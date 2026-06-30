/**
 * Resolve Zeus fleet MongoDB database name. Never uses MongoDB’s implicit default `test`.
 *
 * Order: ZEUS_MONITOR_MONGODB_DATABASE env → non-test URI path segment → fleet default below.
 */

/** Live Zeus panel / fleet `projects` database when URI omits a DB or names `test` (zeus.49x.ai production). */
const DEFAULT_ZEUS_FLEET_MONGODB_DATABASE = '49x-zeus-prod';

/**
 * @param {string} uri - ZEUS_MONITOR_MONGODB_URI
 * @param {string | undefined} explicitDb - ZEUS_MONITOR_MONGODB_DATABASE (optional override)
 * @returns {{ dbName: string; notice?: string } | { error: string }}
 */
function resolveZeusMonitorDatabaseName(uri, explicitDb) {
  const trimmed = (explicitDb || '').trim();
  if (trimmed) {
    return { dbName: trimmed };
  }

  if (!uri || typeof uri !== 'string') {
    return { error: 'ZEUS_MONITOR_MONGODB_URI is missing or invalid.' };
  }

  let pathname = '';
  try {
    pathname = new URL(uri).pathname || '';
  } catch {
    return { error: 'Invalid ZEUS_MONITOR_MONGODB_URI (could not parse as URL).' };
  }

  const raw = pathname.replace(/^\//, '');
  const firstSeg = decodeURIComponent((raw.split('/')[0] || '').trim());

  if (!firstSeg || firstSeg.toLowerCase() === 'test') {
    return {
      dbName: DEFAULT_ZEUS_FLEET_MONGODB_DATABASE,
      notice:
        firstSeg.toLowerCase() === 'test'
          ? `URI targeted database "test"; using fleet database "${DEFAULT_ZEUS_FLEET_MONGODB_DATABASE}" instead.`
          : `No database in URI path; using fleet default "${DEFAULT_ZEUS_FLEET_MONGODB_DATABASE}" (not MongoDB default "test").`,
    };
  }

  return { dbName: firstSeg };
}

module.exports = {
  resolveZeusMonitorDatabaseName,
  DEFAULT_ZEUS_FLEET_MONGODB_DATABASE,
};
