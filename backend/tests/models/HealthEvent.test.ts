import type { HealthEvent, HealthEventWarning } from '../../models/HealthEvent';
import {
  HEALTH_EVENT_COLLECTION,
  HEALTH_EVENT_INDEXES,
  HEALTH_EVENT_TTL_SECONDS,
} from '../../models/HealthEvent';

describe('HealthEvent model contract', () => {
  it('defines 7-day TTL in seconds', () => {
    expect(HEALTH_EVENT_TTL_SECONDS).toBe(7 * 24 * 60 * 60);
  });

  it('uses the health_events collection name', () => {
    expect(HEALTH_EVENT_COLLECTION).toBe('health_events');
  });

  it('declares three indexes: TTL on timestamp, path+method+time, status+time', () => {
    expect(HEALTH_EVENT_INDEXES).toHaveLength(3);

    const [ttl, pathMethod, statusTime] = HEALTH_EVENT_INDEXES;

    expect(ttl.key).toEqual({ timestamp: 1 });
    expect(ttl.expireAfterSeconds).toBe(HEALTH_EVENT_TTL_SECONDS);

    expect(pathMethod.key).toEqual({ path: 1, method: 1, timestamp: -1 });
    expect(pathMethod.expireAfterSeconds).toBeUndefined();

    expect(statusTime.key).toEqual({ statusCode: 1, timestamp: -1 });
    expect(statusTime.expireAfterSeconds).toBeUndefined();
  });

  it('requires core fields and durationMs; optional fields are optional', () => {
    const minimal: HealthEvent = {
      timestamp: new Date('2026-03-30T12:00:00.000Z'),
      path: '/api/chat',
      method: 'POST',
      statusCode: 500,
      message: 'fail',
      durationMs: 42,
    };
    expect(minimal.durationMs).toBe(42);

    const warning: HealthEventWarning = 'SLOW_RESPONSE';

    const full: HealthEvent = {
      ...minimal,
      requestBody: { a: 1 },
      responseBody: { error: 'x' },
      userId: 'user_1',
      awsRequestId: 'req-1',
      warning,
    };

    expect(full.warning).toBe('SLOW_RESPONSE');
    expect(full.requestBody).toEqual({ a: 1 });
  });
});
