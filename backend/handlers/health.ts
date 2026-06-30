import 'dotenv/config';
import { success, error, ApiGatewayResponse } from '../utils/response';
import { connectToDatabase } from '../utils/mongodb';
import {
  countPending5xxEvents,
  detect4xxSpike,
  fetchAndConsumeRecentErrorsForHealth,
  getRecentActivity,
  getRecentWarnings,
} from '../services/healthTracker';
import { HEALTH_PROBES, type HealthProbe } from '../health-config';

const RECENT_LIMIT = 10;
const PROBE_TIMEOUT_MS = 5000;

type ApiGatewayLikeEvent = {
  httpMethod?: string;
  path?: string;
  headers?: Record<string, string | undefined>;
  body?: string | null;
};

function delayReject(ms: number): Promise<never> {
  return new Promise((_, reject) => {
    setTimeout(() => reject(new Error('timeout')), ms);
  });
}

function getTokenFromEvent(event: ApiGatewayLikeEvent): string | undefined {
  const headers: Record<string, string | undefined> = event?.headers ?? {};
  return (
    headers['x-health-token'] ??
    headers['X-Health-Token'] ??
    headers['X-HEALTH-TOKEN']
  );
}

function isValidToken(provided: string | undefined): boolean {
  const expected = process.env.HEALTH_TOKEN;
  return Boolean(expected && provided === expected);
}

async function mongoPing(): Promise<{ status: 'UP' | 'DOWN'; error?: string }> {
  if (!process.env.MONGODB_URI) {
    return { status: 'DOWN', error: 'MONGODB_URI not set' };
  }
  try {
    await Promise.race([connectToDatabase(), delayReject(PROBE_TIMEOUT_MS)]);
    return { status: 'UP' };
  } catch (err) {
    const msg = err instanceof Error && err.message === 'timeout' ? 'timeout' : err instanceof Error ? err.message : 'MongoDB connection failed';
    return { status: 'DOWN', error: msg };
  }
}

async function runProbe(probe: HealthProbe): Promise<{ name: string; status: 'UP' | 'DOWN'; error?: string }> {
  try {
    const result = await Promise.race([probe.check(), delayReject(PROBE_TIMEOUT_MS)]);
    return { name: probe.name, status: result.status, ...(result.error ? { error: result.error } : {}) };
  } catch (err) {
    const msg = err instanceof Error ? err.message : 'probe failed';
    return { name: probe.name, status: 'DOWN', error: msg === 'timeout' ? 'timeout' : msg };
  }
}

function computeOverallStatus(params: {
  mongoUriSet: boolean;
  mongoReachable: boolean;
  recentErrorsCount: number;
  fourxxSpikeActive: boolean;
}): 'UP' | 'DEGRADED' | 'DOWN' {
  if (!params.mongoUriSet) return 'DOWN';
  if (!params.mongoReachable || params.recentErrorsCount > 0 || params.fourxxSpikeActive) {
    return 'DEGRADED';
  }
  return 'UP';
}

async function handleGetHealth(event: ApiGatewayLikeEvent): Promise<ApiGatewayResponse> {
  const mongoUriSet = Boolean(process.env.MONGODB_URI);
  const authenticated = isValidToken(getTokenFromEvent(event));

  const probePromises = HEALTH_PROBES.map((p) => runProbe(p));

  const [recentWarnings, recentHttpActivity, spike, mongoDep, ...probeResults] = await Promise.all([
    getRecentWarnings(RECENT_LIMIT),
    getRecentActivity(RECENT_LIMIT),
    detect4xxSpike(),
    mongoPing(),
    ...probePromises,
  ]);

  /** Pending 5xx rows only (Zeus); not HTTP access logs — those go in `recentHttpActivity`. */
  const consumedPending5xx = authenticated
    ? await fetchAndConsumeRecentErrorsForHealth(RECENT_LIMIT)
    : [];
  const recentErrorsCount = authenticated
    ? consumedPending5xx.length
    : await countPending5xxEvents();

  const mongoReachable = mongoDep.status === 'UP';
  const status = computeOverallStatus({
    mongoUriSet,
    mongoReachable,
    recentErrorsCount,
    fourxxSpikeActive: spike.active,
  });

  if (!authenticated) {
    return success({ status, mongodb: mongoReachable });
  }

  const dependencies: Record<string, { status: 'UP' | 'DOWN'; error?: string }> = {
    mongodb: {
      status: mongoDep.status,
      ...(mongoDep.error ? { error: mongoDep.error } : {}),
    },
  };
  for (const pr of probeResults) {
    dependencies[pr.name] = {
      status: pr.status,
      ...(pr.error ? { error: pr.error } : {}),
    };
  }

  return success({
    status,
    version: process.env.APP_VERSION || 'unknown',
    uptime: Math.floor(process.uptime()),
    timestamp: new Date().toISOString(),
    dependencies,
    recent_errors: consumedPending5xx,
    recent_warnings: recentWarnings,
    recent_logs: recentHttpActivity,
    rate_alerts: {
      '4xx_spike': {
        active: spike.active,
        count_recent_5min: spike.count_recent_5min,
        count_previous_5min: spike.count_previous_5min,
      },
    },
  });
}

/**
 * GET /api/health — public: `{ status, mongodb }` (boolean, no secrets). Authenticated (`X-Health-Token`): full diagnostics;
 * `recent_errors` is pending 5xx only (consumed after read). `recent_logs` is recent HTTP activity (any status).
 */
export const health = async (event: unknown): Promise<ApiGatewayResponse> => {
  const e = event as ApiGatewayLikeEvent;
  const method = e.httpMethod?.toUpperCase() ?? 'GET';

  if (method === 'GET') {
    return handleGetHealth(e);
  }

  return error('Method not allowed', 405);
};
