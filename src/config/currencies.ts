export interface CurrencyGroup {
  name: string;
  codes: string[];
}

/** Top 30 currencies relevant to Hungarian trade, grouped by role. */
export const CURRENCY_GROUPS: CurrencyGroup[] = [
  {
    name: "Core EU & global",
    codes: ["EUR", "USD", "GBP", "CHF"],
  },
  {
    name: "Central/Eastern Europe",
    codes: ["PLN", "CZK", "RON", "RSD", "UAH"],
  },
  {
    name: "Regional",
    codes: ["TRY", "RUB"],
  },
  {
    name: "EU Nordics",
    codes: ["SEK", "NOK", "DKK"],
  },
  {
    name: "Asia — manufacturing",
    codes: ["CNY", "JPY", "KRW", "INR", "SGD", "THB", "HKD", "MYR", "IDR"],
  },
  {
    name: "Americas",
    codes: ["CAD", "AUD", "BRL", "MXN"],
  },
  {
    name: "Middle East & other",
    codes: ["ILS", "ZAR", "NZD"],
  },
];

export const TRADE_CURRENCIES: string[] = CURRENCY_GROUPS.flatMap(
  (g) => g.codes,
);

export const TRADE_CURRENCY_SET = new Set(TRADE_CURRENCIES);
