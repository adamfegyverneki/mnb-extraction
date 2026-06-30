/**
 * Staging hostname label derived from prod subdomainName in infra/config.ts (never written to config).
 * That value is already the deploy host label (internal client 49x has a leading 49x- stripped at sync).
 * Prefixes "staging-": e.g. kratos-test → staging-kratos-test.
 *
 * Staging uses the same ACM certificate as production (wildcard or SAN); no separate cert.
 *
 * Must match staging_site_label() in scripts/run/dev-deploy.sh.
 */
export function stagingSiteLabel(prodSubdomainName: string): string {
  const sub = prodSubdomainName.trim();
  if (!sub) {
    return "staging";
  }
  return `staging-${sub}`;
}
