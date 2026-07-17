#!/bin/bash
# Account-meter polling discipline: the dashboard (/api/summary) drives the
# usage-endpoint refresh at the normal cadence, but background consumers (the
# status line, Discord) only trickle it — so Pulse doesn't hammer the shared,
# rate-limited endpoint 24/7 when no one is watching the card.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CL=$TMP/claude; CX=$TMP/codex; PH=$TMP/pulse
mkdir -p "$CL/projects/demo" "$CX/sessions/2026/07/15" "$PH"
echo '{"accountMeters": true}' > "$PH/config.json"
echo '{"claudeAiOauth":{"accessToken":"sk-test-oauth-token","expiresAt":9999999999999}}' > "$CL/.credentials.json"
# a recent Claude entry so the status line has something to build from
node -e '
const fs = require("fs"); const now = Date.now();
fs.writeFileSync(process.argv[1] + "/projects/demo/s.jsonl", JSON.stringify({
  type: "assistant", timestamp: new Date(now - 5*60e3).toISOString(), sessionId: "s1", requestId: "r1", cwd: "/p",
  message: { id: "m1", model: "claude-fable-5", usage: { input_tokens: 1000, output_tokens: 500 } } }) + "\n");
' "$CL"

# counting mock: every hit to /usage-ok increments a counter, exposed at /count
node -e '
const http = require("http");
let n = 0;
http.createServer((q, s) => {
  if (q.url === "/count") { s.writeHead(200); s.end(String(n)); return; }
  if (q.url === "/usage-ok") {
    n++;
    s.writeHead(200, { "Content-Type": "application/json" });
    s.end(JSON.stringify({ five_hour: { utilization: 0.2, resets_at: new Date(Date.now()+3600e3).toISOString() },
                           seven_day: { utilization: 0.5, resets_at: new Date(Date.now()+3*86400e3).toISOString() } }));
    return;
  }
  s.writeHead(404); s.end();
}).listen(4875, "127.0.0.1", () => console.log("count mock up"));
' >/dev/null 2>&1 &
MOCK=$!
sleep 0.4

PORT=4895
# short foreground gate (400ms); the background trickle stays at its 15-min default
PULSE_HOME=$PH CLAUDE_DIR=$CL CODEX_DIR=$CX \
PULSE_METERS_API=http://127.0.0.1:4875/usage-ok PULSE_METERS_CACHE_MS=400 \
node "$ROOT/server.js" --port $PORT --no-update-check >"$TMP/srv.log" 2>&1 &
SRV=$!
sleep 2

count() { curl -s "http://127.0.0.1:4875/count"; }

# 1) dashboard poll -> one foreground fetch
for i in 1 2 3 4 5 6; do
  curl -s "http://127.0.0.1:$PORT/api/summary" > "$TMP/sum.json"
  ST=$(node -e 'const s=require(process.argv[1]);console.log(s.meters&&s.meters.status||"")' "$TMP/sum.json")
  [ "$ST" = "ok" ] && break
  sleep 0.5
done
C_AFTER_DASH=$(count)

# 2) let the foreground gate (400ms) AND the statusline memo (3s) both expire,
#    then hammer the status line — background trickle must NOT fetch
sleep 4
for i in $(seq 1 8); do curl -s "http://127.0.0.1:$PORT/api/statusline" >/dev/null; sleep 0.1; done
sleep 0.5
C_AFTER_SL=$(count)

# 3) a dashboard poll now (gate long expired) DOES fetch again
curl -s "http://127.0.0.1:$PORT/api/summary" >/dev/null
sleep 0.6
C_AFTER_DASH2=$(count)

kill $SRV $MOCK 2>/dev/null

node -e '
let fail = 0;
const ok = (c, m) => { console.log((c ? "PASS" : "FAIL") + "  " + m); if (!c) fail = 1; };
const [dash, sl, dash2] = process.argv.slice(1).map(Number);
ok(dash >= 1, "dashboard poll fetched the usage endpoint (count=" + dash + ")");
ok(sl === dash, "8 status-line hits over 4s did NOT poll the endpoint — background trickle held (count " + dash + " -> " + sl + ")");
ok(dash2 === dash + 1, "a later dashboard poll DID fetch again (count " + sl + " -> " + dash2 + ")");
process.exit(fail);
' "$C_AFTER_DASH" "$C_AFTER_SL" "$C_AFTER_DASH2"
RES=$?
echo "---- exit $RES"
exit $RES
