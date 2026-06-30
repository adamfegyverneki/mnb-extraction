import { ApiGatewayResponse } from '../utils/response';
import { insertHealthEvent, summarizeHttpResponseMessage } from '../services/healthTracker';
import { logger } from '../utils/logger';
import type { HealthEvent } from '../models/HealthEvent';

/** Slow response threshold — above this, non-excluded routes get `warning: SLOW_RESPONSE` (non-5xx only). */
export const SLOW_RESPONSE_THRESHOLD_MS = 3000;

/** Paths excluded from slow-response warnings (e.g. long-running worker proxy). */
export const SLOW_RESPONSE_EXCLUDED_PATHS: readonly string[] = ['/api/worker'];

/** Field names (case-insensitive) redacted in sanitized JSON bodies. */
export const SANITIZED_FIELD_NAMES = [
  'password',
  'token',
  'authorization',
  'secret',
  'apiKey',
  'api_key',
  'creditCard',
  'credit_card',
  'ssn',
  'cvv',
  'pin',
] as const;

const SANITIZED_BODY_MAX_BYTES = 8192;

type AnyHandler = (event: any, context?: any) => Promise<ApiGatewayResponse>;

function isSensitiveKey(key: string): boolean {
  const lower = key.toLowerCase();
  return SANITIZED_FIELD_NAMES.some((n) => n.toLowerCase() === lower);
}

function redactValue(value: unknown): unknown {
  if (value === null || typeof value !== 'object') {
    return value;
  }
  if (Array.isArray(value)) {
    return value.map(redactValue);
  }
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
    out[k] = isSensitiveKey(k) ? '[REDACTED]' : redactValue(v);
  }
  return out;
}

/**
 * Parse JSON, redact sensitive keys recursively, and enforce max serialized size.
 * Returns `undefined` when `raw` is empty/absent.
 */
export function sanitizeBody(raw: string | undefined): Record<string, unknown> | undefined {
  if (raw === undefined || raw === '') {
    return undefined;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { _unparseable: true };
  }
  if (typeof parsed !== 'object' || parsed === null) {
    return { _unparseable: true };
  }
  const redacted = redactValue(parsed);
  const serialized = JSON.stringify(redacted);
  if (Buffer.byteLength(serialized, 'utf8') > SANITIZED_BODY_MAX_BYTES) {
    return { _truncated: true, reason: 'body_too_large' };
  }
  return redacted as unknown as Record<string, unknown>;
}

function getHeader(event: any, name: string): string | undefined {
  const h = event.headers;
  if (!h || typeof h !== 'object') return undefined;
  const lower = name.toLowerCase();
  for (const [k, v] of Object.entries(h)) {
    if (k.toLowerCase() === lower && typeof v === 'string') {
      return v;
    }
  }
  return undefined;
}

/** Decode JWT payload only (no signature verification); returns a stable user id string if present. */
export function decodeJwtUserIdFromEvent(event: any): string | undefined {
  const auth = getHeader(event, 'Authorization');
  if (!auth?.startsWith('Bearer ')) {
    return undefined;
  }
  const token = auth.slice(7).trim();
  const parts = token.split('.');
  if (parts.length !== 3) {
    return undefined;
  }
  try {
    const segment = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    const pad = segment.length % 4 === 0 ? '' : '='.repeat(4 - (segment.length % 4));
    const json = Buffer.from(segment + pad, 'base64').toString('utf8');
    const payload = JSON.parse(json) as Record<string, unknown>;
    if (typeof payload.sub === 'string') {
      return payload.sub;
    }
    if (typeof payload.userId === 'string') {
      return payload.userId;
    }
    if (typeof payload.email === 'string') {
      return payload.email;
    }
  } catch {
    return undefined;
  }
  return undefined;
}

function getRawRequestBody(event: any): string | undefined {
  if (event.body === undefined || event.body === null) {
    return undefined;
  }
  if (typeof event.body !== 'string') {
    return undefined;
  }
  if (event.isBase64Encoded) {
    return Buffer.from(event.body, 'base64').toString('utf8');
  }
  return event.body;
}

function buildHealthEvent(params: {
  event: any;
  context: any;
  response: ApiGatewayResponse;
  durationMs: number;
  rawRequestBody: string | undefined;
}): HealthEvent {
  const { event, context, response, durationMs, rawRequestBody } = params;
  const path: string = event.path || event.requestContext?.http?.path || 'unknown';
  const method: string = event.httpMethod || event.requestContext?.http?.method || 'unknown';
  const statusCode = response.statusCode;
  const message = summarizeHttpResponseMessage(response.body, statusCode);
  const userId = decodeJwtUserIdFromEvent(event);
  const awsRequestId =
    typeof context?.awsRequestId === 'string' ? context.awsRequestId : undefined;

  const base: HealthEvent = {
    timestamp: new Date(),
    path,
    method,
    statusCode,
    message,
    durationMs,
    ...(userId !== undefined ? { userId } : {}),
    ...(awsRequestId !== undefined ? { awsRequestId } : {}),
  };

  if (statusCode >= 500) {
    return {
      ...base,
      requestBody: sanitizeBody(rawRequestBody),
      responseBody: sanitizeBody(response.body),
    };
  }

  if (
    durationMs > SLOW_RESPONSE_THRESHOLD_MS &&
    !SLOW_RESPONSE_EXCLUDED_PATHS.includes(path)
  ) {
    return { ...base, warning: 'SLOW_RESPONSE' };
  }

  return base;
}

/**
 * Wraps a Lambda handler to record each HTTP response in the health_events collection
 * (any status code). Logging is fire-and-forget — the response is never delayed.
 *
 * Usage:
 *   export const myHandler = withHealthTracking(async (event) => { ... });
 */
export function withHealthTracking(handler: AnyHandler): AnyHandler {
  return async (event: any, context?: any): Promise<ApiGatewayResponse> => {
    const startTime = Date.now();
    const rawRequestBody = getRawRequestBody(event);

    const response = await handler(event, context);

    const durationMs = Date.now() - startTime;

    const payload = buildHealthEvent({
      event,
      context,
      response,
      durationMs,
      rawRequestBody,
    });

    void insertHealthEvent(payload).catch((err) => {
      logger.warn('healthTracking: insertHealthEvent failed', { err });
    });

    return response;
  };
}
