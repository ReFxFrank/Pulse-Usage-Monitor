#!/bin/bash
# Effort chips from bare `/effort` (interactive picker) — the level lives only
# in the <local-command-stdout> confirmation echo. Also: quoted words in a
# real prompt must never forge an event.
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
const U = (min, sid, content) => ({ type: "user", timestamp: iso(min), sessionId: sid, cwd: "/p",
  message: { role: "user", content } });
const A = (min, sid, id) => ({ type: "assistant", timestamp: iso(min), sessionId: sid, requestId: "r" + id, cwd: "/p",
  message: { id: "m" + id, model: "claude-fable-5", usage: { input_tokens: 100, output_tokens: 100 } } });
const lines = [
  // Session P: the desktop scenario — bare /effort, EMPTY args, picker echo
  U(60, "sess-P", "<command-name>/effort</command-name>\n<command-message>effort</command-message>\n<command-args></command-args>"),
  U(59, "sess-P", "<local-command-stdout>Set effort level to high (this session only)</local-command-stdout>"),
  U(58, "sess-P", "please fix the server rename bug"),
  A(57, "sess-P", 1),
  // …then picker again → ultracode
  U(50, "sess-P", "<command-name>/effort</command-name>\n<command-message>effort</command-message>\n<command-args></command-args>"),
  U(49, "sess-P", "<local-command-stdout>Set effort level to ultracode (this session only): xhigh + dynamic workflow orchestration</local-command-stdout>"),
  A(48, "sess-P", 2),
  // …then back to auto → chip cleared from here on
  U(40, "sess-P", "<local-command-stdout>Effort level set to auto</local-command-stdout>"),
  A(39, "sess-P", 3),
  // Session Q: a REAL prompt quoting the magic words must NOT forge an event
  U(30, "sess-Q", "why does it say Set effort level to max sometimes?"),
  A(29, "sess-Q", 4),
  // Session R: "Kept effort level as" echo also names the level
  U(20, "sess-R", "<command-name>/effort</command-name>\n<command-message>effort</command-message>\n<command-args></command-args>"),
  U(19, "sess-R", "<local-command-stdout>Kept effort level as max</local-command-stdout>"),
  A(18, "sess-R", 5),
  // Session S: Claude Code >= 2.1.212 records the level ON the assistant entry
  // (top-level `effort`) — no echo anywhere, the recorded field alone must chip
  Object.assign(A(12, "sess-S", 6), { effort: "xhigh" }),
  // Session T: an echo says high, but one entry RECORDS medium — the recorded
  // per-message level is authoritative there; the echo fills the unrecorded one
  U(10, "sess-T", "<command-name>/effort</command-name>\n<command-message>effort</command-message>\n<command-args></command-args>"),
  U(9, "sess-T", "<local-command-stdout>Set effort level to high (this session only)</local-command-stdout>"),
  Object.assign(A(8, "sess-T", 7), { effort: "Medium" }), // case-normalized
  A(7, "sess-T", 8),
];
fs.writeFileSync(process.argv[1] + "/projects/demo/s.jsonl",
  lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
' "$CL"

PORT=4885
CLAUDE_DIR=$CL PULSE_HOME=$PH CODEX_DIR=$TMP/no-codex \
node "$ROOT/server.js" --port $PORT --no-update-check >"$TMP/srv.log" 2>&1 &
SRV=$!
sleep 2
curl -s "http://127.0.0.1:$PORT/api/summary" > "$TMP/out.json"
kill $SRV 2>/dev/null

node -e '
const s = require(process.argv[1] + "/out.json");
let fail = 0;
const ok = (cond, msg) => { console.log((cond ? "PASS" : "FAIL") + "  " + msg); if (!cond) fail = 1; };
const sess = {};
for (const r of s.recentSessions || []) sess[r.sessionId] = r;
const P = sess["sess-P"], Q = sess["sess-Q"], R = sess["sess-R"];
ok(P && Q && R, "all three sessions present");
ok(P && (P.efforts || []).includes("high"), "P: picker echo with EMPTY args yields high chip — got " + JSON.stringify(P && P.efforts));
ok(P && P.ultracode === true, "P: ultracode picker echo flags ULTRA");
ok(Q && (Q.efforts || []).length === 0 && !Q.ultracode, "Q: quoted words in a real prompt forge NOTHING — got " + JSON.stringify(Q && Q.efforts));
ok(R && (R.efforts || []).includes("max"), "R: Kept-effort echo yields max — got " + JSON.stringify(R && R.efforts));
const S2 = sess["sess-S"], T2 = sess["sess-T"];
ok(S2 && (S2.efforts || []).includes("xhigh"), "S: recorded per-entry effort field chips with NO echo — got " + JSON.stringify(S2 && S2.efforts));
ok(T2 && (T2.efforts || []).includes("medium") && (T2.efforts || []).includes("high"),
   "T: recorded level wins on its own entry, echo fills the unrecorded one — got " + JSON.stringify(T2 && T2.efforts));
process.exit(fail);
' "$TMP"
RES=$?
echo "---- exit $RES"
exit $RES
