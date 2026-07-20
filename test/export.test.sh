#!/bin/bash
# CSV/JSON export e2e: GET /api/export serializes the dashboard's aggregations.
# Covers: daily CSV (with per-source columns + UTF-8 BOM), by-model CSV at exact
# cost, sessions CSV with RFC-4180 quoting of a comma+quote title, JSON full
# payload with attachment headers, the ?sources= scoping, a 400 on an unknown
# data set, and the allowRead DNS-rebinding guard (foreign Host -> 403).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CL=$TMP/claude; CX=$TMP/codex; PH=$TMP/pulse
mkdir -p "$CL/projects/demo" "$CX/sessions/2026/07/15" "$PH"

# Claude (source cli): fable-5 ($10/$50) 100k in + 100k out = $6 today. The
# session's first user message contains a comma AND quotes so the sessions CSV
# must emit an RFC-4180 quoted cell.
node -e '
const fs = require("fs"); const now = Date.now();
const iso = (m) => new Date(now - m * 60e3).toISOString();
fs.writeFileSync(process.argv[1] + "/projects/demo/s.jsonl", [
  { type: "user", timestamp: iso(20), sessionId: "s1", cwd: "/p",
    message: { role: "user", content: "Fix the \"big, scary\" bug" } },
  { type: "assistant", timestamp: iso(19), sessionId: "s1", requestId: "r1", cwd: "/p",
    message: { id: "m1", model: "claude-fable-5", usage: { input_tokens: 100000, output_tokens: 100000 } } },
].map(JSON.stringify).join("\n") + "\n");
' "$CL"

# Codex (source codex): gpt-5.6-luna ($1/$6) 1M in + 1M out = $7 today.
node -e '
const fs = require("fs"); const now = Date.now();
const iso = (ms) => new Date(ms).toISOString();
const lines = [
  { timestamp: iso(now - 3600e3), type: "session_meta", payload: { session_id: "cx1", cwd: "/p" } },
  { timestamp: iso(now - 30 * 60e3), type: "turn_context",
    payload: { turn_id: "t0", model: "gpt-5.6-luna",
      collaboration_mode: { mode: "default", settings: { model: "gpt-5.6-luna", reasoning_effort: "medium" } } } },
  { timestamp: iso(now - 29 * 60e3), type: "event_msg",
    payload: { type: "token_count", info: {
      last_token_usage: { input_tokens: 1000000, cached_input_tokens: 0, output_tokens: 1000000, total_tokens: 2000000 },
      total_token_usage: { input_tokens: 1000000, cached_input_tokens: 0, output_tokens: 1000000, total_tokens: 2000000 } } } },
];
fs.writeFileSync(process.argv[1] + "/sessions/2026/07/15/rollout-x.jsonl",
  lines.map(JSON.stringify).join("\n") + "\n");
' "$CX"

PORT=4899
CLAUDE_DIR=$CL CODEX_DIR=$CX PULSE_HOME=$PH \
node "$ROOT/server.js" --port $PORT --no-update-check >"$TMP/srv.log" 2>&1 &
SRV=$!
sleep 2.5

B="http://127.0.0.1:$PORT/api/export"
curl -s -D "$TMP/daily.h"    "$B?format=csv&data=daily&period=last30"    > "$TMP/daily.csv"
curl -s                      "$B?format=csv&data=models&period=last30"   > "$TMP/models.csv"
curl -s                      "$B?format=csv&data=sessions&period=last30" > "$TMP/sessions.csv"
curl -s                      "$B?format=csv&data=daily&period=last30&sources=cli" > "$TMP/dailycli.csv"
curl -s -D "$TMP/json.h"     "$B?format=json"                            > "$TMP/full.json"
BAD=$(curl -s -o "$TMP/bad.json" -w "%{http_code}" "$B?format=csv&data=nonsense")
EVIL=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: evil.example.com" "$B?format=csv&data=daily")
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

node -e '
const fs = require("fs"); const T = process.argv[1];
let fail = 0;
const ok = (c, m) => { console.log((c ? "PASS" : "FAIL") + "  " + m); if (!c) fail = 1; };
const near = (a, b) => Math.abs(a - b) < 0.005;

const daily = fs.readFileSync(T + "/daily.csv", "utf8");
ok(daily.charCodeAt(0) === 0xFEFF, "daily CSV starts with a UTF-8 BOM");
const dlines = daily.slice(1).split("\r\n").filter(Boolean);
ok(dlines[0] === "date,cost_usd,tokens,cost_cli,cost_codex",
   "daily header has per-source cost columns (got " + dlines[0] + ")");
const today = new Date(); const ds = today.getFullYear() + "-" +
  String(today.getMonth() + 1).padStart(2, "0") + "-" + String(today.getDate()).padStart(2, "0");
const trow = dlines.find((l) => l.startsWith(ds + ","));
ok(!!trow, "daily CSV has a row for today");
const tc = (trow || "").split(",");
ok(trow && near(+tc[1], 13) && near(+tc[3], 6) && near(+tc[4], 7),
   "today: total 13 = cli 6 + codex 7 (got " + trow + ")");

const models = fs.readFileSync(T + "/models.csv", "utf8").slice(1).split("\r\n").filter(Boolean);
ok(models[0] === "model,cost_usd,tokens,messages", "models header");
const luna = models.find((l) => l.startsWith("gpt-5.6-luna,"));
ok(luna && near(+luna.split(",")[1], 7), "models CSV: gpt-5.6-luna costs 7 (got " + luna + ")");
const fable = models.find((l) => l.startsWith("claude-fable-5,"));
ok(fable && near(+fable.split(",")[1], 6), "models CSV: claude-fable-5 costs 6 (got " + fable + ")");

// Title cell = "<project> · <prompt> · <shortId>" — the comma+quotes in the
// prompt force RFC-4180: whole cell wrapped in quotes, inner quotes doubled.
const sess = fs.readFileSync(T + "/sessions.csv", "utf8");
ok(/"[^\r\n]*Fix the ""big, scary"" bug[^\r\n]*"/.test(sess),
   "sessions CSV: comma+quote title is RFC-4180 quoted (wrapped, quotes doubled)");

const cliOnly = fs.readFileSync(T + "/dailycli.csv", "utf8").slice(1).split("\r\n").filter(Boolean);
ok(cliOnly[0] === "date,cost_usd,tokens,cost_cli", "?sources=cli drops the codex column");
const crow = cliOnly.find((l) => l.startsWith(ds + ","));
ok(crow && near(+crow.split(",")[1], 6), "?sources=cli: today totals only the cli $6 (got " + crow + ")");

const dh = fs.readFileSync(T + "/daily.h", "utf8");
ok(/content-type:\s*text\/csv/i.test(dh), "CSV served as text/csv");
ok(/content-disposition:\s*attachment; filename="pulse-daily-last30-\d{8}\.csv"/i.test(dh),
   "CSV attachment filename carries data set, period, date");
const jh = fs.readFileSync(T + "/json.h", "utf8");
ok(/content-disposition:\s*attachment; filename="pulse-export-\d{8}\.json"/i.test(jh), "JSON attachment filename");
const full = JSON.parse(fs.readFileSync(T + "/full.json", "utf8"));
ok(full.version && Array.isArray(full.periods) && full.periods.length > 0, "JSON export is the full payload");

ok(process.argv[2] === "400", "unknown data set -> 400 (got " + process.argv[2] + ")");
ok(process.argv[3] === "403", "foreign Host header -> 403 DNS-rebinding guard (got " + process.argv[3] + ")");
process.exit(fail);
' "$TMP" "$BAD" "$EVIL"
RES=$?
echo "---- exit $RES"
exit $RES
