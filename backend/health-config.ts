/**
 * Project-specific dependency probes for `GET /api/health` (authenticated).
 *
 * Register optional checks here when a deployment needs to report custom dependency
 * status alongside the built-in MongoDB ping. Do **not** add global or
 * team-wide integration keys (env / S3 secrets; see `docs/kratos/s3-secrets-setup.md`) as probes — those are exercised by Zeus
 * independently; this registry is for app-owned endpoints or resources only.
 */

export interface HealthProbe {
  name: string;
  check: () => Promise<{ status: 'UP' | 'DOWN'; error?: string }>;
}

/** Maintain probes in this array; empty by default. */
export const HEALTH_PROBES: HealthProbe[] = [];
