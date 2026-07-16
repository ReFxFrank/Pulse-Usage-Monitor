#!/bin/bash
# Analytics breakdowns e2e: per-period spend by effort level (incl. ultracode /
# default) and by project, sorted by cost.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CL=$TMP/claude; PH=$TMP/pulse
mkdir -p "$CL/projects/demo" "$PH"

node -e '
const fs = require("fs");
const now = Date.now();
const iso = (m) => new Date(now - m * 60e3).toISOString();
const U = (min, sid, cwd, content) => ({ type: "user", timestamp: iso(min), sessionId: sid, cwd,
  message: { role: "user", content } });
const A = (min, sid, cwd, id, inTok, outTok) => ({ type: "assistant", timestamp: iso(min), sessionId: sid, requestId: "r" + id, cwd,
  message: { id: "m" + id, model: "claude-fable-5", usage: { input_tokens: inTok, output_tokens: outTok } } });
const eff = (min, sid, cwd, lvl) => U(min, sid, cwd,
  "<command-name>/effort</command-name>\n<command-message>effort</command-message>\n<command-args>" + lvl + "</command-args>");
const A_DIR = "/home/me/projA", B_DIR = "/home/me/projB", C_DIR = "/home/me/projC";
const lines = [
  // projA: /effort high -> 300k tokens at "high"
  eff(60, "sA", A_DIR, "high"),
  A(58, "sA", A_DIR, 1, 200000, 100000),
  // projB: /effort ultracode -> 200k at "ultracode"
  eff(50, "sB", B_DIR, "ultracode"),
  A(48, "sB", B_DIR, 2, 100000, 100000),
  // projC: no effort -> 100k at "default"
  U(40, "sC", C_DIR, "just a normal prompt"),
  A(38, "sC", C_DIR, 3, 50000, 50000),
];
fs.writeFileSync(process.argv[1] + "/projects/demo/s.jsonl", lines.map(JSON.stringify).join("\n") + "\n");
' "$CL"

PORT=4889
CLAUDE_DIR=$CL PULSE_HOME=$PH CODEX_DIR=$TMP/no-codex \
node "$ROOT/server.js" --port $PORT --no-update-check >"$TMP/srv.log" 2>&1 &
SRV=$!
sleep 2.5
curl -s "http://127.0.0.1:$PORT/api/summary" > "$TMP/out.json"
kill $SRV 2>/dev/null

node -e '
const s = require(process.argv[1] + "/out.json");
let fail = 0;
const ok = (c, m) => { console.log((c ? "PASS" : "FAIL") + "  " + m); if (!c) fail = 1; };
const p = (s.periods || []).find((x) => x.key === "last30");
ok(!!p, "last30 period present");
const es = (p && p.effortSpend) || {};
ok(es.high && es.high.tokens === 300000, "effort: high = 300k tokens (got " + (es.high && es.high.tokens) + ")");
ok(es.ultracode && es.ultracode.tokens === 200000, "effort: ultracode = 200k (got " + (es.ultracode && es.ultracode.tokens) + ")");
ok(es.default && es.default.tokens === 100000, "effort: default = 100k (got " + (es.default && es.default.tokens) + ")");
ok(!es.medium && !es.low, "effort: no spurious buckets");

const bp = (p && p.byProject) || [];
ok(bp.length === 3, "3 projects (got " + bp.length + ")");
ok(bp[0].project.endsWith("projA") && bp[0].tokens === 300000, "byProject sorted by cost: projA first, 300k (got " + (bp[0] && bp[0].project) + ")");
ok(bp[1].project.endsWith("projB") && bp[2].project.endsWith("projC"), "byProject order projB, projC");
ok(bp[0].sessions === 1, "byProject session count (got " + (bp[0] && bp[0].sessions) + ")");
ok(typeof p.liveCost === "number" && Math.abs(p.liveCost - (es.high.cost + es.ultracode.cost + es.default.cost)) < 1e-9,
   "liveCost = sum of effort buckets");
process.exit(fail);
' "$TMP"
RES=$?
echo "---- exit $RES"
exit $RES
