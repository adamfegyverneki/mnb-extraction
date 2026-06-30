# SST/CDK Infra Project

## How to use

**Config sync:** During setup (`./scripts/dev.sh setup`), `config.ts` and `sst.config.ts` are filled from `context/config.json` plus fixed template values (**49x.ai**, subdomain deploy on, existing bucket if `aws s3api head-bucket` succeeds). Infra is **not** deployed during setup. On **first deploy** (`./scripts/dev.sh deploy`), the deploy script detects the missing infra stack, may prompt only for **subdomainName**, syncs config, then runs **`npm run deploy -- --stage prod`** to create S3 bucket, CloudFront distribution, and Route53 subdomain routing.

To sync config after editing `context/config.json`, run `./scripts/dev.sh setup` again (sync runs after config prompts), or the deploy script will sync before infra deploy when you run `./scripts/dev.sh deploy`.

**`npm run deploy -- --stage prod`**: Run once to set up S3 bucket (frontend + Serverless deploy artifacts), CloudFront and Route53. Invoked automatically by the deploy pipeline on first deploy (see [Deployment](docs/kratos/deployment.md)).

**`npm run upload`**: Run whenever you'd like to update the frontend. Note: input files need to be in the `index.html`, `i.js` and `i.css` format as set in vite config

npm run remove to roll back (in case of a failed deploy)


This project supports a reusable shared AWS infra repo via:

git submodule add https://github.com/YOUR_USERNAME/aws-infra shared

