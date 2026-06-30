import {
  getCurrencies,
  getCurrentExchangeRates,
  getExchangeRates,
} from "../mnb/client.js";
import { parseRatesXml } from "../mnb/parser.js";
import type { RateSnapshot } from "../mnb/types.js";
import {
  TRADE_CURRENCIES,
  TRADE_CURRENCY_SET,
} from "../config/currencies.js";

function todayIso(): string {
  return new Date().toISOString().slice(0, 10);
}

function isEmptyRatesXml(xml: string): boolean {
  return !/<Day[\s>]/i.test(xml);
}

export async function validateTradeCurrencies(): Promise<string[]> {
  const available = new Set(await getCurrencies());
  const missing = TRADE_CURRENCIES.filter((c) => !available.has(c));
  if (missing.length > 0) {
    console.warn(
      `Warning: MNB does not publish these configured currencies: ${missing.join(", ")}`,
    );
  }
  return missing;
}

async function loadRatesXml(requestedDate?: string): Promise<string> {
  if (requestedDate) {
    const xml = await getExchangeRates(
      requestedDate,
      requestedDate,
      TRADE_CURRENCIES,
    );
    if (!isEmptyRatesXml(xml)) {
      return xml;
    }
    console.warn(
      `No MNB quote for ${requestedDate} (weekend/holiday); using last published rates.`,
    );
  }

  const xml = await getCurrentExchangeRates();
  if (isEmptyRatesXml(xml)) {
    throw new Error("No exchange rate data available from MNB");
  }
  return xml;
}

export async function fetchRates(date?: string): Promise<RateSnapshot> {
  const missingFromMnb = await validateTradeCurrencies();
  const xml = await loadRatesXml(date);
  const parsed = parseRatesXml(xml, TRADE_CURRENCY_SET);

  const foundCodes = new Set(parsed.rates.map((r) => r.code));
  const missingInResponse = TRADE_CURRENCIES.filter((c) => !foundCodes.has(c));

  if (missingInResponse.length > 0) {
    console.warn(
      `Warning: no rate returned for: ${missingInResponse.join(", ")}`,
    );
  }

  const orderMap = new Map(TRADE_CURRENCIES.map((c, i) => [c, i]));
  parsed.rates.sort(
    (a, b) => (orderMap.get(a.code) ?? 999) - (orderMap.get(b.code) ?? 999),
  );

  const allMissing = [
    ...new Set([...missingFromMnb, ...missingInResponse]),
  ].sort();

  return {
    date: parsed.date,
    fetchedAt: new Date().toISOString(),
    source: "MNB",
    referenceCurrency: "HUF",
    rates: parsed.rates,
    ...(allMissing.length > 0 ? { missing: allMissing } : {}),
  };
}
