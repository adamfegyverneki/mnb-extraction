/**
 * Pure helpers for Zeus maintainer email resolution (no I/O).
 * Used by register-project.js and backend unit tests.
 */

'use strict';

/** Local part contains a GitHub app/bot marker, e.g. github-actions[bot]@… */
const BOT_LOCAL_PART = /\[bot\]/i;

/** Known non-[bot] automation identities */
const AUTOMATION_LOCAL_EXACT = new Set(
  ['dependabot', 'dependabot-preview', 'greenkeeper', 'renovate'].map((s) => s.toLowerCase())
);

function isAutomatedProcessEmail(raw) {
  if (!raw || raw === 'null') return false;
  const email = String(raw).trim();
  if (!email) return false;
  const l = email.toLowerCase();
  if (BOT_LOCAL_PART.test(email)) return true;
  if (l.includes('dependabot[bot]')) return true;
  if (l.startsWith('dependabot@')) return true;
  const at = l.lastIndexOf('@');
  if (at > 0) {
    const local = l.slice(0, at);
    if (AUTOMATION_LOCAL_EXACT.has(local)) return true;
  }
  return false;
}

function isUsableMaintainerEmail(raw) {
  if (!raw || raw === 'null') return false;
  const email = String(raw).trim();
  if (!email) return false;
  return !isAutomatedProcessEmail(email);
}

/**
 * GitHub `login` for an automation account (not a human developer).
 */
function isGitHubBotLogin(login) {
  if (!login || typeof login !== 'string') return true;
  const l = login.trim();
  if (!l) return true;
  if (BOT_LOCAL_PART.test(l)) return true;
  const lower = l.toLowerCase();
  if (lower === 'dependabot-preview' || lower === 'greenkeeperio') return true;
  return false;
}

/**
 * `GET /user` JSON: reject Bots and missing login.
 */
function isGitHubBotAccount(user) {
  if (!user || typeof user !== 'object') return true;
  if (user.type === 'Bot') return true;
  return isGitHubBotLogin(user.login);
}

/**
 * Pick best email from `GET /user/emails` payload (array of { email, primary, verified }).
 */
function pickEmailFromGhEmailsList(emails) {
  if (!Array.isArray(emails)) return '';
  const verified = emails.filter((e) => e && e.verified === true && typeof e.email === 'string');
  const primary = verified.find((e) => e.primary === true && isUsableMaintainerEmail(e.email));
  if (primary) return primary.email.trim();
  const any = verified.find((e) => isUsableMaintainerEmail(e.email));
  return any ? any.email.trim() : '';
}

/**
 * First usable author email from `git log --format=%ae` output (one email per line).
 */
function firstUsableAuthorEmailFromGitLogLines(text, maxLines) {
  if (!text || typeof text !== 'string') return '';
  const limit = typeof maxLines === 'number' && maxLines > 0 ? maxLines : 80;
  const seen = new Set();
  const lines = text.split(/\r?\n/);
  let n = 0;
  for (const line of lines) {
    const e = line.trim();
    if (!e) continue;
    if (seen.has(e)) continue;
    seen.add(e);
    n += 1;
    if (n > limit) break;
    if (isUsableMaintainerEmail(e)) return e;
  }
  return '';
}

module.exports = {
  isAutomatedProcessEmail,
  isUsableMaintainerEmail,
  isGitHubBotLogin,
  isGitHubBotAccount,
  pickEmailFromGhEmailsList,
  firstUsableAuthorEmailFromGitLogLines,
};
