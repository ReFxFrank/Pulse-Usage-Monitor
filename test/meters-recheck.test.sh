#!/bin/bash
# Account-connect "Recheck now": with meters enabled but no login, the meters
# stay in no-login; the moment the Claude Code credential appears, POST
# /api/meters/recheck picks it up immediately (no restart), returning live
# buckets. Verifies the connect-card auto-detect flow.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CL=$TMP/claude; PH=$TMP/pulse
mkdir -p "$CL/projects/demo" "$PH"
echo '{"accountMeters": true}' > "$PH/config.json"

# meters mock: validates the token, returns two buckets
node -e '
const http = require("http");
http.createServer((q, s) => {
  if (q.headers["authorization"] !== "Bearer sk-test-oauth-token") { s.writeHead(401); s.end("{}"); return; }
  s.writeHead(200, { "Content-Type": "application/json" });
  s.end(JSON.stringify({
    five_hour: { utilization: 0.5, resets_at: new Date(Date.now()+2*3600e3).toISOString() },
    seven_day: { utilization: 0.6, resets_at: new Date(Date.now()+3*86400e3).toISOString() },
  }));
}).listen(4878, "127.0.0.1", () => {});
' >/dev/null 2>&1 &
MOCK=$!
sleep 0.4

PORT=4899
PULSE_HOME=$PH CLAUDE_DIR=$CL CODEX_DIR=$TMP/nc \
PULSE_METERS_API=http://127.0.0.1:4878/usage PULSE_METERS_CACHE_MS=100 \
node "$ROOT/server.js" --port $PORT --no-update-check >"$TMP/srv.log" 2>&1 &
SRV=$!
sleep 2.2

# (1) no credential yet -> no-login
curl -s "http://127.0.0.1:$PORT/api/summary" > "$TMP/before.json"
# (2) recheck with still no credential -> still no-login
curl -s -X POST -H 'X-Pulse: 1' "http://127.0.0.1:$PORT/api/meters/recheck" > "$TMP/recheck-nologin.json"
# (3) user "logs in": the credential file appears
echo '{"claudeAiOauth":{"accessToken":"sk-test-oauth-token","expiresAt":9999999999999}}' > "$CL/.credentials.json"
# (4) recheck -> should now pick it up immediately, live buckets
curl -s -X POST -H 'X-Pulse: 1' "http://127.0.0.1:$PORT/api/meters/recheck" > "$TMP/recheck-ok.json"

kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
kill $MOCK 2>/dev/null

node -e '
const fs=require("fs"); const T=process.argv[1];
let fail=0; const ok=(c,m)=>{console.log((c?"PASS":"FAIL")+"  "+m); if(!c) fail=1;};
const before=require(T+"/before.json").meters;
ok(before && before.status==="no-login", "no credential -> meters status no-login (got "+(before&&before.status)+")");
const rn=require(T+"/recheck-nologin.json");
ok(rn.ok && rn.meters && rn.meters.status==="no-login", "recheck with no login -> still no-login, endpoint ok");
const ro=require(T+"/recheck-ok.json");
ok(ro.ok && ro.meters && ro.meters.status==="ok", "after login appears, recheck -> status ok (no restart) (got "+(ro.meters&&ro.meters.status)+")");
ok(ro.meters && Array.isArray(ro.meters.buckets) && ro.meters.buckets.length>=2, "recheck returns live buckets ("+(ro.meters&&ro.meters.buckets&&ro.meters.buckets.length)+")");
// token must never appear in logs
const log=fs.readFileSync(T+"/srv.log","utf8");
ok(!/sk-test-oauth-token/.test(log), "oauth token never logged");
process.exit(fail);
' "$TMP"
RES=$?
echo "---- exit $RES"
exit $RES
