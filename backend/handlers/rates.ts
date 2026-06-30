import "dotenv/config";
import { success, error } from "../utils/response";
import {
  loadLatestSnapshot,
  loadSnapshot,
  listSnapshotDates,
} from "../storage/rate-snapshots";

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

type ApiGatewayLikeEvent = {
  httpMethod?: string;
  pathParameters?: { date?: string };
};

export const ratesLatest = async (event: unknown) => {
  const e = event as ApiGatewayLikeEvent;
  if (e.httpMethod?.toUpperCase() !== "GET") {
    return error("Method not allowed", 405);
  }

  const snapshot = await loadLatestSnapshot();
  if (!snapshot) {
    return error("No rate snapshots found", 404);
  }

  return success(snapshot);
};

export const ratesByDate = async (event: unknown) => {
  const e = event as ApiGatewayLikeEvent;
  if (e.httpMethod?.toUpperCase() !== "GET") {
    return error("Method not allowed", 405);
  }

  const date = e.pathParameters?.date?.trim();
  if (!date || !DATE_RE.test(date)) {
    return error("Invalid date; use YYYY-MM-DD", 400);
  }

  const snapshot = await loadSnapshot(date);
  if (!snapshot) {
    return error(`No snapshot for ${date}`, 404);
  }

  return success(snapshot);
};

export const ratesList = async (event: unknown) => {
  const e = event as ApiGatewayLikeEvent;
  if (e.httpMethod?.toUpperCase() !== "GET") {
    return error("Method not allowed", 405);
  }

  const dates = await listSnapshotDates();
  return success({ dates, count: dates.length });
};
