# WTI relay

A Cloudflare Worker that fetches the WTI crude front-month price every 5 minutes and serves the latest one as JSON. The app polls this instead of calling quote sites itself, so the sites see one poller however many copies of the app run.

Live at `https://wti.oil-price.workers.dev/` once the account's workers.dev subdomain is `oil-price`.

## What it serves

`GET /` returns:

```json
{
  "quote": {
    "price": 93.05,
    "changePercent": 0.19,
    "contract": "CLX26",
    "quoteTime": "2026-10-01T22:57:13.000Z",
    "source": "cnbc"
  },
  "fetchedAt": "2026-10-01T23:10:00.123Z",
  "lastAttempt": { "at": "2026-10-01T23:10:00.123Z", "ok": true, "failures": [] }
}
```

- `quoteTime` is when the exchange quoted the price, if the source says. It's `null` for TradingView. Free sources run about 10 minutes behind.
- `fetchedAt` is when the relay last got a price. If every source fails, the relay keeps the old quote and `fetchedAt`, and `lastAttempt` has `ok: false` with each source's reason.
- Before the first successful fetch, the response is HTTP 503 with `quote: null`.
- `overrides` appears only when test-only source URLs are set. It should never appear in production.

## Sources

Tried in order, first usable price wins: CNBC, Yahoo Finance, TradingView, Google Finance. All are unofficial endpoints, so any of them can change or block without notice. A source fails on any non-2xx status, an empty body, a response it can't parse, a price that isn't a positive number, or no answer within 10 seconds.

## Test

```
npm install
npm test
```

The test runs the Worker locally with `wrangler dev`, points every source at a stub server that serves the captured responses in `test/fixtures/`, fires the cron handler, and checks what the Worker serves. It never contacts a real quote site. It prints PASS/FAIL per check, ends with `ALL PASS` or `FAILED`, and writes the same output to `test/last-run.log`.

The CNBC and TradingView fixtures are real responses captured 2026-10-01. The Google fixture is the quote blob trimmed out of a real 1.2 MB page. The Yahoo fixture is the payload captured for the app's Swift tests, with `regularMarketTime` added; the live endpoint returns that field.

## Deploy

```
npx wrangler deploy
```

Needs `wrangler login` first. The KV namespace (`wti-quotes`) already exists; its id is in `wrangler.toml`. Five-minute runs make 288 KV writes a day, inside the free plan's 1,000.

Logs and run history are in the Cloudflare dashboard under Workers → wti, or live with `npx wrangler tail wti`.
