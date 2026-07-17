#!/bin/bash
# Activity heatmap: entries land in the right weekday×hour cell (local time),
# cells sum correctly, and max tracking is right.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CL=$TMP/claude; PH=$TMP/pulse
mkdir -p "$CL/projects/demo" "$PH"

# Fixed timestamps; compute expected (weekday,hour) with the SAME local-time
# method the server uses, so the assert is timezone-agnostic.
node -e '
const fs = require("fs");
const T = [
  ["2026-07-13T09:15:00Z", 200000, 100000], // cell A
  ["2026-07-13T09:45:00Z", 100000, 50000],  // cell A again (same hour) -> sums
  ["2026-07-15T22:30:00Z", 60000, 40000],   // cell B (different day+hour)
];
const A = (iso, i, inTok, outTok) => ({ type: "assistant", timestamp: iso, sessionId: "s"+i, requestId: "r"+i, cwd: "/p",
  message: { id: "m"+i, model: "claude-fable-5", usage: { input_tokens: inTok, output_tokens: outTok } } });
fs.writeFileSync(process.argv[1] + "/projects/demo/s.jsonl",
  T.map((t, i) => A(t[0], i, t[1], t[2])).map(JSON.stringify).join("\n") + "\n");
const cell = (iso) => { const d = new Date(iso); return [d.getDay(), d.getHours()]; };
fs.writeFileSync(process.argv[2], JSON.stringify({
  a: cell(T[0][0]), aTokens: 200000+100000+50000+100000, aMsgs: 2,   // 2 entries, tokens summed
  b: cell(T[2][0]), bTokens: 60000+40000, bMsgs: 1,
}));
' "$CL" "$TMP/exp.json"

PORT=4897
CLAUDE_DIR=$CL PULSE_HOME=$PH CODEX_DIR=$TMP/no-codex \
node "$ROOT/server.js" --port $PORT --no-update-check >"$TMP/srv.log" 2>&1 &
SRV=$!
sleep 2.5
curl -s "http://127.0.0.1:$PORT/api/summary" > "$TMP/out.json"
kill $SRV 2>/dev/null

node -e '
const s = require(process.argv[1] + "/out.json");
const E = require(process.argv[1] + "/exp.json");
let fail = 0;
const ok = (c, m) => { console.log((c ? "PASS" : "FAIL") + "  " + m); if (!c) fail = 1; };
const hm = s.heatmap;
ok(hm && Array.isArray(hm.grid) && hm.grid.length === 7 && hm.grid[0].length === 24, "7x24 grid present");
const cA = hm.grid[E.a[0]][E.a[1]], cB = hm.grid[E.b[0]][E.b[1]];
ok(cA && cA.tokens === E.aTokens && cA.messages === E.aMsgs, "cell A sums two same-hour entries (tokens " + (cA&&cA.tokens) + "/" + E.aTokens + ", msgs " + (cA&&cA.messages) + ")");
ok(cB && cB.tokens === E.bTokens && cB.messages === E.bMsgs, "cell B distinct day/hour (tokens " + (cB&&cB.tokens) + "/" + E.bTokens + ")");
// every other cell empty
let nonzero = 0; for (const row of hm.grid) for (const c of row) if (c.messages > 0) nonzero++;
ok(nonzero === 2, "exactly 2 non-empty cells (got " + nonzero + ")");
ok(hm.maxMessages === 2, "maxMessages = 2 (got " + hm.maxMessages + ")");
ok(hm.maxCost > 0 && Math.abs(hm.maxCost - cA.cost) < 1e-9, "maxCost = busiest cell cost");
process.exit(fail);
' "$TMP"
RES=$?
echo "---- exit $RES"
exit $RES
