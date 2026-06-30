# mnb-extract

Daily MNB (Magyar Nemzeti Bank) middle exchange rates for Hungary's top 30 trade currencies, quoted in **HUF**.

Rates come from the official MNB SOAP service — one daily publication on Hungarian business days, not live forex ticks.

## Setup

```bash
npm install
```

Requires Node.js 20+.

## Usage

```bash
# Fetch today's rates (or last published on weekends/holidays)
npm run fetch

# Fetch a specific date
npm run fetch -- --date 2026-06-20

# Re-fetch even if snapshot exists
npm run fetch -- --force

# List saved snapshots
npm run list

# Run daily at 12:00 Mon–Fri (Europe/Budapest)
npm run schedule
```

### Windows Task Scheduler

Create a daily task that runs:

```
cmd /c cd /d C:\path\to\mnb-extract && npm run fetch
```

Schedule for weekdays after 12:00 CET when MNB publishes new rates.

## Output

Snapshots are saved to `data/`:

- `data/YYYY-MM-DD.json` — full snapshot with metadata
- `data/YYYY-MM-DD.csv` — flat table: `date,code,huf`

Each `huf` value means: **1 unit of the foreign currency costs X HUF** (MNB per-100 quotes are normalized during fetch).

## Top 30 currencies

| Group | Codes |
|-------|-------|
| Core EU & global | EUR, USD, GBP, CHF |
| Central/Eastern Europe | PLN, CZK, RON, RSD, UAH |
| Regional | TRY, RUB |
| EU Nordics | SEK, NOK, DKK |
| Asia — manufacturing | CNY, JPY, KRW, INR, SGD, THB, HKD, MYR, IDR |
| Americas | CAD, AUD, BRL, MXN |
| Middle East & other | ILS, ZAR, NZD |

Edit `src/config/currencies.ts` to change the list.

## Notes

- MNB quotes some currencies (JPY, KRW, IDR) per 100 units; the app normalizes these to HUF per 1 unit in the saved output.
- On weekends/holidays, MNB returns the last business day's rates — the `date` field reflects the actual quote date.
- If MNB stops publishing a currency (e.g. RUB), a warning is printed and that code is marked unavailable.

## Data source

[MNB Exchange Rate Web Service](http://www.mnb.hu/arfolyamok.asmx)
