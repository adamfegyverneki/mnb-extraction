/**
 * Register (or update) this project in the Zeus fleet monitor dashboard.
 *
 * Run from the backend/ directory so node_modules (mongodb, dotenv) are accessible:
 *   cd backend && node ../scripts/monitor/register-project.js
 *
 * Required sources:
 *   backend/.env              — ZEUS_MONITOR_MONGODB_URI, HEALTH_TOKEN (via dotenv); DB from URI path, ZEUS_MONITOR_MONGODB_DATABASE, or fleet default (see resolve-monitor-db-name.js)
 *   HEALTH_URL env var        — full URL to the public health route (template default: …/api/health), set by dev-deploy.sh
 *   LOG_GROUP_PREFIX env var  — CloudWatch Logs prefix for Lambdas (e.g. /aws/lambda/kratos-prod-), set by dev-deploy.sh
 *   context/config.json       — projectName, clientName
 *
 * Maintainer email (for Slack / fleet contact), in order:
 *   1. MAINTAINER_EMAIL env — explicit override (e.g. CI)
 *   2. GitHub CLI as a human user: `gh api user` must not be a Bot / * [bot] * login; then verified emails from `user/emails`, then profile `.email`
 *   3. If `gh` is an automation user (e.g. GITHUB_TOKEN in Actions): `GITHUB_ACTOR`’s public email via `gh api users/{actor}` when actor looks human
 *   4. Recent `git log` author emails (first non-automation)
 *   5. `git config user.email` only if it does not look like an automation account
 *
 * The script upserts by (projectName, clientName) — safe to run on every deploy.
 * Caller must set ZEUS_MONITOR_MONGODB_URI (dev-deploy.sh enforces or SKIP_ZEUS_MONITOR_REGISTRATION).
 * Database: URI path, ZEUS_MONITOR_MONGODB_DATABASE, else fleet default `49x-zeus-prod` — never MongoDB’s implicit `test`.
 *
 * Before writing to Zeus, the script GETs HEALTH_URL and requires HTTP 2xx so you do not register
 * a project whose /api/health route is missing (e.g. frontend deployed but backend health not yet deployed).
 * Override with SKIP_HEALTH_URL_CHECK=1 (emergency / CI only).
 */

require('dotenv/config');

const { MongoClient } = require('mongodb');
const { execSync, execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const {
  isUsableMaintainerEmail,
  isGitHubBotAccount,
  isGitHubBotLogin,
  pickEmailFromGhEmailsList,
  firstUsableAuthorEmailFromGitLogLines,
} = require('./maintainer-email-lib.js');
const { resolveZeusMonitorDatabaseName } = require('./resolve-monitor-db-name.js');

const PROJECT_ROOT = path.join(__dirname, '../..');
const CONFIG_FILE = path.join(PROJECT_ROOT, 'context/config.json');

function ghApiRaw(endpoint) {
  try {
    return execFileSync('gh', ['api', endpoint], {
      cwd: PROJECT_ROOT,
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'pipe'],
      env: process.env,
    }).trim();
  } catch {
    return '';
  }
}

function ghApiUserJson() {
  const raw = ghApiRaw('user');
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function ghUserEmailsJson() {
  const raw = ghApiRaw('user/emails');
  if (!raw) return [];
  try {
    const data = JSON.parse(raw);
    return Array.isArray(data) ? data : [];
  } catch {
    return [];
  }
}

function ghApiUserEmailForLogin(login) {
  if (!login || isGitHubBotLogin(login)) return '';
  const pathSeg = `users/${encodeURIComponent(login)}`;
  try {
    const out = execFileSync('gh', ['api', pathSeg, '--jq', '.email'], {
      cwd: PROJECT_ROOT,
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'pipe'],
      env: process.env,
    }).trim();
    return isUsableMaintainerEmail(out) ? out : '';
  } catch {
    return '';
  }
}

function resolveMaintainerEmailFromGitLog() {
  try {
    const out = execSync('git log -80 --format=%ae', {
      cwd: PROJECT_ROOT,
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    return firstUsableAuthorEmailFromGitLogLines(out, 80);
  } catch {
    return '';
  }
}

function resolveMaintainerEmail() {
  const override = (process.env.MAINTAINER_EMAIL || '').trim();
  if (override) return override;

  const ghUser = ghApiUserJson();
  if (ghUser) {
    if (!isGitHubBotAccount(ghUser)) {
      const fromList = pickEmailFromGhEmailsList(ghUserEmailsJson());
      if (fromList) return fromList;

      const publicEmail =
        typeof ghUser.email === 'string' && ghUser.email.trim() && ghUser.email !== 'null'
          ? ghUser.email.trim()
          : '';
      if (isUsableMaintainerEmail(publicEmail)) return publicEmail;
    } else {
      console.warn(
        `[zeus-monitor] gh is authenticated as automation (${ghUser.login || 'unknown'}); not using that account’s emails for maintainer.`
      );
      const actions = (process.env.GITHUB_ACTIONS || '').toLowerCase() === 'true';
      const actor = (process.env.GITHUB_ACTOR || '').trim();
      if (actions && actor && !isGitHubBotLogin(actor)) {
        const actorEmail = ghApiUserEmailForLogin(actor);
        if (actorEmail) {
          console.warn(`[zeus-monitor] Using GITHUB_ACTOR public profile email (${actor}) for maintainer.`);
          return actorEmail;
        }
      }
    }
  }

  const fromLog = resolveMaintainerEmailFromGitLog();
  if (fromLog) return fromLog;

  let gitEmail = '';
  try {
    gitEmail = execSync('git config user.email', {
      cwd: PROJECT_ROOT,
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'pipe'],
    }).trim();
  } catch {
    // git not configured or not in a repo
  }

  if (isUsableMaintainerEmail(gitEmail)) return gitEmail;

  if (gitEmail) {
    console.warn(
      '[zeus-monitor] maintainerEmail left empty: no human GitHub user email and git user.email is unusable. Use `gh auth login` as yourself (user:email), set MAINTAINER_EMAIL, or ensure recent commits have a human author email.'
    );
  } else {
    console.warn(
      '[zeus-monitor] maintainerEmail left empty: configure gh as a human user, set MAINTAINER_EMAIL, or add a git user.email.'
    );
  }

  return '';
}

const FLEET_HEALTH_STATUSES = new Set(['UP', 'DEGRADED', 'DOWN']);

/**
 * Warn when the live JSON does not match the fleet Zeus contract (wrong status words or non-default path).
 * Does not block registration — see docs/kratos/zeus-health-contract.md
 */
function warnIfHealthContractMismatch(urlString, bodyText) {
  if ((process.env.SKIP_HEALTH_CONTRACT_WARN || '').trim() === '1') {
    return;
  }
  let parsed;
  try {
    parsed = JSON.parse(bodyText);
  } catch {
    return;
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return;
  }
  const status = parsed.status;
  if (typeof status === 'string' && !FLEET_HEALTH_STATUSES.has(status)) {
    console.warn(
      `[zeus-monitor] Health JSON "status" is "${status}" — fleet Zeus expects UP, DEGRADED, or DOWN. ` +
        'If intentional, align Zeus polling or set SKIP_HEALTH_CONTRACT_WARN=1. ' +
        'See docs/kratos/zeus-health-contract.md'
    );
  }
  try {
    const u = new URL(urlString);
    const pathNorm = u.pathname.replace(/\/+$/, '') || '/';
    if (!pathNorm.endsWith('/api/health')) {
      console.warn(
        `[zeus-monitor] HEALTH_URL path is "${u.pathname}" — Kratos template defaults to GET /api/health. ` +
          'Ensure this URL matches serverless routes and Zeus. See docs/kratos/zeus-health-contract.md'
      );
    }
  } catch {
    // ignore malformed URL
  }
}

/**
 * Refuse to upsert into Zeus if HEALTH_URL is missing or unreachable (e.g. API deployed without the health route).
 */
async function assertHealthUrlReachable(url) {
  if ((process.env.SKIP_HEALTH_URL_CHECK || '').trim() === '1') {
    console.warn('[zeus-monitor] SKIP_HEALTH_URL_CHECK=1 — skipping HEALTH_URL reachability check.');
    return;
  }
  try {
    const res = await fetch(url, {
      method: 'GET',
      redirect: 'follow',
      signal: AbortSignal.timeout(15000),
      headers: { Accept: 'application/json' },
    });
    const bodyText = await res.text();
    if (!res.ok) {
      console.error(
        `[zeus-monitor] HEALTH_URL returned HTTP ${res.status}. Deploy the health endpoint and confirm it returns 2xx before registering. Not writing to Zeus.`
      );
      process.exit(1);
    }
    const slice = bodyText.length > 65536 ? bodyText.slice(0, 65536) : bodyText;
    warnIfHealthContractMismatch(url, slice);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(
      `[zeus-monitor] HEALTH_URL is not reachable (${msg}). Deploy the health endpoint first. Not writing to Zeus.`
    );
    process.exit(1);
  }
}

async function main() {
  const monitorUri = process.env.ZEUS_MONITOR_MONGODB_URI;
  if (!monitorUri) {
    console.error('[monitor] ZEUS_MONITOR_MONGODB_URI is not set');
    process.exit(1);
  }

  const healthUrl = process.env.HEALTH_URL;
  if (!healthUrl) {
    console.error('[zeus-monitor] HEALTH_URL env var not set');
    process.exit(1);
  }

  await assertHealthUrlReachable(healthUrl.trim());

  const healthToken = process.env.HEALTH_TOKEN || '';
  const logGroupPrefix = (process.env.LOG_GROUP_PREFIX || '').trim();

  let config = {};
  try {
    config = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'));
  } catch (e) {
    console.error('[zeus-monitor] Could not read context/config.json:', e.message);
    process.exit(1);
  }

  const projectName = config.projectName || 'unknown';
  const clientName = config.clientName || 'unknown';

  const maintainerEmail = resolveMaintainerEmail();

  const dbResolution = resolveZeusMonitorDatabaseName(
    monitorUri,
    process.env.ZEUS_MONITOR_MONGODB_DATABASE
  );
  if ('error' in dbResolution) {
    console.error(`[zeus-monitor] ${dbResolution.error}`);
    process.exit(1);
  }

  if (dbResolution.notice) {
    console.warn(`[zeus-monitor] ${dbResolution.notice}`);
  }

  const client = new MongoClient(monitorUri, { serverSelectionTimeoutMS: 8000 });
  try {
    await client.connect();
    const db = client.db(dbResolution.dbName);
    const col = db.collection('projects');

    const $set = {
      projectName,
      clientName,
      healthUrl,
      healthToken,
      maintainerEmail,
      updatedAt: new Date(),
    };
    if (logGroupPrefix) {
      $set.logGroupPrefix = logGroupPrefix;
    }

    await col.updateOne(
      { projectName, clientName },
      {
        $set,
        $setOnInsert: { registeredAt: new Date() },
      },
      { upsert: true }
    );

    const logHint = logGroupPrefix ? `, logs: ${logGroupPrefix}*` : '';
    console.log(`[zeus-monitor] Registered "${projectName}" (${clientName}) → ${healthUrl}${logHint}`);
  } finally {
    await client.close();
  }
}

main().catch((err) => {
  console.error('[zeus-monitor] Registration failed:', err.message);
  process.exit(1);
});
