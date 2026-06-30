import { mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { RateSnapshot } from "../mnb/types.js";

const DATA_DIR = join(process.cwd(), "data");

export function snapshotPath(date: string, ext: "json" | "csv"): string {
  return join(DATA_DIR, `${date}.${ext}`);
}

export async function snapshotExists(date: string): Promise<boolean> {
  try {
    await readFile(snapshotPath(date, "json"));
    return true;
  } catch {
    return false;
  }
}

export async function saveSnapshot(snapshot: RateSnapshot): Promise<void> {
  await mkdir(DATA_DIR, { recursive: true });

  const jsonPath = snapshotPath(snapshot.date, "json");
  await writeFile(jsonPath, JSON.stringify(snapshot, null, 2) + "\n", "utf-8");

  const csvLines = [
    "date,code,huf",
    ...snapshot.rates.map(
      (r) => `${snapshot.date},${r.code},${r.huf}`,
    ),
  ];
  const csvPath = snapshotPath(snapshot.date, "csv");
  await writeFile(csvPath, csvLines.join("\n") + "\n", "utf-8");
}

export async function listSnapshots(): Promise<string[]> {
  try {
    const files = await readdir(DATA_DIR);
    return files
      .filter((f: string) => f.endsWith(".json"))
      .map((f: string) => f.replace(".json", ""))
      .sort()
      .reverse();
  } catch {
    return [];
  }
}

export async function loadSnapshot(date: string): Promise<RateSnapshot> {
  const content = await readFile(snapshotPath(date, "json"), "utf-8");
  return JSON.parse(content) as RateSnapshot;
}
