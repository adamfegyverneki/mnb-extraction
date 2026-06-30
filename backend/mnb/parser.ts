import { XMLParser } from "fast-xml-parser";
import type { CurrencyRate } from "./types";

const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: "@_",
});

function parseDecimal(value: string): number {
  return Number(value.replace(",", "."));
}

interface RawRate {
  "@_unit"?: string;
  "@_curr"?: string;
  "#text"?: string;
}

interface RawDay {
  "@_date"?: string;
  Rate?: RawRate | RawRate[];
}

export function parseRatesXml(
  xml: string,
  filterCodes?: Set<string>,
): { date: string; rates: CurrencyRate[] } {
  const parsed = parser.parse(xml) as {
    MNBExchangeRates?: { Day?: RawDay | RawDay[] };
    MNBCurrentExchangeRates?: { Day?: RawDay | RawDay[] };
  };
  const root = parsed.MNBExchangeRates ?? parsed.MNBCurrentExchangeRates;
  const dayNode = root?.Day;

  if (!dayNode) {
    throw new Error("No exchange rate data in MNB response");
  }

  const days = Array.isArray(dayNode) ? dayNode : [dayNode];
  const latest = days[days.length - 1];
  const date = latest["@_date"] ?? "";

  const rawRates = latest.Rate;
  const rateList = rawRates
    ? Array.isArray(rawRates)
      ? rawRates
      : [rawRates]
    : [];

  const rates: CurrencyRate[] = [];

  for (const rate of rateList) {
    const code = rate["@_curr"];
    const text = rate["#text"];
    if (!code || text === undefined) continue;
    if (filterCodes && !filterCodes.has(code)) continue;

    const unit = Number(rate["@_unit"] ?? "1");
    const rawValue = parseDecimal(String(text));
    const huf = rawValue / unit;

    rates.push({ code, huf });
  }

  rates.sort((a, b) => a.code.localeCompare(b.code));
  return { date, rates };
}
