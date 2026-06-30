import "dotenv/config";
import { fetchRates } from "../services/fetch-rates";
import {
  saveSnapshot,
  snapshotExists,
} from "../storage/rate-snapshots";
import { logger } from "../utils/logger";

function todayIso(): string {
  return new Date().toISOString().slice(0, 10);
}

export async function handler(): Promise<{ statusCode: number; body: string }> {
  try {
    const today = todayIso();
    if (await snapshotExists(today)) {
      logger.info(`Snapshot for ${today} already exists; skipping fetch`);
      return {
        statusCode: 200,
        body: JSON.stringify({
          ok: true,
          skipped: true,
          date: today,
          message: "Snapshot already exists",
        }),
      };
    }

    const snapshot = await fetchRates();
    if (await snapshotExists(snapshot.date)) {
      logger.info(`Snapshot for ${snapshot.date} already exists; skipping save`);
      return {
        statusCode: 200,
        body: JSON.stringify({
          ok: true,
          skipped: true,
          date: snapshot.date,
          message: "Snapshot already exists",
        }),
      };
    }

    await saveSnapshot(snapshot);
    logger.info(
      `Saved ${snapshot.rates.length} rates for ${snapshot.date}`,
    );

    return {
      statusCode: 200,
      body: JSON.stringify({
        ok: true,
        skipped: false,
        date: snapshot.date,
        rateCount: snapshot.rates.length,
        missing: snapshot.missing ?? [],
      }),
    };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    logger.error("Scheduled fetch failed:", message);
    return {
      statusCode: 500,
      body: JSON.stringify({ ok: false, error: message }),
    };
  }
}
