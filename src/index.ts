#!/usr/bin/env node
import { Command } from "commander";
import { CURRENCY_GROUPS } from "./config/currencies.js";
import { fetchRates } from "./services/fetch-rates.js";
import type { RateSnapshot } from "./mnb/types.js";
import {
  listSnapshots,
  saveSnapshot,
  snapshotExists,
} from "./storage/save-rates.js";

function todayIso(): string {
  return new Date().toISOString().slice(0, 10);
}

function printRatesTable(snapshot: RateSnapshot): void {
  console.log(`\nMNB rates for ${snapshot.date} (reference: HUF)\n`);

  const rateMap = new Map(snapshot.rates.map((r) => [r.code, r]));

  for (const group of CURRENCY_GROUPS) {
    console.log(`  ${group.name}`);
    for (const code of group.codes) {
      const rate = rateMap.get(code);
      if (rate) {
        const value = rate.huf.toFixed(4).replace(/\.?0+$/, "");
        console.log(`    ${code.padEnd(4)}  ${value.padStart(12)} HUF`);
      } else {
        console.log(`    ${code.padEnd(4)}  ${"(unavailable)".padStart(12)}`);
      }
    }
    console.log();
  }

  if (snapshot.missing?.length) {
    console.log(`Missing from MNB: ${snapshot.missing.join(", ")}\n`);
  }

  console.log(`Saved ${snapshot.rates.length} rates.`);
}

async function runFetch(options: {
  date?: string;
  force?: boolean;
}): Promise<void> {
  const targetDate = options.date ?? todayIso();

  if (!options.force && (await snapshotExists(targetDate))) {
    console.log(
      `Snapshot for ${targetDate} already exists. Use --force to re-fetch.`,
    );
    process.exit(0);
  }

  const snapshot = await fetchRates(options.date);
  await saveSnapshot(snapshot);
  printRatesTable(snapshot);
}

const program = new Command();

program
  .name("mnb-extract")
  .description(
    "Fetch daily MNB middle exchange rates for Hungary's top 30 trade currencies",
  );

program
  .command("fetch")
  .description("Fetch rates and save JSON + CSV snapshot")
  .option("-d, --date <date>", "Date in YYYY-MM-DD format (default: today)")
  .option("-f, --force", "Re-fetch even if snapshot already exists")
  .action(async (options: { date?: string; force?: boolean }) => {
    try {
      await runFetch(options);
    } catch (err) {
      console.error("Fetch failed:", err instanceof Error ? err.message : err);
      process.exit(1);
    }
  });

program
  .command("list")
  .description("List saved snapshot dates (local data/ only)")
  .action(async () => {
    const dates = await listSnapshots();
    if (dates.length === 0) {
      console.log("No snapshots found in data/");
      return;
    }
    console.log("Saved snapshots:");
    for (const date of dates) {
      console.log(`  ${date}`);
    }
  });

program.parse();
