#!/bin/bash
# `pulse --summary` e2e: a terminal readout with no browser and no server.
# PORT points at a dead port so the runtime-file/loopback lookup MUST fail and
# the in-process fallback is what we are exercising (a stray real Pulse on the
# default port would otherwise answer with the user's own data).
# Contract: always exit 0, NO_COLOR emits no ANSI — including when a configured
# plan label is on screen (the label is printed outside the colour gate).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CL=$TMP/claude; PH=$TMP/pulse; PP=$TMP/pulse-plan
mkdir -p "$CL/projects/demo" "$PH" "$TMP/empty-claude" "$TMP/empty-pulse" "$PP"

# Today: claude-fable-5 ($10/$50) 0.6M output = $30.00
#      + claude-haiku-4-5 ($1/$5) 2.0M output = $10.00   -> today = $40.00
# Both are today, so the 7d and 30d figures are the same $40.00.
node -e '
const fs = require("fs");
const now = Date.now();
const mid = new Date(); mid.setHours(0, 0, 0, 0);
const ts = (n) => new Date(Math.max(now - n * 60e3, mid.getTime())).toISOString();
const E = (t, id, model, out) => ({ type: "assistant", timestamp: t, sessionId: "s1", requestId: "r" + id,
  cwd: "/p", message: { id: "m" + id, model, usage: { input_tokens: 0, output_tokens: out } } });
fs.writeFileSync(process.argv[1] + "/projects/demo/s.jsonl", [
  E(ts(30), 1, "claude-fable-5", 600000),
  E(ts(20), 2, "claude-haiku-4-5", 2000000),
].map(JSON.stringify).join("\n") + "\n");
// Second home, identical logs, WITH a plan configured. The label carries
// ESC[2J (clear screen) + ESC[31m (red) + DEL and is written straight into
// config.json — a label that predates the route sanitizer, or a hand-edited
// one. --summary prints the label outside the colour gate, so rendering it
// verbatim wipes the terminal even under NO_COLOR=1: the renderer has to strip
// control bytes itself. ($40 of usage on a $200 plan -> 0.2x.)
const ESC = String.fromCharCode(27), DEL = String.fromCharCode(127);
fs.writeFileSync(process.argv[2] + "/config.json", JSON.stringify({
  planCost: 200, planLabel: ESC + "[2J" + ESC + "[31mMax 20x" + DEL,
}));
' "$CL" "$PP"

DEAD=4919
# Nothing may answer on DEAD, or the CLI would fetch a real server instead of
# taking the in-process fallback this suite is here to cover.
if curl -s -m 1 "http://127.0.0.1:$DEAD/api/health" >/dev/null 2>&1; then
  echo "FAIL  port $DEAD is not dead — cannot test the offline fallback"; echo "---- exit 1"; exit 1
fi
PULSE_HOME=$PH CLAUDE_DIR=$CL CODEX_DIR=$TMP/no-codex PORT=$DEAD \
PULSE_NO_UPDATE_CHECK=1 PULSE_SUMMARY_MEMO_MS=0 \
node "$ROOT/server.js" --summary > "$TMP/plain.out" 2>"$TMP/plain.out.err"
echo "$?" > "$TMP/plain.out.code"

NO_COLOR=1 PULSE_HOME=$PH CLAUDE_DIR=$CL CODEX_DIR=$TMP/no-codex PORT=$DEAD \
PULSE_NO_UPDATE_CHECK=1 PULSE_SUMMARY_MEMO_MS=0 \
node "$ROOT/server.js" --summary > "$TMP/nocolor.out" 2>"$TMP/nocolor.out.err"
echo "$?" > "$TMP/nocolor.out.code"

# Same fixture, plan configured with the hostile label.
PULSE_HOME=$PP CLAUDE_DIR=$CL CODEX_DIR=$TMP/no-codex PORT=$DEAD \
PULSE_NO_UPDATE_CHECK=1 PULSE_SUMMARY_MEMO_MS=0 \
node "$ROOT/server.js" --summary > "$TMP/plan.out" 2>"$TMP/plan.out.err"
echo "$?" > "$TMP/plan.out.code"

NO_COLOR=1 PULSE_HOME=$PP CLAUDE_DIR=$CL CODEX_DIR=$TMP/no-codex PORT=$DEAD \
PULSE_NO_UPDATE_CHECK=1 PULSE_SUMMARY_MEMO_MS=0 \
node "$ROOT/server.js" --summary > "$TMP/plannc.out" 2>"$TMP/plannc.out.err"
echo "$?" > "$TMP/plannc.out.code"

# No logs at all: still a clean exit 0, never a stack trace to the shell.
PULSE_HOME=$TMP/empty-pulse CLAUDE_DIR=$TMP/empty-claude CODEX_DIR=$TMP/no-codex PORT=$DEAD \
PULSE_NO_UPDATE_CHECK=1 \
node "$ROOT/server.js" --summary > "$TMP/empty.out" 2>"$TMP/empty.out.err"
echo "$?" > "$TMP/empty.out.code"

node -e '
const fs = require("fs"); const T = process.argv[1];
let fail = 0;
const ok = (c, m) => { console.log((c ? "PASS" : "FAIL") + "  " + m); if (!c) fail = 1; };
const R = (f) => fs.readFileSync(T + "/" + f, "utf8");
const code = (f) => R(f + ".code").trim();

const plain = R("plain.out");
ok(code("plain.out") === "0", "exit 0 with no server running (got " + code("plain.out") + ")");
ok(plain.trim().length > 0, "prints something (" + JSON.stringify(plain.slice(0, 120)) + ")");
// $40.00 of spend today; accept either fmtMoney or a plain 2dp render.
ok(/\$40(\.00)?(?![0-9])/.test(plain), "today spend $40.00 present in the readout");
ok(/fable/i.test(plain), "top-models section names the biggest spender (claude-fable-5)");
ok(!/\bError\b|at Object\.|node:internal/.test(plain), "no stack trace leaked into stdout");

const nc = R("nocolor.out");
ok(code("nocolor.out") === "0", "NO_COLOR=1: exit 0");
ok(!/\x1b\[/.test(nc), "NO_COLOR=1: no ANSI escapes emitted");
ok(/\$40(\.00)?(?![0-9])/.test(nc), "NO_COLOR=1: same numbers, just unstyled");
// stdout is a pipe here, so the default run must already be color-free too.
ok(!/\x1b\[/.test(plain), "piped stdout (not a TTY) is color-free as well");

// ---- a configured plan label is DATA, never terminal control ----
// The label round-trips from config.json into the readout. Anything in
// /[\x00-\x1f\x7f-\x9f]/ has to be gone by the time it is written to stdout:
// ESC[2J alone clears the scrollback of whoever ran `pulse --summary`, and the
// colour gate does not cover the label because the label is not styled text.
const CTRL = /[\x00-\x1f\x7f-\x9f]/;
const stripNl = (s) => s.replace(/[\n\r]/g, ""); // newlines are the layout, not payload
const pl = R("plan.out"), pn = R("plannc.out");
ok(code("plan.out") === "0" && code("plannc.out") === "0", "plan configured: still exit 0 both ways");
ok(/\bplan\b/.test(pn) && /0\.2x/.test(pn),
   "plan row renders: $40 of usage on a $200 plan = 0.2x (got " + JSON.stringify((pn.match(/.*plan.*/) || [""])[0]) + ")");
ok(/\$200\/mo/.test(pn), "plan row states the plan price ($200/mo)");
ok(/Max 20x/.test(pn), "the printable part of the label survives — only control bytes are dropped");
ok(!CTRL.test(stripNl(pn)),
   "NO_COLOR=1 with a hostile plan label: NO control characters in the output at all");
ok(!/\x1b/.test(pn), "NO_COLOR=1 with a plan label: no ESC byte reaches the terminal");
ok(!/\x1b/.test(pl), "piped stdout with a plan label: no ESC byte either");

ok(code("empty.out") === "0", "empty fixture home: still exit 0 (got " + code("empty.out") + ")");
process.exit(fail);
' "$TMP"
RES=$?
echo "---- exit $RES"
exit $RES
