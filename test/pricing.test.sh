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
// Sonnet 5: the $2/$10 launch price was made PERMANENT on 2026-08-11 (the
// scheduled 2026-09-01 step-up to $3/$15 never happened), so a July entry AND
// a September entry both bill 2/10 (=12 for 1M+1M). Pinned dates -> asserted
// via their calendar-month periods, so this stays valid whenever the suite runs.
lines.push({ type: "assistant", timestamp: "2026-07-15T12:00:00.000Z",
  sessionId: "intro-s", requestId: "ri1", cwd: "/p",
  message: { id: "mi1", model: "claude-sonnet-5", usage: { input_tokens: 1000000, output_tokens: 1000000 } } });
lines.push({ type: "assistant", timestamp: "2026-09-15T12:00:00.000Z",
  sessionId: "intro-s", requestId: "ri2", cwd: "/p",
  message: { id: "mi2", model: "claude-sonnet-5", usage: { input_tokens: 1000000, output_tokens: 1000000 } } });
// Fable 5.1: $10/$50 like Fable 5, but cache READS at 0.025x ($0.25/M) — 1M
// in + 1M out + 1M cache read = 10 + 50 + 0.25 = 60.25 (NOT 61 off the Fable 5
// 0.10x). Proves the per-row cacheReadMult is applied, not the global 0.10.
lines.push({ type: "assistant", timestamp: "2026-09-16T12:00:00.000Z",
  sessionId: "f51-s", requestId: "rf51", cwd: "/p",
  message: { id: "mf51", model: "claude-fable-5-1", usage: { input_tokens: 1000000, output_tokens: 1000000, cache_read_input_tokens: 1000000 } } });
// Mythos 5 (Glasswing twin of Fable 5): $10/$50 -> 1M+1M = 60, and it must
// price SILENTLY (no unknown-model warning) instead of the $3/$15 default.
lines.push({ type: "assistant", timestamp: "2026-09-16T13:00:00.000Z",
  sessionId: "my5-s", requestId: "rmy5", cwd: "/p",
  message: { id: "mmy5", model: "claude-mythos-5", usage: { input_tokens: 1000000, output_tokens: 1000000 } } });
// Mythos Preview: official Glasswing price $25/$125 -> 1M+1M = 150 (an exact
// row; the family prefix must NOT quietly apply the Fable tier).
lines.push({ type: "assistant", timestamp: "2026-09-17T12:00:00.000Z",
  sessionId: "myp-s", requestId: "rmyp", cwd: "/p",
  message: { id: "mmyp", model: "claude-mythos-preview", usage: { input_tokens: 1000000, output_tokens: 1000000 } } });
// Retired Opus 4 dated id: no bare prefix key covers it — explicit row -> 90.
lines.push({ type: "assistant", timestamp: "2026-09-17T13:00:00.000Z",
  sessionId: "op4-s", requestId: "rop4", cwd: "/p",
  message: { id: "mop4", model: "claude-opus-4-20250514", usage: { input_tokens: 1000000, output_tokens: 1000000 } } });
// Partner-cloud ids (Claude Code on Bedrock / Vertex) price via the canonical
// id, silently: sonnet-4-5 1M+1M = 18 for both forms.
lines.push({ type: "assistant", timestamp: "2026-09-17T14:00:00.000Z",
  sessionId: "br-s", requestId: "rbr", cwd: "/p",
  message: { id: "mbr", model: "us.anthropic.claude-sonnet-4-5-20250929-v1:0", usage: { input_tokens: 1000000, output_tokens: 1000000 } } });
lines.push({ type: "assistant", timestamp: "2026-09-17T15:00:00.000Z",
  sessionId: "vx-s", requestId: "rvx", cwd: "/p",
  message: { id: "mvx", model: "claude-sonnet-4-5@20250929", usage: { input_tokens: 1000000, output_tokens: 1000000 } } });
// GovCloud ("us-gov.") and other hyphenated region prefixes must reduce too —
// haiku-4-5 $1/$5 -> 1M+1M = 6, NOT the $3/$15 default (a 3x over-bill).
lines.push({ type: "assistant", timestamp: "2026-09-17T16:00:00.000Z",
  sessionId: "gov-s", requestId: "rgov", cwd: "/p",
  message: { id: "mgov", model: "us-gov.anthropic.claude-haiku-4-5-20251001-v1:0", usage: { input_tokens: 1000000, output_tokens: 1000000 } } });
// inference_geo "us": every token category at 1.1x — opus-4-6 1M+1M = 30 -> 33.
lines.push({ type: "assistant", timestamp: "2026-09-16T14:00:00.000Z",
  sessionId: "geo-s", requestId: "rgeo", cwd: "/p",
  message: { id: "mgeo", model: "claude-opus-4-6", usage: { input_tokens: 1000000, output_tokens: 1000000, inference_geo: "us" } } });
// Opus 5 standard vs fast mode, split across months so each is asserted on its
// own: standard bills 5/25 (=30 for 1M+1M), fast (usage.speed "fast", the
// `/fast` toggle) bills the 10/50 premium (=60). Same fixture shape proves the
// premium comes from the speed field, not the model row.
lines.push({ type: "assistant", timestamp: "2026-05-15T12:00:00.000Z",
  sessionId: "o5-s", requestId: "ro1", cwd: "/p",
  message: { id: "mo1", model: "claude-opus-5", usage: { input_tokens: 1000000, output_tokens: 1000000 } } });
lines.push({ type: "assistant", timestamp: "2026-06-15T12:00:00.000Z",
  sessionId: "o5-s", requestId: "ro2", cwd: "/p",
  message: { id: "mo2", model: "claude-opus-5", usage: { input_tokens: 1000000, output_tokens: 1000000, speed: "fast" } } });
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
// Per model: [id, uncached input, output, cached input]. Prompts stay UNDER
// the 272K long-context threshold (100K + cached) so each row asserts its
// plain rate: cost = 0.1*input$ + output$ (+ 0.1*cached$ where cached).
// Entries are stamped "now" -> current (post-cut) prices; a second rollout
// below is pinned to 2026-07-15 to assert the pre-cut history steps.
const MODELS = [
  ["gpt-5.6-sol", 100000, 1000000, 0], ["gpt-5.6-terra", 100000, 1000000, 0], ["gpt-5.6-luna", 100000, 1000000, 0],
  ["gpt-5.5", 100000, 1000000, 0], ["gpt-5.4", 100000, 1000000, 0], ["gpt-5.4-mini", 100000, 1000000, 0],
  ["gpt-5.3-codex", 100000, 1000000, 0], ["codex-auto-review", 100000, 1000000, 0],
  // GPT-6 Astra: 100K in + 1M out + 100K cached (200K prompt, short context)
  ["gpt-6-astra", 100000, 1000000, 100000],
  ["gpt-6-astra-wm", 100000, 1000000, 0],          // Codex daybreak variant -> Astra rate
  ["gpt-5.6", 100000, 1000000, 0],                 // official alias of Sol
  ["gpt-5.6-cyber", 100000, 1000000, 0],
  ["us.openai.gpt-5.6-terra", 100000, 1000000, 0], // Bedrock-routed id -> canonical lookup
  // long-context: 300K prompt on a dated gpt-5.4 snapshot -> 2x in / 1.5x out
  ["gpt-5.4-2026-03-05", 300000, 100000, 0],
];
const rollout = (sid, base, models) => {
  const lines = [{ timestamp: iso(base - 60e3), type: "session_meta", payload: { session_id: sid, cwd: "/p" } }];
  let cum = { input_tokens: 0, cached_input_tokens: 0, output_tokens: 0, total_tokens: 0 };
  models.forEach(([m, inp, out, cached], i) => {
    const t = base + (i + 1) * 60e3;
    lines.push({ timestamp: iso(t), type: "turn_context",
      payload: { turn_id: sid + "-t" + i, model: m,
                 collaboration_mode: { mode: "default", settings: { model: m, reasoning_effort: "medium" } } } });
    const u = { input_tokens: inp + cached, cached_input_tokens: cached, output_tokens: out, total_tokens: inp + cached + out };
    cum = { input_tokens: cum.input_tokens + u.input_tokens, cached_input_tokens: cum.cached_input_tokens + cached,
            output_tokens: cum.output_tokens + u.output_tokens, total_tokens: cum.total_tokens + u.total_tokens };
    lines.push({ timestamp: iso(t + 30e3), type: "event_msg",
      payload: { type: "token_count", info: { last_token_usage: u, total_token_usage: { ...cum } } } });
  });
  return lines.map((l) => JSON.stringify(l)).join("\n") + "\n";
};
fs.writeFileSync(dir + "/sessions/2026/07/15/rollout-price.jsonl", rollout("price-1", now - 3600e3, MODELS));
// Pre-cut history: the 5.6 family billed at its July rates for July entries.
fs.writeFileSync(dir + "/sessions/2026/07/15/rollout-history.jsonl",
  rollout("price-jul", Date.parse("2026-07-15T12:00:00.000Z"),
    [["gpt-5.6-sol", 100000, 1000000, 0], ["gpt-5.6-terra", 100000, 1000000, 0], ["gpt-5.6-luna", 100000, 1000000, 0]]));
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
// 0.1*input$ + output$ (+0.1*cached$) at the CURRENT (post-cut) rates:
const WANT = { "gpt-5.6-sol": 20.4, "gpt-5.6-terra": 12.2, "gpt-5.6-luna": 1.22, "gpt-5.5": 30.5,
               "gpt-5.4": 15.25, "gpt-5.4-mini": 4.575, "gpt-5.3-codex": 14.175, "codex-auto-review": 15.25,
               "gpt-6-astra": 51.1, "gpt-6-astra-wm": 51, "gpt-5.6": 20.4, "gpt-5.6-cyber": 76.25,
               "us.openai.gpt-5.6-terra": 12.2,
               // 300K prompt > 272K: 300K x $5 + 100K x $22.50 = 1.5 + 2.25
               "gpt-5.4-2026-03-05": 3.75 };
const rows = (s.periods && s.periods[0] && s.periods[0].byModel) || {};
for (const [m, want] of Object.entries(WANT)) {
  const r = rows[m];
  ok(r && Math.abs(r.cost - want) < 0.005, m + " costs $" + want + " (got " + (r ? r.cost.toFixed(2) : "missing") + ")");
}
// Pre-cut history steps: July entries keep the July prices (5/30, 2.5/15, 1/6).
const jul26 = ((s.periods || []).find((p) => p.key === "2026-07") || {}).byModel || {};
for (const [m, want] of Object.entries({ "gpt-5.6-sol": 30.5, "gpt-5.6-terra": 15.25, "gpt-5.6-luna": 6.1 })) {
  const r = jul26[m];
  ok(r && Math.abs(r.cost - want) < 0.005, m + " July 2026 entry at the PRE-cut rate $" + want + " (got " + (r ? r.cost.toFixed(2) : "missing") + ")");
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
ok(sep && Math.abs(sep.cost - 12) < 0.005, "sonnet-5 September 2026 entry ALSO at the now-permanent 2/10 = 12 (got " + (sep ? sep.cost.toFixed(2) : "missing") + ")");
const f51 = (mon("2026-09").byModel || {})["claude-fable-5-1"];
ok(f51 && Math.abs(f51.cost - 60.25) < 0.005, "fable-5-1: per-row 0.025x cache read -> 10+50+0.25 = 60.25 (got " + (f51 ? f51.cost.toFixed(2) : "missing") + ")");
const my5 = (mon("2026-09").byModel || {})["claude-mythos-5"];
ok(my5 && Math.abs(my5.cost - 60) < 0.005, "mythos-5 priced at the Fable tier 10/50 = 60 (got " + (my5 ? my5.cost.toFixed(2) : "missing") + ")");
const geo = (mon("2026-09").byModel || {})["claude-opus-4-6"];
ok(geo && Math.abs(geo.cost - 33) < 0.005, "inference_geo us: opus-4-6 1M+1M = 30 x 1.1 = 33 (got " + (geo ? geo.cost.toFixed(2) : "missing") + ")");
const sep26 = mon("2026-09").byModel || {};
for (const [m, want] of Object.entries({ "claude-mythos-preview": 150, "claude-opus-4-20250514": 90,
                                          "us.anthropic.claude-sonnet-4-5-20250929-v1:0": 18, "claude-sonnet-4-5@20250929": 18,
                                          "us-gov.anthropic.claude-haiku-4-5-20251001-v1:0": 6 })) {
  const r = sep26[m];
  ok(r && Math.abs(r.cost - want) < 0.005, m + " = $" + want + " (got " + (r ? r.cost.toFixed(2) : "missing") + ")");
}
// Opus 5: standard 5/25, and the fast-mode premium 10/50 applied off
// usage.speed — the same 1M+1M entry must cost exactly double when fast.
const o5std = (mon("2026-05").byModel || {})["claude-opus-5"];
const o5fast = (mon("2026-06").byModel || {})["claude-opus-5"];
ok(o5std && Math.abs(o5std.cost - 30) < 0.005, "opus-5 standard at 5/25 = 30 (got " + (o5std ? o5std.cost.toFixed(2) : "missing") + ")");
ok(o5fast && Math.abs(o5fast.cost - 60) < 0.005, "opus-5 fast mode at 10/50 = 60 (got " + (o5fast ? o5fast.cost.toFixed(2) : "missing") + ")");
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
