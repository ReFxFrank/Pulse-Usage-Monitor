#!/bin/bash
# Status line e2e:
#  - with a running Pulse server: the line is enriched with today's spend, the
#    5h block, and Pulse's official meter % (fetched over loopback, not from a
#    provider), plus model + context from the piped stdin payload
#  - server down: fails open — still prints model + context + stdin weekly, exit 0
#  - NO_COLOR strips ANSI
#  - always a single line, always exit 0
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CL=$TMP/claude; PH=$TMP/pulse
mkdir -p "$CL/projects/demo" "$PH"
echo '{"accountMeters": true}' > "$PH/config.json"
echo '{"claudeAiOauth":{"accessToken":"sk-test-oauth-token","expiresAt":9999999999999}}' > "$CL/.credentials.json"
# one assistant entry ~1h ago -> today spend + a current 5h block
node -e '
const fs = require("fs"); const now = Date.now();
fs.writeFileSync(process.argv[1] + "/projects/demo/s.jsonl", [
  { type: "user", timestamp: new Date(now - 3700e3).toISOString(), sessionId: "s1", cwd: "/p", message: { role: "user", content: "hi" } },
  { type: "assistant", timestamp: new Date(now - 3600e3).toISOString(), sessionId: "s1", requestId: "r1", cwd: "/p",
    message: { id: "m1", model: "claude-fable-5", usage: { input_tokens: 400000, output_tokens: 300000 } } },
].map(JSON.stringify).join("\n") + "\n");
' "$CL"

PAYLOAD='{"model":{"display_name":"Opus","id":"claude-opus-4-8"},"workspace":{"current_dir":"/p"},"context_window":{"used_percentage":25},"session_id":"s1","rate_limits":{"seven_day":{"used_percentage":55}}}'
strip() { sed -r 's/\x1b\[[0-9;]*m//g'; }

node "$ROOT/test/mocks/mock-meters.js" >/dev/null 2>&1 & MOCK=$!
sleep 0.4

PORT=4888
PULSE_HOME=$PH CLAUDE_DIR=$CL CODEX_DIR=$TMP/no-codex \
PULSE_METERS_API=http://127.0.0.1:4870/usage-ok PULSE_METERS_CACHE_MS=500 \
node "$ROOT/server.js" --port $PORT --no-update-check >"$TMP/srv.log" 2>&1 &
SRV=$!
sleep 2
# warm the meters (server is the poller) before rendering
for i in 1 2 3 4 5 6 7 8; do
  ST=$(curl -s "http://127.0.0.1:$PORT/api/summary" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).meters.status)}catch(_){console.log("")}})')
  [ "$ST" = "ok" ] && break
  sleep 1
done

# with server up
echo "$PAYLOAD" | PULSE_HOME=$PH node "$ROOT/server.js" --statusline > "$TMP/up.raw" 2>/dev/null
echo "exit:$?" > "$TMP/up.code"
strip < "$TMP/up.raw" > "$TMP/up.txt"

# NO_COLOR
echo "$PAYLOAD" | NO_COLOR=1 PULSE_HOME=$PH node "$ROOT/server.js" --statusline > "$TMP/nc.raw" 2>/dev/null

kill $SRV $MOCK 2>/dev/null; wait $SRV 2>/dev/null

# server down: no runtime file present, point at a dead port
rm -f "$PH/server.json"
echo "$PAYLOAD" | PULSE_HOME=$PH PORT=4999 node "$ROOT/server.js" --statusline > "$TMP/down.raw" 2>/dev/null
echo "exit:$?" >> "$TMP/up.code"
strip < "$TMP/down.raw" > "$TMP/down.txt"

node -e '
const fs = require("fs");
const TMP = process.argv[1];
let fail = 0;
const ok = (c, m) => { console.log((c ? "PASS" : "FAIL") + "  " + m); if (!c) fail = 1; };
const up = fs.readFileSync(TMP + "/up.txt", "utf8");
const down = fs.readFileSync(TMP + "/down.txt", "utf8");
const codes = fs.readFileSync(TMP + "/up.code", "utf8");
const nc = fs.readFileSync(TMP + "/nc.raw", "utf8");

ok(/Opus/.test(up), "up: shows model from stdin (" + JSON.stringify(up.trim()) + ")");
ok(/ctx 25%/.test(up), "up: shows context % from stdin");
ok(/today \$/.test(up), "up: shows today spend from Pulse");
ok(/5h \$/.test(up), "up: shows current 5h block from Pulse");
ok(/wk 61%/.test(up), "up: weekly % from Pulse official meter (61), not stdin 55");
ok(up.trim().split("\n").length === 1, "up: single line");
ok(/exit:0/.test(codes.split("\n")[0]), "up: exit 0");

ok(/Opus/.test(down) && /ctx 25%/.test(down), "down: fails open with model + context");
ok(/wk 55%/.test(down), "down: weekly falls back to stdin rate_limits (55)");
ok(!/today/.test(down), "down: no server-only fields");
ok(/exit:0/.test(codes.split("\n")[1]), "down: exit 0 (never blanks the line)");

ok(!/\x1b\[/.test(nc), "NO_COLOR: no ANSI escapes emitted");
ok(/\x1b\[/.test(fs.readFileSync(TMP + "/up.raw", "utf8")), "default: ANSI colors present");
process.exit(fail);
' "$TMP"
RES=$?
echo "---- exit $RES"
exit $RES
