#!/bin/bash
# Limit alerts: the summary payload flags every window at/above a warning
# threshold (Claude meters + Codex snapshot), sorted most-urgent-first, with
# provider-correct labels; thresholds are configurable and the feature disables.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CL=$TMP/claude; CX=$TMP/codex; PH=$TMP/pulse
mkdir -p "$CL/projects/demo" "$CX/sessions/2026/07/15" "$PH"
echo '{"claudeAiOauth":{"accessToken":"sk-test-oauth-token","expiresAt":9999999999999}}' > "$CL/.credentials.json"

# Codex rollout: weekly window pinned at 90% (secondary, window_minutes 10080).
node -e '
const fs = require("fs"); const now = Date.now();
const iso = (ms) => new Date(ms).toISOString(); const ep = (ms) => Math.round(ms/1000);
fs.writeFileSync(process.argv[1] + "/sessions/2026/07/15/r.jsonl", [
  { timestamp: iso(now-20*60e3), type: "session_meta", payload: { session_id: "s", cwd: "/p" } },
  { timestamp: iso(now-10*60e3), type: "event_msg", payload: { type: "token_count",
    info: { last_token_usage: { input_tokens: 10, cached_input_tokens: 0, output_tokens: 10, total_tokens: 20 },
            total_token_usage: { input_tokens: 10, cached_input_tokens: 0, output_tokens: 10, total_tokens: 20 } },
    rate_limits: { primary: { used_percent: 30, window_minutes: 300, resets_at: ep(now+3600e3) },
                   secondary: { used_percent: 90, window_minutes: 10080, resets_at: ep(now+5*86400e3) } } } },
].map(JSON.stringify).join("\n") + "\n");
' "$CX"

# inline meters mock: 5h 82%, weekly 96%, Opus 40%
node -e '
const http = require("http");
http.createServer((q, s) => {
  if (q.headers["authorization"] !== "Bearer sk-test-oauth-token") { s.writeHead(401); s.end("{}"); return; }
  s.writeHead(200, { "Content-Type": "application/json" });
  s.end(JSON.stringify({
    five_hour:      { utilization: 0.82, resets_at: new Date(Date.now()+2*3600e3).toISOString() },
    seven_day:      { utilization: 0.96, resets_at: new Date(Date.now()+3*86400e3).toISOString() },
    seven_day_opus: { utilization: 0.40, resets_at: new Date(Date.now()+3*86400e3).toISOString() },
    // model-scoped Fable weekly MAXED OUT — a reached limit, must be dropped
    // from the alerts banner (you have hit it, not approaching it).
    limits: [ { kind: "weekly_scoped", group: "g", percent: 100,
                resets_at: new Date(Date.now()+4*86400e3).toISOString(),
                scope: { model: { display_name: "Fable" } } } ],
  }));
}).listen(4877, "127.0.0.1", () => console.log("mock up"));
' >/dev/null 2>&1 &
MOCK=$!
sleep 0.4

PORT=4896
fetch() { # $1 config, $2 out
  echo "$1" > "$PH/config.json"
  PULSE_HOME=$PH CLAUDE_DIR=$CL CODEX_DIR=$CX \
  PULSE_METERS_API=http://127.0.0.1:4877/usage PULSE_METERS_CACHE_MS=400 \
  node "$ROOT/server.js" --port $PORT --no-update-check >"$TMP/srv.log" 2>&1 &
  local SRV=$!
  sleep 2
  for i in 1 2 3 4 5 6; do
    curl -s "http://127.0.0.1:$PORT/api/summary" > "$2"
    ST=$(node -e 'const s=require(process.argv[1]);console.log(s.meters&&s.meters.status||"")' "$2")
    [ "$ST" = "ok" ] && break
    sleep 0.6
  done
  kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
}

fetch '{"accountMeters": true}' "$TMP/def.json"
fetch '{"accountMeters": true, "alerts": false}' "$TMP/off.json"
fetch '{"accountMeters": true, "alertThresholds": [50]}' "$TMP/t50.json"
kill $MOCK 2>/dev/null

node -e '
const fs = require("fs"); const TMP = process.argv[1];
let fail = 0;
const ok = (c, m) => { console.log((c ? "PASS" : "FAIL") + "  " + m); if (!c) fail = 1; };
const A = require(TMP + "/def.json").alerts || [];
const by = {}; for (const a of A) by[a.key] = a;
ok(by["claude:seven_day"] && by["claude:seven_day"].threshold === 95, "weekly 96% -> alert at threshold 95");
ok(by["claude:five_hour"] && by["claude:five_hour"].threshold === 80, "5h 82% -> alert at threshold 80 (not 95)");
ok(!by["claude:seven_day_opus"], "Opus 40% -> no alert (below 80)");
ok(by["codex:codex_secondary"] && by["codex:codex_secondary"].threshold === 80 && by["codex:codex_secondary"].provider === "codex",
   "Codex weekly 90% -> alert, provider codex (" + JSON.stringify(by["codex:codex_secondary"] && {t:by["codex:codex_secondary"].threshold,p:by["codex:codex_secondary"].provider}) + ")");
ok(/^Claude · /.test((by["claude:seven_day"]||{}).label || "") && /^Codex · /.test((by["codex:codex_secondary"]||{}).label || ""), "labels carry provider prefix");
ok(A.length >= 3 && A[0].pct >= A[A.length-1].pct, "sorted most-urgent-first (" + A.map(a=>Math.round(a.pct)).join(">=") + ")");

// maxed-out windows are dropped from the banner (reached, not approaching).
const buckets = (require(TMP + "/def.json").meters || {}).buckets || [];
const fableBucket = buckets.find((b) => b.key === "model_scoped:fable");
ok(fableBucket && Math.round(fableBucket.pct) === 100, "Fable weekly meter IS present at 100% (bucket exists)");
ok(!by["claude:model_scoped:fable"], "Fable 100% -> NOT in alerts (a reached limit is dropped from the banner)");

const off = require(TMP + "/off.json").alerts;
ok(Array.isArray(off) && off.length === 0, "alerts:false -> no alerts (" + (off && off.length) + ")");

const t50 = require(TMP + "/t50.json").alerts || [];
const by50 = {}; for (const a of t50) by50[a.key] = a;
ok(!by50["claude:seven_day_opus"], "threshold [50]: Opus 40% still below 50 -> no alert");
ok(by50["claude:five_hour"] && by50["claude:five_hour"].threshold === 50, "threshold [50]: 5h 82% -> alert at 50");
process.exit(fail);
' "$TMP"
RES=$?
echo "---- exit $RES"
exit $RES
