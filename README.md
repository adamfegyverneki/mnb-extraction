# mnb-extract

Daily MNB (Magyar Nemzeti Bank) middle exchange rates for Hungary's top 30 trade currencies, quoted in **HUF**. Deployed as a backend-only AWS microservice with MongoDB Atlas storage.

Rates come from the official MNB SOAP service — one daily publication on Hungarian business days, not live forex ticks.

## Architecture

- **AWS Lambda + API Gateway** (`eu-central-1`) — read API and health
- **EventBridge cron** — fetches rates Mon–Fri at 11:00 UTC (12:00 CET / 13:00 CEST, after MNB midday publish)
- **MongoDB Atlas** — sole data store (`rate_snapshots` collection)
- **Infra subdomain** — `https://mnb-extraction.49x.ai` (S3/CloudFront bucket for Serverless artifacts; API is on API Gateway)

## API endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/health` | Public health (`status`, `mongodb`); full diagnostics with `X-Health-Token` |
| GET | `/api/rates/latest` | Latest stored snapshot |
| GET | `/api/rates/{date}` | Snapshot for `YYYY-MM-DD` |
| GET | `/api/rates` | List of stored snapshot dates |

Base URL after deploy: `https://{api-id}.execute-api.eu-central-1.amazonaws.com/prod`

## Environment variables

Copy [`backend/.env.example`](backend/.env.example) to `backend/.env`. Key variables:

| Variable | Purpose |
|----------|---------|
| `MONGODB_URI` | Atlas connection string (from `mongodb-atlas.sh`) |
| `MONGODB_DB_NAME` | Local dev DB: `49x-mnb-extraction-dev`; prod Lambdas use `49x-mnb-extraction-prod` |
| `HEALTH_TOKEN` | Zeus/authenticated health tier (from S3 secrets) |
| `FRONTEND_ORIGIN` | CORS origin: `https://mnb-extraction.49x.ai` |
| `APP_VERSION` | Shown in authenticated health response |
| `MONGODB_ATLAS_*` | Atlas CLI API keys (from S3 secrets, for cluster setup) |
| `ZEUS_MONITOR_MONGODB_URI` | Fleet dashboard registration (from S3 secrets) |

Prod deploy sets `SERVERLESS_DEPLOYMENT_BUCKET` automatically from the infra stack.

## First-time setup

Prerequisites: Node.js 20+, AWS CLI, Atlas CLI, `jq`, `openssl`.

```bash
npm install
cd backend && npm install && cd ..

# Store Kratos secrets key, pull S3 secrets, create Atlas cluster
chmod +x scripts/initial-setup/setup-env.sh
./scripts/initial-setup/setup-env.sh
```

Or step by step:

```bash
./scripts/initial-setup/secrets-key.sh set   # paste KRATOS_SECRETS_KEY
./scripts/initial-setup/pull-s3-secrets.sh
atlas auth login
MONGODB_ATLAS_NONINTERACTIVE=1 ./scripts/initial-setup/mongodb-atlas.sh --yes
```

## Deploy (backend only)

From the `main` branch:

```bash
./scripts/dev.sh verify backend
./scripts/dev.sh deploy-be
./scripts/dev.sh post-deploy
```

Do **not** run `deploy-fe` (no frontend).

Optional: register with Zeus fleet monitor after post-deploy:

```bash
# Uses VITE_API_URL from frontend/.env_prod + HEALTH_TOKEN from backend/.env
HEALTH_URL="$(grep VITE_API_URL frontend/.env_prod | cut -d= -f2- | tr -d '"')/api/health" \
LOG_GROUP_PREFIX="/aws/lambda/mnb-extraction-prod-" \
DOTENV_CONFIG_PATH=backend/.env \
NODE_PATH=backend/node_modules \
node scripts/monitor/register-project.js
```

## Verify after deploy

```bash
API_URL=$(grep VITE_API_URL frontend/.env_prod | cut -d= -f2- | tr -d '"')
curl "$API_URL/api/health"
curl "$API_URL/api/rates/latest"

# Manual fetch trigger
cd backend && npx serverless invoke -f fetchDaily --stage prod --region eu-central-1

# Tail logs
./scripts/dev.sh logs-be
```

## Daily fetch schedule

EventBridge rule: `cron(0 11 ? * MON-FRI *)` (UTC).

MNB publishes around midday Budapest time on business days. 11:00 UTC runs safely after publication in both CET (12:00) and CEST (13:00).

## Local CLI (optional)

The root CLI still supports local file-based fetch for development:

```bash
npm run fetch
npm run fetch -- --date 2026-06-20
npm run list
```

Production data is stored in MongoDB only.

## MongoDB schema

**Database (prod):** `49x-mnb-extraction-prod`  
**Collection:** `rate_snapshots`

```json
{
  "date": "2026-06-30",
  "fetchedAt": "2026-06-30T11:02:53.411Z",
  "source": "MNB",
  "referenceCurrency": "HUF",
  "rates": [{ "code": "EUR", "huf": 355.05 }],
  "missing": ["RUB"]
}
```

Unique index on `date`.

## Project config

[`context/config.json`](context/config.json):

```json
{
  "clientName": "49x",
  "projectName": "mnb-extraction",
  "subdomainName": "49x-mnb-extraction"
}
```

Effective deploy hostname: `mnb-extraction.49x.ai`.
