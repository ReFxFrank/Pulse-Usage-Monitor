#!/bin/bash
# Pricing e2e: every current gpt-5.3–5.6 / codex-auto-review string prices at
# exact OpenAI list rates; no unknown-model warnings in the server log.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CL=$TMP/claude; CX=$TMP/codex; PH=$TMP/pulse
mkdir -p "$CL/projects" "$CX/sessions/2026/07/15" "$PH"

node -e '
const fs = require("fs");
const dir = process.argv[1];
const now = Date.now();
const iso = (ms) => new Date(ms).toISOString();
// 1M uncached input + 1M output per model -> cost = input$ + output$
const MODELS = ["gpt-5.6-sol","gpt-5.6-terra","gpt-5.6-luna","gpt-5.5",
                "gpt-5.4","gpt-5.4-mini","gpt-5.3-codex","codex-auto-review"];
const lines = [{ timestamp: iso(now - 3600e3), type: "session_meta",
                 payload: { session_id: "price-1", cwd: "/p" } }];
let cum = { input_tokens: 0, cached_input_tokens: 0, output_tokens: 0, total_tokens: 0 };
MODELS.forEach((m, i) => {
  const t = now - 3600e3 + (i + 1) * 60e3;
  lines.push({ timestamp: iso(t), type: "turn_context",
    payload: { turn_id: "t" + i, model: m,
               collaboration_mode: { mode: "default", settings: { model: m, reasoning_effort: "medium" } } } });
  const u = { input_tokens: 1000000, cached_input_tokens: 0, output_tokens: 1000000, total_tokens: 2000000 };
  cum = { input_tokens: cum.input_tokens + u.input_tokens, cached_input_tokens: 0,
          output_tokens: cum.output_tokens + u.output_tokens, total_tokens: cum.total_tokens + u.total_tokens };
  lines.push({ timestamp: iso(t + 30e3), type: "event_msg",
    payload: { type: "token_count", info: { last_token_usage: u, total_token_usage: { ...cum } } } });
});
fs.writeFileSync(dir + "/sessions/2026/07/15/rollout-price.jsonl",
  lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
' "$CX"

PORT=4882
CLAUDE_DIR=$CL CODEX_DIR=$CX PULSE_HOME=$PH \
node "$ROOT/server.js" --port $PORT --no-update-check >"$TMP/srv.log" 2>&1 &
SRV=$!
sleep 2.5
curl -s "http://127.0.0.1:$PORT/api/summary" > "$TMP/out.json"
kill $SRV 2>/dev/null

node -e '
const s = require(process.argv[1] + "/out.json");
const log = require("fs").readFileSync(process.argv[1] + "/srv.log", "utf8");
let fail = 0;
const ok = (cond, msg) => { console.log((cond ? "PASS" : "FAIL") + "  " + msg); if (!cond) fail = 1; };
const WANT = { "gpt-5.6-sol": 35, "gpt-5.6-terra": 17.5, "gpt-5.6-luna": 7, "gpt-5.5": 35,
               "gpt-5.4": 17.5, "gpt-5.4-mini": 5.25, "gpt-5.3-codex": 15.75, "codex-auto-review": 17.5 };
const rows = (s.periods && s.periods[0] && s.periods[0].byModel) || {};
for (const [m, want] of Object.entries(WANT)) {
  const r = rows[m];
  ok(r && Math.abs(r.cost - want) < 0.005, m + " costs $" + want + " (got " + (r ? r.cost.toFixed(2) : "missing") + ")");
}
ok(!/unknown model/.test(log), "no unknown-model warnings in server log");
process.exit(fail);
' "$TMP"
RES=$?
echo "---- exit $RES"
exit $RES
