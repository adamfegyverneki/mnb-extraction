#!/usr/bin/env node
/**
 * Serverless Framework v3 loads either backend/.env OR backend/.env.[stage], not both.
 * Deploy scripts used to write .env.prod / .env.staging with only MONGODB_* lines, which
 * dropped every other key from .env at deploy time (e.g. RELAY_ROUTER_SIGNING_SECRET).
 *
 * This script merges: full contents of backend/.env minus MONGODB_URI / MONGODB_DB_NAME lines,
 * then appends stage-correct MONGODB_URI (from .env) and MONGODB_DB_NAME from context/config.json.
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { getEnvValueFromDotenv } = require('./relayDeployGate');

const SETUP_ONLY_ENV_KEYS = ['OPENAI_ADMIN_KEY'];

/**
 * @param {string} content
 * @returns {string}
 */
function stripMongoAssignmentLines(content) {
  return content
    .split(/\r?\n/)
    .filter((line) => {
      if (/^\s*MONGODB_URI\s*=/.test(line)) return false;
      if (/^\s*MONGODB_DB_NAME\s*=/.test(line)) return false;
      return true;
    })
    .join('\n');
}

/**
 * Remove `…_PRODUCTION=` / `…_STAGING=` lines (consumed as stage overrides; never pass through verbatim).
 * @param {string} content
 * @returns {string}
 */
function stripStageSuffixAssignmentLines(content) {
  return content
    .split(/\r?\n/)
    .filter((line) => !/^\s*.+_(PRODUCTION|STAGING)\s*=/.test(line))
    .join('\n');
}

/**
 * @param {string} value
 * @returns {string}
 */
function stripOuterQuotes(value) {
  let v = String(value ?? '').trim();
  v = v.replace(/^["']|["']$/g, '').trim();
  return v;
}

/**
 * @param {string} content
 * @param {'prod' | 'staging'} stage
 * @returns {Map<string, string>}
 */
function parseStageSuffixOverrides(content, stage) {
  const suffix = stage === 'prod' ? '_PRODUCTION' : '_STAGING';
  const needle = `${suffix}=`;
  const out = new Map();
  for (const line of content.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq === -1) continue;
    const keyPart = trimmed.slice(0, eq).trim();
    if (!keyPart.endsWith(suffix)) continue;
    const baseKey = keyPart.slice(0, -suffix.length);
    if (!/^[A-Z][A-Z0-9_]*$/.test(baseKey)) continue;
    out.set(baseKey, stripOuterQuotes(trimmed.slice(eq + 1)));
  }
  return out;
}

/**
 * @param {string} content
 * @param {string} key
 * @returns {string}
 */
function stripKeyAssignmentLine(content, key) {
  const esc = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const re = new RegExp(`^\\s*${esc}\\s*=`);
  return content
    .split(/\r?\n/)
    .filter((line) => !re.test(line))
    .join('\n');
}

/**
 * @param {string} content
 * @returns {string}
 */
function stripSetupOnlyAssignmentLines(content) {
  return SETUP_ONLY_ENV_KEYS.reduce(
    (nextContent, key) => stripKeyAssignmentLine(nextContent, key),
    content
  );
}

/**
 * @param {{ backendDir: string, configPath: string, stage: 'prod' | 'staging' }} options
 * @returns {{ outPath: string, mongoUri: string, dbName: string }}
 */
function mergeServerlessStageEnv(options) {
  const { backendDir, configPath, stage } = options;
  if (stage !== 'prod' && stage !== 'staging') {
    throw new Error(`stage must be "prod" or "staging", got: ${stage}`);
  }

  const envPath = path.join(backendDir, '.env');
  if (!fs.existsSync(envPath)) {
    throw new Error(`missing ${envPath}`);
  }

  const envContent = fs.readFileSync(envPath, 'utf8');
  const suffixOverrides = parseStageSuffixOverrides(envContent, stage);

  const mongoUriFromSuffix = suffixOverrides.get('MONGODB_URI');
  const mongoUri = (mongoUriFromSuffix && mongoUriFromSuffix.trim()) || getEnvValueFromDotenv(envContent, 'MONGODB_URI');
  if (!mongoUri.trim()) {
    throw new Error(`MONGODB_URI missing or empty in ${envPath} (or ${stage === 'prod' ? 'MONGODB_URI_PRODUCTION' : 'MONGODB_URI_STAGING'})`);
  }

  if (!fs.existsSync(configPath)) {
    throw new Error(`missing ${configPath}`);
  }

  const cfg = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  const client = String(cfg.clientName ?? 'app').trim() || 'app';
  const project = String(cfg.projectName ?? 'app').trim() || 'app';
  const tier = stage === 'prod' ? 'prod' : 'staging';
  const dbNameFromSuffix = suffixOverrides.get('MONGODB_DB_NAME');
  const dbName =
    (dbNameFromSuffix && dbNameFromSuffix.trim()) || `${client}-${project}-${tier}`;

  let body = stripSetupOnlyAssignmentLines(stripMongoAssignmentLines(stripStageSuffixAssignmentLines(envContent)));

  for (const [key, val] of suffixOverrides) {
    if (key === 'MONGODB_URI' || key === 'MONGODB_DB_NAME') continue;
    body = stripKeyAssignmentLine(body, key);
    const line = `${key}=${val}\n`;
    if (body.length > 0 && !body.endsWith('\n')) {
      body += '\n';
    }
    body += line;
  }

  if (body.length > 0 && !body.endsWith('\n')) {
    body += '\n';
  }
  body += `MONGODB_URI=${mongoUri}\n`;
  body += `MONGODB_DB_NAME=${dbName}\n`;

  const outName = stage === 'prod' ? '.env.prod' : '.env.staging';
  const outPath = path.join(backendDir, outName);
  fs.writeFileSync(outPath, body, 'utf8');
  console.log(`[merge-serverless-stage-env] Wrote ${outPath} (merged .env + stage=${stage} MONGODB_*)`);

  return { outPath, mongoUri, dbName };
}

/**
 * @param {string[]} argv
 */
function parseArgs(argv) {
  let stage;
  let backendDir;
  let configPath;
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--stage' && argv[i + 1]) {
      stage = argv[++i];
      continue;
    }
    if (a === '--backend-dir' && argv[i + 1]) {
      backendDir = argv[++i];
      continue;
    }
    if (a === '--config' && argv[i + 1]) {
      configPath = argv[++i];
      continue;
    }
  }
  return { stage, backendDir, configPath };
}

if (require.main === module) {
  try {
    const { stage, backendDir: bdArg, configPath: cfArg } = parseArgs(process.argv);
    if (!stage) {
      console.error(
        'Usage: node mergeServerlessStageEnv.js --stage prod|staging [--backend-dir path] [--config path]'
      );
      process.exit(1);
    }
    const backendDir = bdArg ? path.resolve(bdArg) : path.resolve(__dirname, '..');
    const configPath =
      cfArg ||
      process.env.KRATOS_CONFIG_PATH ||
      path.join(backendDir, '..', 'context', 'config.json');

    mergeServerlessStageEnv({
      backendDir,
      configPath: path.resolve(configPath),
      stage,
    });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error(`[merge-serverless-stage-env] ${msg}`);
    process.exit(1);
  }
}

module.exports = {
  mergeServerlessStageEnv,
  stripMongoAssignmentLines,
  stripStageSuffixAssignmentLines,
  parseStageSuffixOverrides,
  stripKeyAssignmentLine,
  stripSetupOnlyAssignmentLines,
};
