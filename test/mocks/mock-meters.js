const http = require('http');
http.createServer((q, s) => {
  const auth = q.headers['authorization'] || '';
  if (q.url === '/usage-ok') {
    if (auth !== 'Bearer sk-test-oauth-token') { s.writeHead(401); s.end('{"error":"bad token"}'); return; }
    s.writeHead(200, { 'Content-Type': 'application/json' });
    s.end(JSON.stringify({
      five_hour: { utilization: 0.34, resets_at: new Date(Date.now() + 2.4 * 3600e3).toISOString() },
      seven_day: { utilization: 61, resets_at: new Date(Date.now() + 3 * 86400e3).toISOString() },
      seven_day_opus: { utilization: 0.88, resets_at: new Date(Date.now() + 3 * 86400e3).toISOString() },
      extra_unknown_key: { something: true },
      limits: [
        // the real thing: per-model weekly window
        { kind: 'weekly_scoped', group: 'g', percent: 76, resets_at: new Date(Date.now() + 3 * 86400e3).toISOString(),
          scope: { model: { display_name: 'Fable' } } },
        // duplicate of the legacy seven_day_opus key — must be deduped
        { kind: 'weekly_scoped', group: 'g', percent: 88, resets_at: new Date(Date.now() + 3 * 86400e3).toISOString(),
          scope: { model: { display_name: 'Opus' } } },
        // wrong kind — ignore
        { kind: 'five_hour', group: 'g', percent: 34, resets_at: null, scope: { model: { display_name: 'Nope' } } },
        // surface-scoped, no model — ignore
        { kind: 'weekly_scoped', group: 'g', percent: 12, resets_at: null, scope: { surface: { display_name: 'apps' } } },
        // malformed — ignore
        { kind: 'weekly_scoped', percent: 'NaN', scope: { model: { display_name: 'Broken' } } },
        null,
      ],
    }));
    return;
  }
  if (q.url === '/usage-401') { s.writeHead(401); s.end('{}'); return; }
  s.writeHead(404); s.end();
}).listen(4870, '127.0.0.1', () => console.log('mock meters up'));
