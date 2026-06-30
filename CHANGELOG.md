# Changelog

## 1.0.0

- AWS microservice deployment (Lambda + API Gateway + EventBridge)
- MongoDB Atlas storage for MNB exchange rate snapshots
- Read API: `/api/rates/latest`, `/api/rates/{date}`, `/api/rates`
- Health endpoint: `/api/health`
- Daily fetch cron: Mon–Fri 11:00 UTC (after MNB midday publish)
