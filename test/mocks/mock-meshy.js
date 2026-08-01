// Mock Meshy API for test/meshy.test.sh.
//
// Serves the two CONFIRMED endpoints (GET /openapi/v1/balance and
// GET /openapi/v2/text-to-3d) and deliberately FAILS every other task family,
// each in a different way, because the unconfirmed families must be probed
// defensively: a 404 / 405 / garbage-JSON family has to be skipped silently and
// must never fail the whole refresh.
//
// Everything the suite needs to prove is observable here:
//   - the key arrives in the Authorization header and NEVER in a URL
//     (stats.keyInUrl) — URLs land in access logs, proxies and shell history;
//   - request counts per path + the page_num/page_size of every list call
//     (stats.pages), which is how incremental paging is asserted;
//   - controllable 401 / 429 / 500 so bad-key and back-off paths are testable
//     against the SAME base URL the server was configured with (PULSE_MESHY_API
//     is a base, so scenarios cannot be selected by path).
//
// The mock never prints the key, for the same reason the server must not.
const http = require('http');
const fs = require('fs');
const url = require('url');

const PORT = parseInt(process.env.MESHY_PORT, 10) || 4879;
// Distinctive on purpose: the suite greps the whole payload, the server log and
// the persisted task store for this exact string. Obviously not a real key.
const KEY = process.env.MESHY_KEY || 'msy-fake-key-DO-NOT-LOG-0123456789';
// Task fixture (a JSON array, newest first). Re-read on every list request so
// the suite can swap fixtures between phases without restarting the mock.
const FIXTURE = process.env.MESHY_FIXTURE || '';
// Non-integer on purpose — a credit balance is not a count of things.
const BALANCE = process.env.MESHY_BALANCE ? Number(process.env.MESHY_BALANCE) : 987.5;

let mode = 'ok'; // ok | 401 | 429 | 500
const zero = () => ({ total: 0, balance: 0, list: 0, pages: [], badAuth: 0, keyInUrl: 0, paths: {} });
let stats = zero();

function readFixture() {
  if (!FIXTURE) return [];
  try {
    const j = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));
    return Array.isArray(j) ? j : [];
  } catch (_) { return []; }
}

const json = (s, code, obj) => {
  s.writeHead(code, { 'Content-Type': 'application/json' });
  s.end(JSON.stringify(obj));
};

http.createServer((q, s) => {
  const u = url.parse(q.url, true);
  const p = String(u.pathname || '');

  // --- control plane: never counted, never authenticated ---------------------
  // `fixture`/`pid` let the suite prove it is talking to ITS OWN mock: a stray
  // mock left listening on this port by an earlier run answers every request
  // with an empty task list, which looks exactly like a server-side parsing bug.
  if (p === '/__stats') return json(s, 200, Object.assign({ mode, fixture: FIXTURE, pid: process.pid }, stats));
  if (p === '/__reset') { stats = zero(); return json(s, 200, { ok: true }); }
  if (p === '/__mode') { mode = String(u.query.set || 'ok'); return json(s, 200, { ok: true, mode }); }

  stats.total++;
  stats.paths[p] = (stats.paths[p] || 0) + 1;
  if (q.url.indexOf(KEY) >= 0) stats.keyInUrl++; // a secret in a URL is a leak

  if ((q.headers['authorization'] || '') !== 'Bearer ' + KEY) {
    stats.badAuth++;
    return json(s, 401, { message: 'Unauthorized' });
  }

  if (mode === '401') return json(s, 401, { message: 'Unauthorized' });
  if (mode === '429') {
    s.writeHead(429, { 'Content-Type': 'application/json', 'Retry-After': '1' });
    return s.end('{"message":"Too Many Requests"}');
  }
  if (mode === '500') return json(s, 500, { message: 'boom' });

  if (/\/openapi\/v\d+\/balance$/.test(p)) {
    stats.balance++;
    return json(s, 200, { balance: BALANCE });
  }

  // The confirmed list endpoint. The real API answers with a bare JSON array of
  // task objects (page_size caps at 50), so the mock does too.
  if (/\/openapi\/v\d+\/text-to-3d$/.test(p)) {
    const size = Math.min(parseInt(u.query.page_size, 10) || 50, 50);
    const n = Math.max(parseInt(u.query.page_num, 10) || 1, 1);
    stats.list++;
    stats.pages.push({ n, size });
    const all = readFixture();
    return json(s, 200, all.slice((n - 1) * size, n * size));
  }

  // Unconfirmed families — three different flavours of failure, all of which
  // must be skipped silently rather than poisoning the refresh.
  if (/\/remesh$/.test(p)) { // 200 with a truncated body: valid HTTP, invalid JSON
    s.writeHead(200, { 'Content-Type': 'application/json' });
    return s.end('{"not":');
  }
  if (/\/animation$/.test(p)) { s.writeHead(405); return s.end(); }
  return json(s, 404, { message: 'not found' });
}).on('error', (e) => {
  // Never fail quietly: a mock that could not bind would otherwise leave the
  // suite testing whatever else owns the port.
  console.error('mock meshy could not listen on ' + PORT + ': ' + e.message);
  process.exit(1);
}).listen(PORT, '127.0.0.1', () => console.log('mock meshy up on ' + PORT));
