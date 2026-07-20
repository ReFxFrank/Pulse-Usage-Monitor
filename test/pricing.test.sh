#!/bin/bash
# Pricing e2e: every current gpt-5.3–5.6 / codex-auto-review string prices at
# exact OpenAI list rates; Zhipu GLM models (via the ~/.claude path) price at
# Z.ai list rates; the full Gemini table at Google list rates, incl. the
# tier-suffix guard (an unknown -flash-lite must take the LOGGED default, never
# the parent flash rate); Claude cache multipliers at exact rates; both sides
# of Sonnet 5's introductory-price date boundary. The only unknown-model
# warning allowed in the server log is the deliberate guard case.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CL=$TMP/claude; CX=$TMP/codex; GEM=$TMP/gemini; PH=$TMP/pulse
mkdir -p "$CL/projects/glm" "$CX/sessions/2026/07/15" "$GEM/tmp/proj/chats" "$PH"

# GLM usage as it arrives through Claude Code (Z.ai Anthropic-compatible
# endpoint): glm-* model ids in a ~/.claude transcript. 1M input + 1M output
# per model -> cost = input$ + output$.
node -e '
const fs = require("fs");
const now = Date.now();
const iso = (ms) => new Date(ms).toISOString();
const A = (min, id, model) => ({ type: "assistant", timestamp: iso(now - min * 60e3),
  sessionId: "glm-s", requestId: "r" + id, cwd: "/p",
  message: { id: "m" + id, model, usage: { input_tokens: 1000000, output_tokens: 1000000 } } });
const MODELS = ["glm-4.6", "glm-4.5", "glm-4.5-air", "glm-4.5-x", "glm-5", "glm-4.7-flash"];
const lines = MODELS.map((m, i) => A(30 - i, i, m));
// Claude cache multipliers at exact rates: opus-4-8 (5/25), 1M each of
// input + output + 5m cache write (x1.25) + 1h cache write (x2.0) + cache
// read (x0.10) -> 5 + 25 + 6.25 + 10 + 0.5 = 46.75.
lines.push({ type: "assistant", timestamp: iso(now - 40 * 60e3),
  sessionId: "glm-s", requestId: "rc1", cwd: "/p",
  message: { id: "mc1", model: "claude-opus-4-8",
    usage: { input_tokens: 1000000, output_tokens: 1000000, cache_read_input_tokens: 1000000,
      cache_creation: { ephemeral_5m_input_tokens: 1000000, ephemeral_1h_input_tokens: 1000000 } } } });
// Sonnet 5 intro price is keyed on the ENTRY date (priceFor), never "now":
// a July-2026 entry bills intro 2/10 (=12 for 1M+1M), a post-2026-08-31 entry
// bills standard 3/15 (=18). Pinned dates -> asserted via their calendar-month
// periods, so this stays valid no matter when the suite runs.
lines.push({ type: "assistant", timestamp: "2026-07-15T12:00:00.000Z",
  sessionId: "intro-s", requestId: "ri1", cwd: "/p",
  message: { id: "mi1", model: "claude-sonnet-5", usage: { input_tokens: 1000000, output_tokens: 1000000 } } });
lines.push({ type: "assistant", timestamp: "2026-09-15T12:00:00.000Z",
  sessionId: "intro-s", requestId: "ri2", cwd: "/p",
  message: { id: "mi2", model: "claude-sonnet-5", usage: { input_tokens: 1000000, output_tokens: 1000000 } } });
fs.writeFileSync(process.argv[1] + "/projects/glm/s.jsonl",
  lines.map(JSON.stringify).join("\n") + "\n");
' "$CL"

# Gemini CLI fixture: 1M input (0 cached) + 1M output per model -> cost =
# input$ + output$ at Google list rates. The last three rows exercise the
# prefix matcher: a dated -preview variant must fall back to its base row,
# while a tier variant (no gemini-3.5-flash-lite row exists) and a modality
# variant hidden behind -preview (-preview-tts) must NOT price at the parent
# flash rate — each takes __default__ (1.25+10) and warns.
node -e '
const fs = require("fs");
const now = Date.now();
const iso = (ms) => new Date(ms).toISOString();
const MODELS = ["gemini-3-pro", "gemini-3.1-pro", "gemini-3.5-flash", "gemini-3-flash",
                "gemini-3.1-flash-lite", "gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite",
                "gemini-3-pro-preview-11-2025", "gemini-3.5-flash-lite", "gemini-2.5-flash-preview-tts"];
fs.writeFileSync(process.argv[1] + "/tmp/proj/chats/session-p.jsonl",
  MODELS.map((m, i) => ({ id: "gp" + i, sessionId: "gp-s", timestamp: iso(now - (25 - i) * 60e3), model: m,
    tokens: { input: 1000000, output: 1000000, cached: 0, thoughts: 0, tool: 0, total: 2000000 } }))
    .map(JSON.stringify).join("\n") + "\n");
' "$GEM"

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
CLAUDE_DIR=$CL CODEX_DIR=$CX GEMINI_DIR=$GEM PULSE_HOME=$PH \
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
// GLM via ~/.claude — Z.ai list prices (input$ + output$ for 1M+1M):
const GLM = { "glm-4.6": 2.8, "glm-4.5": 2.8, "glm-4.5-air": 1.3, "glm-4.5-x": 11.1, "glm-5": 4.2, "glm-4.7-flash": 0 };
for (const [m, want] of Object.entries(GLM)) {
  const r = rows[m];
  ok(r && Math.abs(r.cost - want) < 0.005, "GLM " + m + " costs $" + want + " (got " + (r ? r.cost.toFixed(2) : "missing") + ")");
}
// Gemini via ~/.gemini — Google list prices (input$ + output$ for 1M+1M),
// including the dated -preview fallback to its base row:
const GOOG = { "gemini-3-pro": 14, "gemini-3.1-pro": 14, "gemini-3.5-flash": 10.5, "gemini-3-flash": 3.5,
               "gemini-3.1-flash-lite": 1.75, "gemini-2.5-pro": 11.25, "gemini-2.5-flash": 2.8,
               "gemini-2.5-flash-lite": 0.5, "gemini-3-pro-preview-11-2025": 14 };
for (const [m, want] of Object.entries(GOOG)) {
  const r = rows[m];
  ok(r && Math.abs(r.cost - want) < 0.005, "Gemini " + m + " costs $" + want + " (got " + (r ? r.cost.toFixed(2) : "missing") + ")");
}
// Tier-suffix guard: no gemini-3.5-flash-lite row exists, so it must take
// __default__ (1.25+10 = 11.25), NOT the parent gemini-3.5-flash rate (10.5).
const lite = rows["gemini-3.5-flash-lite"];
ok(lite && Math.abs(lite.cost - 11.25) < 0.005,
   "guarded gemini-3.5-flash-lite priced at __default__ 11.25, not flash 10.5 (got " + (lite ? lite.cost.toFixed(2) : "missing") + ")");
// Modality guard: a modality hidden behind a snapshot word (-preview-tts) is
// NOT a snapshot of gemini-2.5-flash — it must also take __default__ + warn.
const tts = rows["gemini-2.5-flash-preview-tts"];
ok(tts && Math.abs(tts.cost - 11.25) < 0.005,
   "guarded gemini-2.5-flash-preview-tts priced at __default__ 11.25, not flash 2.8 (got " + (tts ? tts.cost.toFixed(2) : "missing") + ")");
// Claude cache multipliers at exact rates (opus-4-8: 5+25+6.25+10+0.5):
const cm = rows["claude-opus-4-8"];
ok(cm && Math.abs(cm.cost - 46.75) < 0.005,
   "cache multipliers exact: opus-4-8 1M each in/out/5m/1h/read costs 46.75 (got " + (cm ? cm.cost.toFixed(2) : "missing") + ")");
// Sonnet 5 intro boundary, keyed on the entry OWN date (month periods, so
// the assertion holds regardless of when the suite runs):
const mon = (k) => (s.periods || []).find((p) => p.key === k) || {};
const jul = (mon("2026-07").byModel || {})["claude-sonnet-5"];
const sep = (mon("2026-09").byModel || {})["claude-sonnet-5"];
ok(jul && Math.abs(jul.cost - 12) < 0.005, "sonnet-5 July 2026 entry at intro 2/10 = 12 (got " + (jul ? jul.cost.toFixed(2) : "missing") + ")");
ok(sep && Math.abs(sep.cost - 18) < 0.005, "sonnet-5 September 2026 entry at standard 3/15 = 18 (got " + (sep ? sep.cost.toFixed(2) : "missing") + ")");
// The ONLY unknown-model warnings allowed are the two deliberate guard cases
// — the guard must be VISIBLE (warn), every listed model must price silently.
const unk = log.split("\n").filter((l) => /unknown model/.test(l));
const deliberate = /gemini-3\.5-flash-lite|gemini-2\.5-flash-preview-tts/;
ok(unk.length === 2 && unk.every((l) => deliberate.test(l)),
   "exactly the two deliberate unknown-model warnings, nothing else (got " + unk.length + ")");
process.exit(fail);
' "$TMP"
RES=$?
echo "---- exit $RES"
exit $RES
