export interface CurrencyRate {
  code: string;
  huf: number;
}

export interface RateSnapshot {
  date: string;
  fetchedAt: string;
  source: "MNB";
  referenceCurrency: "HUF";
  rates: CurrencyRate[];
  missing?: string[];
}
