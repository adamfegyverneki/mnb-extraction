/**
 * Isolated mocks: hanging probe must time out (5s) so dependencies.slowProbe is DOWN.
 */
import { jest } from '@jest/globals';

jest.useFakeTimers();

jest.mock('../../health-config', () => ({
  HEALTH_PROBES: [
    {
      name: 'slowProbe',
      check: () =>
        new Promise<{ status: 'UP' | 'DOWN' }>((resolve) => {
          setTimeout(() => resolve({ status: 'UP' }), 10_000);
        }),
    },
  ],
}));

jest.mock('../../utils/mongodb', () => ({
  connectToDatabase: jest.fn((): Promise<unknown> => Promise.resolve(undefined)),
}));

jest.mock('../../services/healthTracker', () => ({
  countPending5xxEvents: jest.fn((): Promise<number> => Promise.resolve(0)),
  fetchAndConsumeRecentErrorsForHealth: jest.fn((): Promise<unknown[]> => Promise.resolve([])),
  getRecentWarnings: jest.fn((): Promise<unknown[]> => Promise.resolve([])),
  getRecentActivity: jest.fn((): Promise<unknown[]> => Promise.resolve([])),
  detect4xxSpike: jest.fn((): Promise<{
    active: boolean;
    count_recent_5min: number;
    count_previous_5min: number;
  }> =>
    Promise.resolve({
      active: false,
      count_recent_5min: 0,
      count_previous_5min: 0,
    })),
}));

describe('health handler — probe timeout', () => {
  const origEnv = process.env;

  beforeEach(() => {
    process.env = {
      ...origEnv,
      HEALTH_TOKEN: 'probe-token',
      MONGODB_URI: 'mongodb://localhost:27017/test',
    };
  });

  afterEach(() => {
    process.env = origEnv;
    jest.clearAllMocks();
  });

  afterAll(() => {
    jest.useRealTimers();
  });

  it('marks probe DOWN when check exceeds timeout', async () => {
    const { health } = await import('../../handlers/health');
    const resPromise = health({
      httpMethod: 'GET',
      path: '/api/health',
      headers: { 'X-Health-Token': 'probe-token' },
    });
    await jest.advanceTimersByTimeAsync(5000);
    const res = await resPromise;
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body) as {
      dependencies: { mongodb: { status: string }; slowProbe: { status: string; error?: string } };
    };
    expect(body.dependencies.mongodb.status).toBe('UP');
    expect(body.dependencies.slowProbe.status).toBe('DOWN');
    expect(body.dependencies.slowProbe.error).toBe('timeout');
    await jest.advanceTimersByTimeAsync(10_000);
  });
});
