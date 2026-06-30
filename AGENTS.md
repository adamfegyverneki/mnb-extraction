# mnb-extract

A small Node.js + TypeScript CLI that fetches daily MNB (Magyar Nemzeti Bank) middle exchange rates for Hungary's top 30 trade currencies and saves JSON + CSV snapshots to `data/`. See `README.md` for usage.

## Cursor Cloud specific instructions

- Single CLI service; no server, database, or web UI. Commands are defined in `package.json` scripts and documented in `README.md`.
- Requires Node.js 20+ (VM has Node 22).
- `npm run fetch` makes a live SOAP request to the public MNB endpoint (`http://www.mnb.hu/arfolyamok.asmx`); it needs outbound network access and will fail without it. Output snapshots land in `data/`, which is gitignored.
- `npm run fetch` skips work if a snapshot for the date already exists; use `npm run fetch -- --force` to re-fetch.
- `npm run schedule` starts a long-running cron process (blocks until Ctrl+C); run it in a background/tmux session, not as a foreground one-shot.
- No lint or automated test setup exists in this repo. The only build check is `npm run build` (`tsc`).
