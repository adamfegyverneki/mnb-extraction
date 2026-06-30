import { connectToDatabase } from '../utils/mongodb';
import { Collection, IndexDescription } from 'mongodb';

export const HEALTH_EVENT_COLLECTION = 'health_events';

/** TTL index: documents expire 7 days after `timestamp`. */
export const HEALTH_EVENT_TTL_SECONDS = 7 * 24 * 60 * 60;

export type HealthEventWarning = 'SLOW_RESPONSE';

/**
 * Document shape for `health_events`. Optional fields are omitted when not applicable.
 */
export interface HealthEvent {
  timestamp: Date;
  path: string;
  method: string;
  statusCode: number;
  message: string;
  durationMs: number;
  requestBody?: Record<string, unknown>;
  responseBody?: Record<string, unknown>;
  userId?: string;
  awsRequestId?: string;
  warning?: HealthEventWarning;
}

/**
 * Index definitions applied on collection access (idempotent createIndex).
 * 1) TTL on timestamp — 7-day retention
 * 2) path + method + time — activity by route
 * 3) status + time — pending 5xx listing and consume-after-read
 */
export const HEALTH_EVENT_INDEXES: readonly IndexDescription[] = [
  { key: { timestamp: 1 }, expireAfterSeconds: HEALTH_EVENT_TTL_SECONDS },
  { key: { path: 1, method: 1, timestamp: -1 } },
  { key: { statusCode: 1, timestamp: -1 } },
];

async function ensureIndexes(col: Collection<HealthEvent>): Promise<void> {
  await Promise.all(
    HEALTH_EVENT_INDEXES.map((desc) => {
      const opts: { expireAfterSeconds?: number } = {};
      if (desc.expireAfterSeconds !== undefined) {
        opts.expireAfterSeconds = desc.expireAfterSeconds;
      }
      return col.createIndex(desc.key, opts);
    })
  ).catch(() => {});
}

async function getCollection(): Promise<Collection<HealthEvent>> {
  const db = await connectToDatabase();
  const col = db.collection<HealthEvent>(HEALTH_EVENT_COLLECTION);
  await ensureIndexes(col);
  return col;
}

/** Ensures indexes; used by `healthTracker` for queries and inserts. */
export async function getHealthEventCollection(): Promise<Collection<HealthEvent>> {
  return getCollection();
}
