const http = require('http');
http.createServer((q, s) => {
  const auth = q.headers['authorization'] || '';
  const acct = q.headers['chatgpt-account-id'] || '';
  if (q.url === '/profiles-ok') {
    if (auth !== 'Bearer fake-cx-token' || acct !== 'acc-test-1') {
      s.writeHead(401); s.end('{"detail":"bad token"}'); return;
    }
    const buckets = [];
    for (let i = 34; i >= 0; i--) { // 35 days: server must trim to last 30
      const d = new Date(Date.now() - i * 86400e3).toISOString().slice(0, 10);
      buckets.push({ start_date: d, tokens: 1000000 + i * 10000 });
    }
    // malformed entries the server must drop (not count into aggregates)
    buckets.push({ start_date: 'N/A', tokens: 5000000 });
    buckets.push({ start_date: 12345, tokens: 5000000 });
    buckets.push(null);
    s.writeHead(200, { 'Content-Type': 'application/json' });
    s.end(JSON.stringify({
      stats: {
        lifetime_tokens: 812345678,
        peak_daily_tokens: 45678901,
        longest_running_turn_sec: 512,
        current_streak_days: 4,
        longest_streak_days: 9,
        daily_usage_buckets: buckets,
      },
    }));
    return;
  }
  if (q.url === '/profiles-401') { s.writeHead(401); s.end('{}'); return; }
  if (q.url === '/profiles-zero') { // brand-new account: stats present, empty
    s.writeHead(200, { 'Content-Type': 'application/json' });
    s.end(JSON.stringify({ stats: { daily_usage_buckets: [], current_streak_days: 0 } }));
    return;
  }
  s.writeHead(404); s.end();
}).listen(4872, '127.0.0.1', () => console.log('mock cx usage up'));
