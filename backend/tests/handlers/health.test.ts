import { health } from '../../handlers/health';
import * as healthTracker from '../../services/healthTracker';
import { connectToDatabase } from '../../utils/mongodb';

jest.mock('../../utils/mongodb', () => ({
  connectToDatabase: jest.fn().mockResolvedValue({}),
}));

jest.mock('../../services/healthTracker', () => ({
  countPending5xxEvents: jest.fn(),
  detect4xxSpike: jest.fn(),
  fetchAndConsumeRecentErrorsForHealth: jest.fn(),
  getRecentActivity: jest.fn(),
  getRecentWarnings: jest.fn(),
}));

jest.mock('../../health-config', () => ({
  HEALTH_PROBES: [],
}));

describe('health handler', () => {
  const origEnv = process.env;

  beforeEach(() => {
    process.env = { ...origEnv, HEALTH_TOKEN: 'test-health-token', MONGODB_URI: 'mongodb://localhost:27017/test' };
    jest.clearAllMocks();
    jest.mocked(healthTracker.fetchAndConsumeRecentErrorsForHealth).mockResolvedValue([]);
    jest.mocked(healthTracker.getRecentWarnings).mockResolvedValue([]);
    jest.mocked(healthTracker.getRecentActivity).mockResolvedValue([]);
    jest.mocked(healthTracker.detect4xxSpike).mockResolvedValue({
      active: false,
      count_recent_5min: 0,
      count_previous_5min: 0,
    });
    jest.mocked(healthTracker.countPending5xxEvents).mockResolvedValue(0);
  });

  afterEach(() => {
    process.env = origEnv;
  });

  it('public GET returns status and mongodb when healthy', async () => {
    const res = await health({ httpMethod: 'GET', path: '/api/health', headers: {} });
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body || '{}');
    expect(body).toEqual({ status: 'UP', mongodb: true });
    expect(healthTracker.countPending5xxEvents).toHaveBeenCalled();
    expect(healthTracker.fetchAndConsumeRecentErrorsForHealth).not.toHaveBeenCalled();
  });

  it('authenticated GET returns full payload', async () => {
    const res = await health({
      httpMethod: 'GET',
      path: '/api/health',
      headers: { 'X-Health-Token': 'test-health-token' },
    });
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body || '{}');
    expect(body.status).toBe('UP');
    expect(body.version).toBeDefined();
    expect(body.uptime).toBeDefined();
    expect(body.timestamp).toBeDefined();
    expect(body.dependencies?.mongodb?.status).toBe('UP');
    expect(body.recent_errors).toEqual([]);
    expect(body.recent_warnings).toEqual([]);
    expect(body.recent_logs).toEqual([]);
    expect(body.rate_alerts?.['4xx_spike']).toBeDefined();
    expect(healthTracker.fetchAndConsumeRecentErrorsForHealth).toHaveBeenCalled();
    expect(healthTracker.countPending5xxEvents).not.toHaveBeenCalled();
  });

  it('DEGRADED when recent pending 5xx exist (public)', async () => {
    jest.mocked(healthTracker.countPending5xxEvents).mockResolvedValue(1);
    const res = await health({ httpMethod: 'GET', path: '/api/health', headers: {} });
    const body = JSON.parse(res.body || '{}');
    expect(body.status).toBe('DEGRADED');
    expect(body.mongodb).toBe(true);
  });

  it('public GET sets mongodb false when ping fails', async () => {
    jest.mocked(connectToDatabase).mockRejectedValueOnce(new Error('ECONNREFUSED'));
    const res = await health({ httpMethod: 'GET', path: '/api/health', headers: {} });
    const body = JSON.parse(res.body || '{}');
    expect(body.mongodb).toBe(false);
    expect(body.status).toBe('DEGRADED');
  });

  it('DEGRADED when consumed 5xx batch non-empty (authenticated)', async () => {
    jest.mocked(healthTracker.fetchAndConsumeRecentErrorsForHealth).mockResolvedValue([
      {
        timestamp: new Date(),
        path: '/api/x',
        method: 'GET',
        statusCode: 500,
        message: 'fail',
        durationMs: 1,
      },
    ]);
    const res = await health({
      httpMethod: 'GET',
      path: '/api/health',
      headers: { 'X-Health-Token': 'test-health-token' },
    });
    const body = JSON.parse(res.body || '{}');
    expect(body.status).toBe('DEGRADED');
    expect(body.recent_errors).toHaveLength(1);
  });

  it('DEGRADED when 4xx spike active', async () => {
    jest.mocked(healthTracker.detect4xxSpike).mockResolvedValue({
      active: true,
      count_recent_5min: 5,
      count_previous_5min: 0,
    });
    const res = await health({
      httpMethod: 'GET',
      path: '/api/health',
      headers: { 'X-Health-Token': 'test-health-token' },
    });
    const body = JSON.parse(res.body || '{}');
    expect(body.status).toBe('DEGRADED');
  });

  it('DOWN when Mongo URI missing', async () => {
    process.env = { ...origEnv, HEALTH_TOKEN: 'test-health-token' };
    delete process.env.MONGODB_URI;
    const res = await health({ httpMethod: 'GET', path: '/api/health', headers: {} });
    const body = JSON.parse(res.body || '{}');
    expect(body.status).toBe('DOWN');
    expect(body.mongodb).toBe(false);
  });

  it('rejects non-GET methods', async () => {
    const res = await health({ httpMethod: 'DELETE', path: '/api/health', headers: {} });
    expect(res.statusCode).toBe(405);
  });
});
