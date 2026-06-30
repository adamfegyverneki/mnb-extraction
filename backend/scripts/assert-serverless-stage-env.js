#!/usr/bin/env node
/**
 * Validates stage dotenv before Serverless deploy (MongoDB + deploy bucket only).
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { getEnvValueFromDotenv } = require('./relayDeployGate');

function envVarsWithoutDefault(serverlessYml) {
  const required = new Set();
  const re = /\$\{env:([A-Z][A-Z0-9_]*)\s*([^}]*)\}/g;
  let m;
  while ((m = re.exec(serverlessYml)) !== null) {
    const rest = (m[2] || '').trim();
    if (rest.startsWith(',')) continue;
    required.add(m[1]);
  }
  return [...required];
}

function resolvedValue(key, mergedContent, env) {
  const fromProc = (env[key] ?? '').trim();
  if (fromProc) return fromProc;
  return getEnvValueFromDotenv(mergedContent, key);
}

function assertServerlessStageEnv(options) {
  const { stage, backendDir } = options;
  const envName = stage === 'prod' ? '.env.prod' : '.env.staging';
  const mergedPath = path.join(backendDir, envName);
  if (!fs.existsSync(mergedPath)) {
    throw new Error(`missing ${mergedPath} — run mergeServerlessStageEnv.js --stage ${stage} first`);
  }
  const merged = fs.readFileSync(mergedPath, 'utf8');
  const slsPath = path.join(backendDir, 'serverless.yml');
  const serverlessYml = fs.readFileSync(slsPath, 'utf8');
  const env = process.env;
  const errors = [];

  const mongoUri = resolvedValue('MONGODB_URI', merged, env);
  if (!mongoUri) errors.push('MONGODB_URI is empty');

  const mongoDb = resolvedValue('MONGODB_DB_NAME', merged, env);
  if (!mongoDb) errors.push('MONGODB_DB_NAME is empty after merge');

  const deployBucket = (resolvedValue('SERVERLESS_DEPLOYMENT_BUCKET', merged, env) || '').trim();
  if (!deployBucket) {
    errors.push('SERVERLESS_DEPLOYMENT_BUCKET is empty — use ./scripts/dev.sh deploy-be');
  } else if (deployBucket === 'serverless-offline-local') {
    errors.push('SERVERLESS_DEPLOYMENT_BUCKET must not be serverless-offline-local for AWS deploys');
  }

  const explicitChecked = new Set(['MONGODB_URI', 'MONGODB_DB_NAME', 'SERVERLESS_DEPLOYMENT_BUCKET']);
  for (const key of envVarsWithoutDefault(serverlessYml).filter((k) => !explicitChecked.has(k))) {
    const v = resolvedValue(key, merged, env);
    if (!v) {
      errors.push(`${key} is required by serverless.yml but is empty`);
    }
  }

  if (errors.length) {
    console.error(`[assert-serverless-stage-env] Deploy aborted for stage=${stage}:`);
    errors.forEach((e) => console.error(`  - ${e}`));
    throw new Error('serverless stage env validation failed');
  }

  console.log(`[assert-serverless-stage-env] OK (${envName}, stage=${stage})`);
}

if (require.main === module) {
  const skip = (process.env.SKIP_SERVERLESS_STAGE_ENV_ASSERT || '').toLowerCase();
  if (skip === '1' || skip === 'true' || skip === 'yes') {
    console.warn('[assert-serverless-stage-env] Skipped');
    process.exit(0);
  }
  const stage = process.argv.includes('--stage') ? process.argv[process.argv.indexOf('--stage') + 1] : null;
  if (stage !== 'prod' && stage !== 'staging') {
    console.error('Usage: node assert-serverless-stage-env.js --stage prod|staging');
    process.exit(1);
  }
  try {
    assertServerlessStageEnv({ stage, backendDir: path.resolve(__dirname, '..') });
  } catch (e) {
    console.error(e instanceof Error ? e.message : String(e));
    process.exit(1);
  }
}

module.exports = { assertServerlessStageEnv };
