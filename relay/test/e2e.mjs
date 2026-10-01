// End-to-end test for the relay Worker.
//
// Runs the real Worker locally (`wrangler dev`) with each source's URL pointed at a stub server
// that serves captured real responses, so no test ever depends on a live quote site. Each case sets
// how every source behaves, fires the cron handler, then reads what the Worker serves.
//
// Ways the relay can fail, each covered below:
//  1. Nothing fetched yet, but it answers as if it has a price.
//  2. It misreads a good source (wrong price, contract, quote time or change).
//  3. A source errors (HTTP 500) and the relay gives up instead of trying the next one.
//  4. A source answers 202 with an empty body (how Barchart died) and that counts as success.
//  5. A source returns 200 with junk, or a price of 0, and that counts as success.
//  6. A rate limit (429) on one source blocks the rest.
//  7. Only the last fallback works and the relay doesn't reach it.
//  8. Every source fails and the relay blanks the last good price, or passes it off as fresh.
//  9. A source hangs and the whole run hangs with it.
// 10. Test-only source overrides are active without saying so.
//
// Run from relay/:  npm test      Results are also written to test/last-run.log.

import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const fixture = name => readFileSync(join(here, 'fixtures', name), 'utf8');
const FIXTURES = {
  cnbc: fixture('cnbc.json'),
  yahoo: fixture('yahoo.json'),
  tradingview: fixture('tradingview.json'),
  google: fixture('google.html'),
};
const SOURCES = Object.keys(FIXTURES);
const TIMEOUT_MS = 1000;

// --- stub upstream: one path per source, behavior set per case ---
const mode = {};
const stub = createServer((req, res) => {
  const src = req.url.slice(1);
  const m = mode[src];
  if (m === 'ok') { res.writeHead(200); res.end(FIXTURES[src]); }
  else if (m === 'http500') { res.writeHead(500); res.end('boom'); }
  else if (m === 'http429') { res.writeHead(429); res.end('Too Many Requests'); }
  else if (m === 'empty202') { res.writeHead(202); res.end(); }
  else if (m === 'garbage') { res.writeHead(200); res.end('<html>Press & Hold</html>'); }
  else if (m === 'zero') { res.writeHead(200); res.end(FIXTURES.cnbc.replace('"last":"93.01"', '"last":"0"')); }
  else if (m === 'hang') { setTimeout(() => { res.writeHead(200); res.end(FIXTURES[src]); }, TIMEOUT_MS * 5); }
  else { res.writeHead(599); res.end(`stub has no mode for ${src}`); }
});
await new Promise(r => stub.listen(0, '127.0.0.1', r));
const stubPort = stub.address().port;

// --- the Worker under test, with fresh local storage ---
const persist = mkdtempSync(join(tmpdir(), 'wti-relay-e2e-'));
const port = 8787 + Math.floor(Math.random() * 1000);
const vars = [
  ...SOURCES.map(s => ['--var', `${s.toUpperCase()}_URL:http://127.0.0.1:${stubPort}/${s}`]).flat(),
  '--var', `TIMEOUT_MS:${TIMEOUT_MS}`,
];
const worker = spawn('npx', ['wrangler', 'dev', '--test-scheduled', '--port', String(port), '--persist-to', persist, ...vars],
  { cwd: join(here, '..'), stdio: ['ignore', 'pipe', 'pipe'] });
let workerLog = '';
worker.stdout.on('data', d => { workerLog += d; });
worker.stderr.on('data', d => { workerLog += d; });

const base = `http://127.0.0.1:${port}`;
const lines = [];
let failed = 0;
const check = (name, ok, detail = '') => {
  if (!ok) failed++;
  lines.push(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ` (${detail})` : ''}`);
};
const get = async path => {
  const res = await fetch(base + path);
  const text = await res.text();
  let body = null;
  try { body = JSON.parse(text); } catch { /* left null; the checks report the raw text */ }
  return { status: res.status, body, text };
};

// Fires the cron handler, then waits for the Worker's own record of a new attempt.
async function runOnce(setup) {
  Object.assign(mode, setup);
  const before = (await get('/')).body?.lastAttempt?.at ?? null;
  const t = await fetch(`${base}/__scheduled?cron=*/5+*+*+*+*`);
  await t.text();
  for (let i = 0; i < 100; i++) {
    const r = await get('/');
    if (r.body?.lastAttempt?.at && r.body.lastAttempt.at !== before) return r;
    await new Promise(res => setTimeout(res, 100));
  }
  throw new Error('the cron run never recorded an attempt');
}
const reasonFor = (r, src) => r.body?.lastAttempt?.failures?.find(f => f.source === src)?.reason ?? '';

try {
  // wait for wrangler dev to come up
  let up = false;
  for (let i = 0; i < 120 && !up && worker.exitCode === null; i++) {
    try { await fetch(base + '/'); up = true; } catch { await new Promise(r => setTimeout(r, 500)); }
  }
  if (!up) throw new Error(`wrangler dev never answered on ${base}\n${workerLog}`);

  // 1 + 10
  let r = await get('/');
  check('before any run: 503, no quote', r.status === 503 && r.body?.quote === null, `${r.status} ${r.text.slice(0, 120)}`);
  check('says that test overrides are active', SOURCES.every(s => r.body?.overrides?.includes(s)), JSON.stringify(r.body?.overrides));

  // 2
  r = await runOnce({ cnbc: 'ok', yahoo: 'ok', tradingview: 'ok', google: 'ok' });
  const q = r.body?.quote;
  check('all up: serves CNBC', r.status === 200 && q?.source === 'cnbc', JSON.stringify(q));
  check('CNBC price, contract and change', q?.price === 93.01 && q?.contract === 'CLX26' && q?.changePercent === 0.15, JSON.stringify(q));
  check('CNBC quote time normalized to UTC', q?.quoteTime === '2026-10-01T22:41:09.000Z', q?.quoteTime);
  check('records a clean attempt', r.body?.lastAttempt?.ok === true && r.body.lastAttempt.failures.length === 0, JSON.stringify(r.body?.lastAttempt));
  check('carries when it was fetched', typeof r.body?.fetchedAt === 'string' && !isNaN(Date.parse(r.body.fetchedAt)), r.body?.fetchedAt);

  // 3
  r = await runOnce({ cnbc: 'http500', yahoo: 'ok' });
  check('CNBC 500: falls back to Yahoo', r.body?.quote?.source === 'yahoo' && r.body.quote.price === 94.27, JSON.stringify(r.body?.quote));
  check('Yahoo quote time from regularMarketTime', r.body?.quote?.quoteTime === new Date(1790895433 * 1000).toISOString(), r.body?.quote?.quoteTime);
  check('names the CNBC failure', reasonFor(r, 'cnbc') === 'HTTP 500', reasonFor(r, 'cnbc'));
  check('a fallback success still counts as ok', r.body?.lastAttempt?.ok === true);

  // 4 + 5
  r = await runOnce({ cnbc: 'empty202', yahoo: 'garbage', tradingview: 'ok' });
  check('202 with empty body is a failure', /empty/i.test(reasonFor(r, 'cnbc')), reasonFor(r, 'cnbc'));
  check('200 with junk is a failure', /unexpected/i.test(reasonFor(r, 'yahoo')), reasonFor(r, 'yahoo'));
  check('then serves TradingView, with no quote time', r.body?.quote?.source === 'tradingview' && r.body.quote.price === 93.01 && r.body.quote.quoteTime === null, JSON.stringify(r.body?.quote));

  // 5 + 6 + 7
  r = await runOnce({ cnbc: 'zero', yahoo: 'http429', tradingview: 'http500', google: 'ok' });
  check('a price of 0 is a failure', /price/i.test(reasonFor(r, 'cnbc')), reasonFor(r, 'cnbc'));
  check('429 on Yahoo is recorded', reasonFor(r, 'yahoo') === 'HTTP 429', reasonFor(r, 'yahoo'));
  check('only Google up: serves Google', r.body?.quote?.source === 'google' && r.body.quote.price === 93.01, JSON.stringify(r.body?.quote));
  check('Google quote time and change', r.body?.quote?.quoteTime === new Date(1790894469 * 1000).toISOString() && r.body.quote.changePercent === 0.15, JSON.stringify(r.body?.quote));
  const googleFetchedAt = r.body?.fetchedAt;

  // 8 + 9
  r = await runOnce({ cnbc: 'hang', yahoo: 'http500', tradingview: 'http500', google: 'http500' });
  check('all down: keeps serving the last good price', r.status === 200 && r.body?.quote?.source === 'google' && r.body.quote.price === 93.01, JSON.stringify(r.body?.quote));
  check('all down: fetchedAt stays at the old fetch', r.body?.fetchedAt === googleFetchedAt, `${r.body?.fetchedAt} vs ${googleFetchedAt}`);
  check('all down: attempt marked failed with every reason', r.body?.lastAttempt?.ok === false && r.body.lastAttempt.failures.length === 4, JSON.stringify(r.body?.lastAttempt));
  check('a hanging source times out', /timed out/i.test(reasonFor(r, 'cnbc')), reasonFor(r, 'cnbc'));

  r = await get('/nope');
  check('unknown path is 404', r.status === 404, String(r.status));
} catch (e) {
  failed++;
  lines.push(`FAIL test aborted: ${e.message}`);
} finally {
  worker.kill();
  stub.close();
  rmSync(persist, { recursive: true, force: true });
}

lines.push(failed ? `FAILED (${failed})` : 'ALL PASS');
const out = lines.join('\n');
console.log(out);
writeFileSync(join(here, 'last-run.log'), `${new Date().toISOString()}\n${out}\n`);
if (failed) {
  console.log('\n--- wrangler dev output ---\n' + workerLog.slice(-4000));
  process.exit(1);
}
