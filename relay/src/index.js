// WTI relay: every few minutes, fetch the WTI crude front-month price from the first source that
// answers, store it in KV, and serve it as JSON to the OilPriceTicker app.
//
// Serving one stored value means the upstream sites see one poller, however many copies of the app
// run. If every source fails, the last good price is kept but never refreshed: `fetchedAt` stays at
// the old fetch and `lastAttempt` says what went wrong, so the app can mark it stale.

const BROWSER_UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36';

const DEFAULT_TIMEOUT_MS = 10_000;

/** A parse problem: the source answered, but not with a usable quote. */
class Unexpected extends Error {}

// Tried in order. All are unofficial endpoints that give the front-month future about 10 minutes
// delayed. Google is last because its page is about 1.2 MB to download and search.
const SOURCES = [
  {
    name: 'cnbc',
    url: 'https://quote.cnbc.com/quote-html-webservice/restQuote/symbolType/symbol?symbols=%40CL.1&requestMethod=itv&noform=1&partnerId=2&fund=1&exthrs=1&output=json&events=1',
    parse(body) {
      const q = JSON.parse(body)?.FormattedQuoteResult?.FormattedQuote?.[0];
      if (!q) throw new Unexpected('no FormattedQuote entry');
      return {
        price: Number(q.last),
        changePercent: q.change_pct == null ? null : Number(String(q.change_pct).replace('%', '')),
        contract: q.altSymbol ?? null,
        // "2026-10-01T18:41:09.000-0400": add the colon to the offset so every runtime parses it.
        quoteTime: q.last_time ? isoOrNull(String(q.last_time).replace(/([+-]\d\d)(\d\d)$/, '$1:$2')) : null,
      };
    },
  },
  {
    name: 'yahoo',
    url: 'https://query1.finance.yahoo.com/v8/finance/chart/CL=F?interval=1d&range=1d',
    parse(body) {
      const chart = JSON.parse(body)?.chart;
      if (chart?.error) throw new Unexpected(`feed error: ${chart.error.description ?? chart.error.code}`);
      const meta = chart?.result?.[0]?.meta;
      if (!meta) throw new Unexpected('no chart result');
      return {
        price: meta.regularMarketPrice,
        changePercent: meta.regularMarketChangePercent ?? null,
        contract: meta.shortName ?? null,
        quoteTime: meta.regularMarketTime ? new Date(meta.regularMarketTime * 1000).toISOString() : null,
      };
    },
  },
  {
    name: 'tradingview',
    url: 'https://scanner.tradingview.com/symbol?symbol=NYMEX:CL1!&fields=close,description,update_mode',
    parse(body) {
      const j = JSON.parse(body);
      return { price: j?.close, changePercent: null, contract: null, quoteTime: null };
    },
  },
  {
    name: 'google',
    url: 'https://www.google.com/finance/quote/CLW00:NYMEX',
    parse(body) {
      // Positional data in the page's embedded quote blob: [price, change, change %, ...], then
      // previous close, then [quote time in epoch seconds].
      const m = body.match(
        /\["CLW00","NYMEX"\],"Crude Oil",\d+,"USD",\[([\d.]+),[-\d.e]+,([-\d.e]+)[^\]]*\],null,[\d.]+,null,null,null,\[(\d+)\]/,
      );
      if (!m) throw new Unexpected('quote blob not found');
      return {
        price: Math.round(Number(m[1]) * 100) / 100,
        changePercent: Math.round(Number(m[2]) * 100) / 100,
        contract: null,
        quoteTime: new Date(Number(m[3]) * 1000).toISOString(),
      };
    },
  },
];

function isoOrNull(s) {
  const t = Date.parse(s);
  return Number.isNaN(t) ? null : new Date(t).toISOString();
}

/** Source list with any `<NAME>_URL` overrides from the environment applied (tests only). */
function sourcesFor(env) {
  return SOURCES.map(s => ({ ...s, url: env[`${s.name.toUpperCase()}_URL`] ?? s.url }));
}

function overridesIn(env) {
  return SOURCES.filter(s => env[`${s.name.toUpperCase()}_URL`]).map(s => s.name);
}

/** One attempt at one source. Resolves to a quote, or throws an Error whose message is the reason. */
async function fetchFrom(src, timeoutMs) {
  let res, body;
  try {
    res = await fetch(src.url, {
      headers: { 'User-Agent': BROWSER_UA, Accept: 'application/json,text/html' },
      signal: AbortSignal.timeout(timeoutMs),
    });
    body = await res.text();
  } catch (e) {
    if (e?.name === 'TimeoutError' || e?.name === 'AbortError') throw new Error(`timed out after ${timeoutMs} ms`);
    throw new Error(`network: ${e?.message ?? e}`);
  }
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  // A 2xx with nothing in it is how Barchart's bot wall answered; never treat it as a quote.
  if (body.length === 0) throw new Error(`empty body (HTTP ${res.status})`);
  let q;
  try {
    q = src.parse(body);
  } catch (e) {
    throw new Error(`unexpected response: ${e.message} (${body.slice(0, 60).replace(/\s+/g, ' ')})`);
  }
  if (typeof q.price !== 'number' || !Number.isFinite(q.price) || q.price <= 0) {
    throw new Error(`unexpected response: no usable price (${q.price})`);
  }
  return { ...q, source: src.name };
}

/** The cron job: try each source in order, store the first quote, record every failure. */
async function refresh(env) {
  const timeoutMs = Number(env.TIMEOUT_MS ?? DEFAULT_TIMEOUT_MS);
  const failures = [];
  let quote = null;
  for (const src of sourcesFor(env)) {
    try {
      quote = await fetchFrom(src, timeoutMs);
      break;
    } catch (e) {
      failures.push({ source: src.name, reason: e.message });
      console.error(`source ${src.name} failed: ${e.message}`);
    }
  }

  const now = new Date().toISOString();
  const prev = await env.QUOTES.get('latest', 'json');
  const record = {
    quote: quote ?? prev?.quote ?? null,
    fetchedAt: quote ? now : prev?.fetchedAt ?? null,
    lastAttempt: { at: now, ok: quote !== null, failures },
  };
  await env.QUOTES.put('latest', JSON.stringify(record));
  if (quote) console.log(`stored ${quote.price} from ${quote.source}`);
  else console.error(`all sources failed; kept the quote fetched at ${record.fetchedAt ?? 'never'}`);
}

export default {
  async scheduled(_event, env, ctx) {
    ctx.waitUntil(refresh(env));
  },

  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== '/') return Response.json({ error: 'not found' }, { status: 404 });

    const record = await env.QUOTES.get('latest', 'json');
    const overrides = overridesIn(env);
    const body = record ?? {
      quote: null,
      fetchedAt: null,
      lastAttempt: null,
      error: 'no quote fetched yet',
    };
    // Only present when test overrides are active, so a misconfigured deploy can't hide it.
    if (overrides.length) body.overrides = overrides;
    return Response.json(body, {
      status: body.quote ? 200 : 503,
      headers: { 'Cache-Control': 'no-store', 'Access-Control-Allow-Origin': '*' },
    });
  },
};
