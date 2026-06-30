const MNB_URL = "http://www.mnb.hu/arfolyamok.asmx";
const NS = "http://www.mnb.hu/webservices/";

function envelope(body: string): string {
  return `<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:web="${NS}">
  <soap:Body>
    ${body}
  </soap:Body>
</soap:Envelope>`;
}

async function soapCall(action: string, body: string): Promise<string> {
  const response = await fetch(MNB_URL, {
    method: "POST",
    headers: {
      "Content-Type": "text/xml; charset=utf-8",
      SOAPAction: `"${NS}${action}"`,
    },
    body: envelope(body),
  });

  if (!response.ok) {
    throw new Error(`MNB SOAP request failed: ${response.status} ${response.statusText}`);
  }

  const xml = await response.text();
  const match = xml.match(/<[^:]*:?Get\w+Result[^>]*>([\s\S]*?)<\/[^:]*:?Get\w+Result>/i);
  if (!match) {
    throw new Error("Could not extract result from MNB SOAP response");
  }

  return decodeHtmlEntities(match[1].trim());
}

function decodeHtmlEntities(text: string): string {
  return text
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'");
}

export async function getCurrencies(): Promise<string[]> {
  const result = await soapCall("GetCurrencies", "<web:GetCurrencies/>");
  const codes = [...result.matchAll(/<Curr[^>]*>([A-Z]{3})<\/Curr>/gi)].map(
    (m) => m[1],
  );
  return codes;
}

export async function getCurrentExchangeRates(): Promise<string> {
  return soapCall("GetCurrentExchangeRates", "<web:GetCurrentExchangeRates/>");
}

export async function getExchangeRates(
  startDate: string,
  endDate: string,
  currencyNames: string[],
): Promise<string> {
  const names = currencyNames.join(",");
  return soapCall(
    "GetExchangeRates",
    `<web:GetExchangeRates>
      <web:startDate>${startDate}</web:startDate>
      <web:endDate>${endDate}</web:endDate>
      <web:currencyNames>${names}</web:currencyNames>
    </web:GetExchangeRates>`,
  );
}
