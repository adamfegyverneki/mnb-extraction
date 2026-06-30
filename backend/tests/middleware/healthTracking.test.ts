import { success, error, ApiGatewayResponse } from '../../utils/response';

jest.mock('../../utils/logger', () => ({
  logger: {
    warn: jest.fn(),
    info: jest.fn(),
    error: jest.fn(),
  },
}));

jest.mock('../../services/healthTracker', () => {
  const actual = jest.requireActual('../../services/healthTracker');
  return {
    ...actual,
    insertHealthEvent: jest.fn().mockResolvedValue(undefined),
  };
});

import {
  withHealthTracking,
  sanitizeBody,
  SLOW_RESPONSE_THRESHOLD_MS,
  SLOW_RESPONSE_EXCLUDED_PATHS,
  SANITIZED_FIELD_NAMES,
  decodeJwtUserIdFromEvent,
} from '../../middleware/healthTracking';
import * as healthTracker from '../../services/healthTracker';

const insertSpy = healthTracker.insertHealthEvent as jest.MockedFunction<
  typeof healthTracker.insertHealthEvent
>;

describe('sanitizeBody', () => {
  it('redacts every SANITIZED_FIELD_NAMES key (case-insensitive) at top level', () => {
    const obj: Record<string, string> = { ok: 'visible' };
    for (const name of SANITIZED_FIELD_NAMES) {
      obj[name] = 'secret';
    }
    const out = sanitizeBody(JSON.stringify(obj))!;
    expect(out.ok).toBe('visible');
    for (const name of SANITIZED_FIELD_NAMES) {
      expect((out as Record<string, unknown>)[name]).toBe('[REDACTED]');
    }
  });

  it('redacts nested sensitive keys', () => {
    const raw = JSON.stringify({ outer: { password: 'secret', a: 1 } });
    const out = sanitizeBody(raw)!;
    expect((out.outer as Record<string, unknown>).password).toBe('[REDACTED]');
    expect((out.outer as Record<string, unknown>).a).toBe(1);
  });

  it('returns _unparseable on invalid JSON', () => {
    expect(sanitizeBody('not-json')).toEqual({ _unparseable: true });
  });

  it('returns undefined for empty or undefined raw', () => {
    expect(sanitizeBody(undefined)).toBeUndefined();
    expect(sanitizeBody('')).toBeUndefined();
  });

  it('returns _truncated when serialized sanitized body exceeds 8192 bytes', () => {
    const huge = 'x'.repeat(9000);
    const raw = JSON.stringify({ data: huge });
    expect(sanitizeBody(raw)).toEqual({ _truncated: true, reason: 'body_too_large' });
  });
});

describe('decodeJwtUserIdFromEvent', () => {
  it('returns sub from Bearer JWT without verifying', () => {
    const header = Buffer.from(JSON.stringify({ sub: 'user-123' }), 'utf8').toString('base64url');
    const token = `header.${header}.sig`;
    const event = { headers: { Authorization: `Bearer ${token}` } };
    expect(decodeJwtUserIdFromEvent(event)).toBe('user-123');
  });
});

describe('withHealthTracking', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    insertSpy.mockResolvedValue(undefined);
  });

  function makeEvent(overrides: Record<string, unknown> = {}): Record<string, unknown> {
    return {
      path: '/api/test',
      httpMethod: 'GET',
      headers: {},
      ...overrides,
    };
  }

  it('records duration and does not await insert (fire-and-forget)', async () => {
    let releaseInsert!: () => void;
    const insertGate = new Promise<void>((resolve) => {
      releaseInsert = resolve;
    });
    insertSpy.mockImplementation(() => insertGate as Promise<void>);

    const wrapped = withHealthTracking(async () => success({ ok: true }));
    const res = await wrapped(makeEvent(), {});
    expect(res.statusCode).toBe(200);
    releaseInsert!();
    await insertGate;
  });

  it('sets SLOW_RESPONSE when duration exceeds threshold and path is not excluded', async () => {
    const now = jest.spyOn(Date, 'now');
    const t0 = 1_000_000;
    const t1 = t0 + SLOW_RESPONSE_THRESHOLD_MS + 500;
    now.mockReturnValueOnce(t0).mockReturnValueOnce(t1);

    const wrapped = withHealthTracking(async () => success({ ok: true }));
    await wrapped(makeEvent({ path: '/api/slow' }), {});

    expect(insertSpy.mock.calls[0][0]).toMatchObject({
      warning: 'SLOW_RESPONSE',
      path: '/api/slow',
    });
    now.mockRestore();
  });

  it('skips SLOW_RESPONSE for excluded paths', async () => {
    const now = jest.spyOn(Date, 'now');
    const t0 = 1_000_000;
    const t1 = t0 + SLOW_RESPONSE_THRESHOLD_MS + 500;
    now.mockReturnValueOnce(t0).mockReturnValueOnce(t1);

    const wrapped = withHealthTracking(async () => success({ ok: true }));
    await wrapped(makeEvent({ path: '/api/worker' }), {});

    expect(insertSpy.mock.calls[0][0].warning).toBeUndefined();
    expect(SLOW_RESPONSE_EXCLUDED_PATHS).toContain('/api/worker');
    now.mockRestore();
  });

  it('includes sanitized request and response bodies for 5xx', async () => {
    const wrapped = withHealthTracking(async () =>
      error('boom', 500)
    );
    const body = JSON.stringify({ password: 'secret', msg: 'e' });
    await wrapped(
      makeEvent({
        body,
        headers: { Authorization: 'Bearer x.y.z' },
      }),
      {}
    );

    const payload = insertSpy.mock.calls[0][0];
    expect(payload.statusCode).toBe(500);
    expect(payload.requestBody).toEqual({ msg: 'e', password: '[REDACTED]' });
    expect(payload.responseBody).toEqual({ error: 'boom' });
  });

  it('passes awsRequestId from Lambda context', async () => {
    const wrapped = withHealthTracking(async () => success({ a: 1 }));
    await wrapped(makeEvent(), { awsRequestId: 'req-abc' });

    expect(insertSpy.mock.calls[0][0].awsRequestId).toBe('req-abc');
  });

  it('stores summarized message for 2xx (not full response body)', async () => {
    const long = 'z'.repeat(3000);
    const wrapped = withHealthTracking(async (): Promise<ApiGatewayResponse> => ({
      statusCode: 200,
      headers: { 'Content-Type': 'application/json' },
      body: long,
    }));
    await wrapped(makeEvent(), {});

    expect(insertSpy.mock.calls[0][0].message).toBe('OK');
  });
});
