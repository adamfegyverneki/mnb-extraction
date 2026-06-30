import { getHealthEventCollection, type HealthEvent } from '../models/HealthEvent';
import { logger } from '../utils/logger';

const FIVE_MIN_MS = 5 * 60 * 1000;
const TEN_MIN_MS = 10 * 60 * 1000;
const WARNINGS_WINDOW_MS = 60 * 60 * 1000;

const DEFAULT_LIMIT = 10;

/** Mongo filter for HTTP 5xx only (defensive against bad or legacy rows). */
const PENDING_5XX_FILTER = { statusCode: { $gte: 500, $lte: 599 } };

/** True only for finite numeric HTTP 5xx (defense in depth after Mongo query). */
export function isHttp5xxStatus(code: unknown): boolean {
  if (typeof code !== 'number' || !Number.isFinite(code)) return false;
  return code >= 500 && code <= 599;
}

export type HealthEventDoc = HealthEvent;

export type InsertHealthEventInput = HealthEvent;

export async function insertHealthEvent(event: InsertHealthEventInput): Promise<void> {
  const col = await getHealthEventCollection();
  await col.insertOne(event);
}

/**
 * Count of 5xx events not yet delivered to an authenticated health consumer (Zeus).
 * Used for public `GET /api/health` `{ status }` without consuming rows.
 */
export async function countPending5xxEvents(): Promise<number> {
  try {
    const col = await getHealthEventCollection();
    return await col.countDocuments(PENDING_5XX_FILTER);
  } catch (err) {
    logger.warn('healthTracker: countPending5xxEvents failed', { err });
    return 0;
  }
}

/**
 * Returns up to `limit` newest 5xx events (for Zeus), then deletes those documents so each error is signaled once.
 */
export async function fetchAndConsumeRecentErrorsForHealth(limit = DEFAULT_LIMIT): Promise<HealthEventDoc[]> {
  try {
    const col = await getHealthEventCollection();
    const docs = await col
      .find(PENDING_5XX_FILTER)
      .sort({ timestamp: -1 })
      .limit(limit)
      .toArray();

    const strictly5xx = docs.filter((d) => isHttp5xxStatus(d.statusCode));
    if (strictly5xx.length === 0) {
      return [];
    }

    const ids = strictly5xx.map((d) => d._id);
    await col.deleteMany({ _id: { $in: ids } });

    return strictly5xx.map(({ _id, ...rest }) => rest as HealthEventDoc);
  } catch (err) {
    logger.warn('healthTracker: fetchAndConsumeRecentErrorsForHealth failed', { err });
    return [];
  }
}

/**
 * Slow responses and 4xx in the last 60 minutes, newest first.
 */
export async function getRecentWarnings(limit = DEFAULT_LIMIT): Promise<HealthEventDoc[]> {
  try {
    const col = await getHealthEventCollection();
    const since = new Date(Date.now() - WARNINGS_WINDOW_MS);
    return await col
      .find(
        {
          $or: [{ warning: 'SLOW_RESPONSE' }, { statusCode: { $gte: 400, $lt: 500 } }],
          timestamp: { $gte: since },
        },
        { projection: { _id: 0 } }
      )
      .sort({ timestamp: -1 })
      .limit(limit)
      .toArray();
  } catch (err) {
    logger.warn('healthTracker: getRecentWarnings failed', { err });
    return [];
  }
}

/** Last N HTTP events (any status), newest first. */
export async function getRecentActivity(limit = DEFAULT_LIMIT): Promise<HealthEventDoc[]> {
  try {
    const col = await getHealthEventCollection();
    return await col
      .find({}, { projection: { _id: 0 } })
      .sort({ timestamp: -1 })
      .limit(limit)
      .toArray();
  } catch (err) {
    logger.warn('healthTracker: getRecentActivity failed', { err });
    return [];
  }
}

export type FourxxSpikeResult = {
  active: boolean;
  count_recent_5min: number;
  count_previous_5min: number;
};

/**
 * Compares 4xx counts in the last 5 minutes vs the prior 5–10 minute window.
 * Spike when countRecent >= 3 and countRecent >= 3 * countPrevious (including zero previous).
 */
export async function detect4xxSpike(): Promise<FourxxSpikeResult> {
  try {
    const col = await getHealthEventCollection();
    const now = Date.now();
    const filter4xx = { statusCode: { $gte: 400, $lt: 500 } };

    const count_recent_5min = await col.countDocuments({
      ...filter4xx,
      timestamp: { $gte: new Date(now - FIVE_MIN_MS) },
    });

    const count_previous_5min = await col.countDocuments({
      ...filter4xx,
      timestamp: { $gte: new Date(now - TEN_MIN_MS), $lt: new Date(now - FIVE_MIN_MS) },
    });

    const active =
      count_recent_5min >= 3 && count_recent_5min >= 3 * count_previous_5min;

    return { active, count_recent_5min, count_previous_5min };
  } catch (err) {
    logger.warn('healthTracker: detect4xxSpike failed', { err });
    return { active: false, count_recent_5min: 0, count_previous_5min: 0 };
  }
}

export function summarizeHttpResponseMessage(
  body: string | undefined,
  statusCode: number
): string {
  if (statusCode >= 500) {
    let message = 'Internal server error';
    try {
      const parsed = JSON.parse(body ?? '{}');
      if (typeof parsed?.error === 'string') message = parsed.error;
    } catch {
      // body is not JSON — keep default message
    }
    return message;
  }
  if (statusCode >= 400) {
    try {
      const parsed = JSON.parse(body ?? '{}');
      if (typeof parsed?.error === 'string') return parsed.error;
    } catch {
      // fall through
    }
    return `HTTP ${statusCode}`;
  }
  return 'OK';
}

/**
 * Log one HTTP response to the health_events collection (any status).
 * Fire-and-forget: never awaited so it never delays the response.
 */
export function logHttpActivity(
  path: string,
  method: string,
  statusCode: number,
  message: string
): void {
  insertHealthEvent({
    timestamp: new Date(),
    path,
    method,
    statusCode,
    message,
    durationMs: 0,
  }).catch((err) => {
    logger.warn('healthTracker: failed to store activity event', { err });
  });
}

/** Thin alias for {@link getRecentActivity} — used by `health.ts` until the enriched handler lands. */
export async function getRecentActivityForHealth(limit = DEFAULT_LIMIT): Promise<HealthEvent[]> {
  return getRecentActivity(limit);
}
