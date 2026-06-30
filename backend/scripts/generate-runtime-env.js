#!/usr/bin/env node

const fs = require("node:fs");
const path = require("node:path");

const backendDir = path.resolve(__dirname, "..");
const sourceFromEnv = (process.env.KRATOS_RUNTIME_ENV_SOURCE || "").trim();
const sourcePath = sourceFromEnv
  ? path.isAbsolute(sourceFromEnv)
    ? sourceFromEnv
    : path.join(backendDir, sourceFromEnv)
  : path.join(backendDir, ".env");
const targetPath = path.join(backendDir, ".env.runtime");
const allowPlaceholderEnv = process.env.VERIFY_ALLOW_PLACEHOLDER_ENV === "1";

function writeRuntimeEnv(content, message) {
  const output = content.endsWith("\n") ? content : `${content}\n`;
  fs.writeFileSync(targetPath, output, "utf8");
  console.log(message);
}

function fail(message) {
  console.error(`[env-runtime] ${message}`);
  process.exit(1);
}

if (!fs.existsSync(sourcePath)) {
  if (!allowPlaceholderEnv) {
    const hint = sourceFromEnv
      ? `Missing KRATOS_RUNTIME_ENV_SOURCE file: ${sourcePath}. Run mergeServerlessStageEnv.js for this stage first.`
      : `Missing source file: ${sourcePath}. Run ./scripts/dev.sh setup first.`;
    fail(hint);
  }

  const placeholderContent = [
    "MONGODB_URI=mongodb://localhost:27017/app",
    "MONGODB_DB_NAME=49x-mnb-extraction-dev",
    "HEALTH_TOKEN=verify-placeholder",
  ].join("\n");
  writeRuntimeEnv(
    placeholderContent,
    `[env-runtime] Wrote ${targetPath} with placeholder values for local verify`
  );
  process.exit(0);
}

const sourceContent = fs.readFileSync(sourcePath, "utf8");
const keyCount = sourceContent
  .split(/\r?\n/)
  .map((line) => line.trim())
  .filter((line) => line && !line.startsWith("#") && line.includes("=")).length;

if (keyCount === 0) {
  fail(`No environment keys found in ${sourcePath}.`);
}

const output = sourceContent.endsWith("\n") ? sourceContent : `${sourceContent}\n`;
const srcLabel = sourceFromEnv ? `from ${sourceFromEnv}` : "from .env";
writeRuntimeEnv(output, `[env-runtime] Wrote ${targetPath} (${keyCount} keys, ${srcLabel})`);
