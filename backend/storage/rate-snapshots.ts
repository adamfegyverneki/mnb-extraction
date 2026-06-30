import type { Collection, Db } from "mongodb";
import { connectToDatabase } from "../utils/mongodb";
import type { RateSnapshot } from "../mnb/types";
import { logger } from "../utils/logger";

const COLLECTION = "rate_snapshots";

let indexesEnsured = false;

async function collection(): Promise<Collection<RateSnapshot>> {
  const db: Db = await connectToDatabase();
  const col = db.collection<RateSnapshot>(COLLECTION);

  if (!indexesEnsured) {
    await col.createIndex({ date: 1 }, { unique: true });
    await col.createIndex({ fetchedAt: -1 });
    indexesEnsured = true;
    logger.debug("Ensured rate_snapshots indexes");
  }

  return col;
}

export async function snapshotExists(date: string): Promise<boolean> {
  const col = await collection();
  const doc = await col.findOne({ date }, { projection: { _id: 1 } });
  return doc !== null;
}

export async function saveSnapshot(snapshot: RateSnapshot): Promise<void> {
  const col = await collection();
  await col.replaceOne({ date: snapshot.date }, snapshot, { upsert: true });
}

export async function loadSnapshot(date: string): Promise<RateSnapshot | null> {
  const col = await collection();
  return col.findOne({ date });
}

export async function loadLatestSnapshot(): Promise<RateSnapshot | null> {
  const col = await collection();
  return col.findOne({}, { sort: { date: -1 } });
}

export async function listSnapshotDates(limit = 100): Promise<string[]> {
  const col = await collection();
  const docs = await col
    .find({}, { projection: { date: 1 }, sort: { date: -1 }, limit })
    .toArray();
  return docs.map((d) => d.date);
}
