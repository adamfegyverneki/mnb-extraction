import type { Collection } from 'mongodb';
import { ObjectId } from 'mongodb';
import type { HealthEvent } from '../../models/HealthEvent';
import * as HealthEventModule from '../../models/HealthEvent';
import {
  countPending5xxEvents,
  detect4xxSpike,
  fetchAndConsumeRecentErrorsForHealth,
  getRecentActivity,
  getRecentWarnings,
  insertHealthEvent,
  isHttp5xxStatus,
  summarizeHttpResponseMessage,
} from '../../services/healthTracker';

jest.mock('../../models/HealthEvent', () => ({
  ...jest.requireActual('../../models/HealthEvent'),
  getHealthEventCollection: jest.fn(),
}));

const getHealthEventCollection = HealthEventModule.getHealthEventCollection as jest.MockedFunction<
  typeof HealthEventModule.getHealthEventCollection
>;

type Doc = HealthEvent & { _id: ObjectId };

function matchesField(doc: Doc, key: string, cond: unknown): boolean {
  const val = (doc as unknown as Record<string, unknown>)[key];
  if (cond !== null && typeof cond === 'object' && !(cond instanceof Date) && !Array.isArray(cond)) {
    const c = cond as Record<string, unknown>;
    if ('$gte' in c) {
      const bound = c.$gte;
      if (bound instanceof Date) {
        if (!(val instanceof Date) || val < bound) return false;
      } else if (typeof bound === 'number' && typeof val === 'number') {
        if (val < bound) return false;
      }
    }
    if ('$lte' in c) {
      const bound = c.$lte;
      if (bound instanceof Date) {
        if (!(val instanceof Date) || val > bound) return false;
      } else if (typeof bound === 'number' && typeof val === 'number') {
        if (val > bound) return false;
      }
    }
    if ('$lt' in c) {
      const bound = c.$lt;
      if (bound instanceof Date) {
        if (!(val instanceof Date) || val >= bound) return false;
      } else if (typeof bound === 'number' && typeof val === 'number') {
        if (val >= bound) return false;
      }
    }
    if ('$exists' in c) {
      const exists = val !== undefined && val !== null;
      if (c.$exists === true && !exists) return false;
      if (c.$exists === false && exists) return false;
    }
    if ('$in' in c && Array.isArray(c.$in)) {
      const arr = c.$in as unknown[];
      return arr.some((x) => {
        if (x === val) return true;
        if (val instanceof ObjectId && x instanceof ObjectId) return val.equals(x);
        return false;
      });
    }
    return true;
  }
  return val === cond;
}

function matchesFilter(doc: Doc, filter: Record<string, unknown>): boolean {
  return Object.entries(filter).every(([k, v]) => {
    if (k === '$or') {
      return (v as unknown[]).some((sub) => matchesFilter(doc, sub as Record<string, unknown>));
    }
    if (k === '$and') {
      return (v as unknown[]).every((sub) => matchesFilter(doc, sub as Record<string, unknown>));
    }
    return matchesField(doc, k, v);
  });
}

function createMemoryCollection(store: Doc[]): Collection<HealthEvent> {
  return {
    insertOne: async (doc: HealthEvent) => {
      const row: Doc = { ...doc, _id: new ObjectId() };
      store.push(row);
    },
    find: (filter: Record<string, unknown>) => ({
      sort: (sortSpec: Record<string, number>) => ({
        limit: (n: number) => ({
          toArray: async () => {
            const matched = store.filter((d) => matchesFilter(d, filter));
            const key = Object.keys(sortSpec)[0];
            const dir = sortSpec[key];
            matched.sort((a, b) => {
              const av = (a as unknown as Record<string, Date>)[key] as Date;
              const bv = (b as unknown as Record<string, Date>)[key] as Date;
              return dir === -1 ? bv.getTime() - av.getTime() : av.getTime() - bv.getTime();
            });
            return matched.slice(0, n);
          },
        }),
      }),
    }),
    deleteMany: async (filter: Record<string, unknown>) => {
      const before = store.length;
      const remaining = store.filter((d) => !matchesFilter(d, filter));
      store.length = 0;
      store.push(...remaining);
      return { deletedCount: before - remaining.length };
    },
    countDocuments: async (filter: Record<string, unknown>) =>
      store.filter((d) => matchesFilter(d, filter)).length,
  } as unknown as Collection<HealthEvent>;
}

describe('isHttp5xxStatus', () => {
  it('accepts 500–599 only', () => {
    expect(isHttp5xxStatus(500)).toBe(true);
    expect(isHttp5xxStatus(599)).toBe(true);
    expect(isHttp5xxStatus(200)).toBe(false);
    expect(isHttp5xxStatus(600)).toBe(false);
    expect(isHttp5xxStatus('500')).toBe(false);
  });
});

describe('summarizeHttpResponseMessage', () => {
  it('parses error string from JSON body on 5xx', () => {
    expect(
      summarizeHttpResponseMessage(JSON.stringify({ error: 'DB down' }), 500)
    ).toBe('DB down');
  });

  it('uses default message for non-JSON 5xx body', () => {
    expect(summarizeHttpResponseMessage('plain', 500)).toBe('Internal server error');
  });

  it('parses error on 4xx', () => {
    expect(
      summarizeHttpResponseMessage(JSON.stringify({ error: 'Bad input' }), 400)
    ).toBe('Bad input');
  });

  it('returns HTTP code label for 4xx without error field', () => {
    expect(summarizeHttpResponseMessage('{}', 404)).toBe('HTTP 404');
  });

  it('returns OK for 2xx', () => {
    expect(summarizeHttpResponseMessage(JSON.stringify({ ok: true }), 200)).toBe('OK');
  });
});

describe('healthTracker service', () => {
  let store: Doc[];

  beforeEach(() => {
    store = [];
    getHealthEventCollection.mockImplementation(
      async (): Promise<Collection<HealthEvent>> => createMemoryCollection(store)
    );
  });

  const base = (over: Partial<HealthEvent>): HealthEvent => ({
    timestamp: new Date('2026-03-30T12:00:00.000Z'),
    path: '/api/x',
    method: 'GET',
    statusCode: 200,
    message: 'OK',
    durationMs: 10,
    ...over,
  });

  it('insertHealthEvent appends a document', async () => {
    const ev = base({});
    await insertHealthEvent(ev);
    expect(store).toHaveLength(1);
    expect(store[0].path).toBe('/api/x');
  });

  it('countPending5xxEvents counts all 5xx rows', async () => {
    store.push(
      { ...base({ statusCode: 500, message: 'a' }), _id: new ObjectId() },
      { ...base({ statusCode: 200 }), _id: new ObjectId() },
      { ...base({ statusCode: 500, message: 'b' }), _id: new ObjectId() }
    );
    expect(await countPending5xxEvents()).toBe(2);
  });

  it('fetchAndConsumeRecentErrorsForHealth returns newest 5xx first, deletes them, strips _id', async () => {
    const tOld = new Date('2026-03-30T11:00:00.000Z');
    const tNew = new Date('2026-03-30T14:00:00.000Z');
    store.push(
      { ...base({ statusCode: 500, message: 'a', timestamp: tOld }), _id: new ObjectId() },
      { ...base({ statusCode: 200, timestamp: new Date('2026-03-30T12:30:00.000Z') }), _id: new ObjectId() },
      { ...base({ statusCode: 500, message: 'c', timestamp: tNew }), _id: new ObjectId() }
    );
    const rows = await fetchAndConsumeRecentErrorsForHealth(10);
    expect(rows.map((r) => r.message)).toEqual(['c', 'a']);
    expect(rows.every((r) => !('_id' in r))).toBe(true);
    expect(store.filter((d) => d.statusCode >= 500)).toHaveLength(0);
    expect(store.some((d) => d.statusCode === 200)).toBe(true);
  });

  it('getRecentWarnings returns slow + 4xx from last 60 minutes', async () => {
    const old = new Date(Date.now() - 2 * 60 * 60 * 1000);
    store.push(
      { ...base({ statusCode: 200, warning: 'SLOW_RESPONSE', timestamp: new Date() }), _id: new ObjectId() },
      { ...base({ statusCode: 404, message: 'nf', timestamp: new Date() }), _id: new ObjectId() },
      { ...base({ statusCode: 200, timestamp: old, warning: 'SLOW_RESPONSE' }), _id: new ObjectId() }
    );
    const rows = await getRecentWarnings(10);
    expect(rows).toHaveLength(2);
    expect(rows.some((r) => r.statusCode === 404)).toBe(true);
    expect(rows.some((r) => r.warning === 'SLOW_RESPONSE')).toBe(true);
  });

  it('getRecentActivity returns any status, newest first', async () => {
    store.push(
      { ...base({ statusCode: 201, timestamp: new Date('2026-03-30T10:00:00.000Z') }), _id: new ObjectId() },
      { ...base({ statusCode: 400, timestamp: new Date('2026-03-30T11:00:00.000Z') }), _id: new ObjectId() }
    );
    const rows = await getRecentActivity(10);
    expect(rows.map((r) => r.statusCode)).toEqual([400, 201]);
  });

  it('detect4xxSpike: spike when zero previous window but 3+ recent 4xx', async () => {
    const now = Date.now();
    store.push(
      { ...base({ statusCode: 404, timestamp: new Date(now - 1 * 60 * 1000) }), _id: new ObjectId() },
      { ...base({ statusCode: 400, timestamp: new Date(now - 2 * 60 * 1000) }), _id: new ObjectId() },
      { ...base({ statusCode: 401, timestamp: new Date(now - 3 * 60 * 1000) }), _id: new ObjectId() }
    );
    const r = await detect4xxSpike();
    expect(r.count_recent_5min).toBe(3);
    expect(r.count_previous_5min).toBe(0);
    expect(r.active).toBe(true);
  });

  it('detect4xxSpike: not active when recent below threshold', async () => {
    const now = Date.now();
    store.push({
      ...base({ statusCode: 404, timestamp: new Date(now - 1 * 60 * 1000) }),
      _id: new ObjectId(),
    });
    const r = await detect4xxSpike();
    expect(r.active).toBe(false);
  });
});
