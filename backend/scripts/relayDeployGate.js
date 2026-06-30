/**
 * Shared logic for deploy-time check: inbound-email must not ship with empty signing secrets.
 * Used by assert-relay-signing-for-deploy.js and Jest tests.
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

/**
 * @param {string} serverlessYml
 * @returns {boolean}
 */
function serverlessHasInboundEmail(serverlessYml) {
  return /^\s*inboundEmail:/m.test(serverlessYml);
}

/**
 * @param {string} serverlessYml
 * @returns {boolean}
 */
function serverlessWiresRelaySigningSecret(serverlessYml) {
  return /RELAY_ROUTER_SIGNING_SECRET:/.test(serverlessYml);
}

/**
 * @param {string} content
 * @param {string} key
 * @returns {string}
 */
function getEnvValueFromDotenv(content, key) {
  if (!content) return '';
  const lines = content.split(/\r?\n/);
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const esc = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const m = trimmed.match(new RegExp(`^${esc}=(.*)$`));
    if (m) {
      let v = m[1] ?? '';
      v = v.replace(/^["']|["']$/g, '').trim();
      return v;
    }
  }
  return '';
}

/**
 * @param {NodeJS.ProcessEnv} processEnv
 * @param {string} envFileContent
 * @returns {boolean}
 */
function signingSecretConfigured(processEnv, envFileContent) {
  const relay = (processEnv.RELAY_ROUTER_SIGNING_SECRET || '').trim();
  const legacy = (processEnv.ROUTER_SIGNING_SECRET || '').trim();
  if (relay || legacy) return true;
  const fr = getEnvValueFromDotenv(envFileContent, 'RELAY_ROUTER_SIGNING_SECRET');
  const fl = getEnvValueFromDotenv(envFileContent, 'ROUTER_SIGNING_SECRET');
  return Boolean((fr || '').trim()) || Boolean((fl || '').trim());
}

/**
 * @param {NodeJS.ProcessEnv} processEnv
 * @returns {boolean}
 */
function skipRelaySigningAssert(processEnv) {
  const a = (processEnv.SKIP_RELAY_SIGNING_ASSERT || '').toLowerCase();
  const b = (processEnv.SKIP_RELAY_ROUTER_SIGNING_ASSERT || '').toLowerCase();
  const v = a || b;
  return v === '1' || v === 'true' || v === 'yes';
}

/**
 * @param {string} serverlessYml
 * @returns {boolean}
 */
function shouldRunRelaySigningAssert(serverlessYml) {
  return serverlessHasInboundEmail(serverlessYml) && serverlessWiresRelaySigningSecret(serverlessYml);
}

/**
 * @param {{ backendDir: string, processEnv?: NodeJS.ProcessEnv, envFileRelPath?: string }} options
 * @returns {{ ok: boolean, skipped?: boolean, warn?: boolean, reason?: string }}
 */
function evaluateRelayDeployGate(options) {
  const backendDir = options.backendDir;
  const processEnv = options.processEnv || process.env;
  const envRel = (options.envFileRelPath || '.env').replace(/^\//, '');
  if (envRel.includes('..')) {
    throw new Error(`invalid envFileRelPath: ${options.envFileRelPath}`);
  }
  const serverlessPath = path.join(backendDir, 'serverless.yml');
  let serverlessYml = '';
  try {
    serverlessYml = fs.readFileSync(serverlessPath, 'utf8');
  } catch {
    return { ok: true, skipped: true, reason: 'serverless.yml not found' };
  }

  if (!shouldRunRelaySigningAssert(serverlessYml)) {
    return { ok: true, skipped: true, reason: 'inbound relay signing not in scope' };
  }

  if (skipRelaySigningAssert(processEnv)) {
    return { ok: true, skipped: true, warn: true, reason: 'SKIP_RELAY_SIGNING_ASSERT or SKIP_RELAY_ROUTER_SIGNING_ASSERT set' };
  }

  let envFileContent = '';
  const envPath = path.join(backendDir, envRel);
  try {
    envFileContent = fs.readFileSync(envPath, 'utf8');
  } catch {
    envFileContent = '';
  }

  if (signingSecretConfigured(processEnv, envFileContent)) {
    return { ok: true };
  }

  return { ok: false, reason: 'RELAY_ROUTER_SIGNING_SECRET and ROUTER_SIGNING_SECRET are both missing or empty' };
}

module.exports = {
  serverlessHasInboundEmail,
  serverlessWiresRelaySigningSecret,
  getEnvValueFromDotenv,
  signingSecretConfigured,
  skipRelaySigningAssert,
  shouldRunRelaySigningAssert,
  evaluateRelayDeployGate,
};
