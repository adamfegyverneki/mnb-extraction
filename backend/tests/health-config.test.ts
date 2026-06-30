import { HEALTH_PROBES, type HealthProbe } from '../health-config';

describe('health-config', () => {
  it('exports HEALTH_PROBES as an array', () => {
    expect(Array.isArray(HEALTH_PROBES)).toBe(true);
  });

  it('validates HealthProbe interface shape at runtime', async () => {
    const upProbe: HealthProbe = {
      name: 'fixture-up',
      check: async () => ({ status: 'UP' }),
    };
    const downProbe: HealthProbe = {
      name: 'fixture-down',
      check: async () => ({ status: 'DOWN', error: 'unreachable' }),
    };

    const up = await upProbe.check();
    expect(up.status).toBe('UP');
    expect(up.error).toBeUndefined();

    const down = await downProbe.check();
    expect(down.status).toBe('DOWN');
    expect(down.error).toBe('unreachable');
  });

  it('requires each registered probe to have name and a check that returns status', async () => {
    for (const probe of HEALTH_PROBES) {
      expect(typeof probe.name).toBe('string');
      expect(probe.name.length).toBeGreaterThan(0);
      expect(typeof probe.check).toBe('function');
      const result = await probe.check();
      expect(['UP', 'DOWN']).toContain(result.status);
      if (result.error !== undefined) {
        expect(typeof result.error).toBe('string');
      }
    }
  });
});
