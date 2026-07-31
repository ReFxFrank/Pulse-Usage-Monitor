#!/bin/bash
# "Run at startup" (Windows Run key) — the one feature that deliberately writes
# outside ~/.pulse, so it gets the strictest harness we have:
#
#   THIS SUITE MUST NEVER TOUCH THE DEVELOPER'S REAL REGISTRY. Every server
#   here runs with PULSE_STARTUP_STUB pointed at a throwaway JSON file in a
#   temp dir; with that env var set the whole startup state is read from and
#   written to that file instead of HKCU\...\Run. If a change ever makes the
#   server fall back to reg.exe while the stub is set, that is a bug — do not
#   "fix" this suite by dropping the stub.
#
# Covered:
# - payload.startup = {supported:boolean, enabled:false} by default.
# - POST /api/startup/enable -> enabled true, and the stub file holds a quoted
#   absolute exe path followed by --no-open (silent, server-only autostart).
# - a second enable is idempotent (same stored value, still enabled).
# - the state survives a restart (it lives in the stub, not in memory).
# - POST /api/startup/disable -> enabled false, and a fresh server agrees.
# - GET on the mutation routes is refused (allowMutation-guarded).
# - CLI --startup on|off|status drives the same state and always exits 0.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CL=$TMP/claude; PH=$TMP/pulse
mkdir -p "$CL/projects/demo" "$PH"
echo '{}' > "$PH/config.json"

node -e '
const fs = require("fs");
fs.writeFileSync(process.argv[1] + "/projects/demo/s.jsonl", JSON.stringify({
  type: "assistant", timestamp: new Date().toISOString(), sessionId: "s", requestId: "r", cwd: "/p",
  message: { id: "m", model: "claude-fable-5", usage: { input_tokens: 0, output_tokens: 10000 } } }) + "\n");
' "$CL"

# The stub stands in for the registry. On Git Bash a /tmp path is virtual, so
# hand the server (a native Windows node) a native path.
STUB=$TMP/startup-stub.json
if command -v cygpath >/dev/null 2>&1; then STUB_NATIVE=$(cygpath -w "$STUB"); else STUB_NATIVE=$STUB; fi

PORT=4914
start_server() {
  PULSE_HOME=$PH CLAUDE_DIR=$CL CODEX_DIR=$TMP/nc PULSE_SUMMARY_MEMO_MS=0 \
  PULSE_STARTUP_STUB="$STUB_NATIVE" \
  PULSE_NO_TRAY_SPAWN=1 PULSE_NO_OPENUSAGE_SPAWN=1 PULSE_NO_STRIP_SPAWN=1 \
  node "$ROOT/server.js" --port $PORT --no-update-check >>"$TMP/srv.log" 2>&1 &
  SRV=$!
  sleep 2.2
}
stop_server() { kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; sleep 0.6; }

start_server
curl -s "http://127.0.0.1:$PORT/api/summary" > "$TMP/before.json"
GETEN=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/api/startup/enable")
GETDIS=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/api/startup/disable")
[ -f "$STUB" ] && cp "$STUB" "$TMP/stub-after-gets.json" || echo '{}' > "$TMP/stub-after-gets.json"

curl -s -X POST -H 'X-Pulse: 1' "http://127.0.0.1:$PORT/api/startup/enable" > "$TMP/en.json"
cp "$STUB" "$TMP/stub-on.json" 2>/dev/null || echo 'MISSING' > "$TMP/stub-on.json"
curl -s "http://127.0.0.1:$PORT/api/summary" > "$TMP/on.json"
# Idempotence: enabling twice must not double-write or change the stored value.
curl -s -X POST -H 'X-Pulse: 1' "http://127.0.0.1:$PORT/api/startup/enable" > "$TMP/en2.json"
cp "$STUB" "$TMP/stub-on2.json" 2>/dev/null || echo 'MISSING' > "$TMP/stub-on2.json"
stop_server

# Restart: the entry is registry(stub)-backed, so it must still read as on.
start_server
curl -s "http://127.0.0.1:$PORT/api/summary" > "$TMP/restart-on.json"
curl -s -X POST -H 'X-Pulse: 1' "http://127.0.0.1:$PORT/api/startup/disable" > "$TMP/dis.json"
cp "$STUB" "$TMP/stub-off.json" 2>/dev/null || echo '{}' > "$TMP/stub-off.json"
curl -s "http://127.0.0.1:$PORT/api/summary" > "$TMP/off.json"
stop_server

start_server
curl -s "http://127.0.0.1:$PORT/api/summary" > "$TMP/restart-off.json"
stop_server

# CLI surface (same stub, no server involved). Wrapped in `timeout` where it
# exists: --startup must print and exit, never fall through to booting a
# server — a hang here would otherwise stall the whole suite.
if command -v timeout >/dev/null 2>&1; then GUARD="timeout 20"; else GUARD=""; fi
run_cli() {
  PULSE_HOME=$PH CLAUDE_DIR=$CL CODEX_DIR=$TMP/nc PULSE_STARTUP_STUB="$STUB_NATIVE" \
  $GUARD node "$ROOT/server.js" --startup "$1" >"$TMP/cli-$1.txt" 2>&1
  echo $?
}
CLI_ON=$(run_cli on)
cp "$STUB" "$TMP/stub-cli-on.json" 2>/dev/null || echo 'MISSING' > "$TMP/stub-cli-on.json"
CLI_STATUS_ON=$(run_cli status); cp "$TMP/cli-status.txt" "$TMP/cli-status-on.txt"
CLI_OFF=$(run_cli off)
CLI_STATUS_OFF=$(run_cli status); cp "$TMP/cli-status.txt" "$TMP/cli-status-off.txt"
cp "$STUB" "$TMP/stub-cli-off.json" 2>/dev/null || echo '{}' > "$TMP/stub-cli-off.json"

node -e '
const fs = require("fs"); const path = require("path");
const T = process.argv[1];
let fail = 0;
const ok = (c, m) => { console.log((c ? "PASS" : "FAIL") + "  " + m); if (!c) fail = 1; };
const skip = (m) => console.log("SKIP  " + m);
const R = (f) => fs.readFileSync(T + "/" + f, "utf8");
const J = (f) => JSON.parse(R(f));

const before = J("before.json");
ok(before.startup && typeof before.startup.supported === "boolean" && before.startup.enabled === false,
   "payload.startup present, {supported:boolean, enabled:false} by default (supported=" +
   (before.startup && before.startup.supported) + ")");

const [getEn, getDis] = [process.argv[2], process.argv[3]];
const refused = (c) => c === "403" || c === "404" || c === "405";
ok(refused(getEn), "GET /api/startup/enable is refused (got " + getEn + ")");
ok(refused(getDis), "GET /api/startup/disable is refused (got " + getDis + ")");
// A refused GET must not have written anything to the registry stub either.
ok(R("stub-after-gets.json").indexOf("--no-open") < 0,
   "a refused GET writes nothing to the startup entry");

if (!(before.startup && before.startup.supported)) {
  // Non-Windows: the Run key does not exist, so enable/disable have nothing to
  // do. Shape + guard assertions above still apply.
  skip("enable/disable assertions (startup.supported === false on this platform)");
  process.exit(fail);
}

const en = J("en.json");
ok(en.ok === true && en.startup && en.startup.enabled === true, "POST enable -> {ok:true, enabled:true}");
ok(J("on.json").startup.enabled === true, "summary reflects enabled");

// The value that would land in HKCU\...\Run: a QUOTED absolute exe path plus
// --no-open (so the autostart is silent — no browser window on login).
const stubOn = R("stub-on.json");
ok(stubOn !== "MISSING", "the stub file (stand-in registry) exists after enable");
const values = [];
(function walk(v) {
  if (typeof v === "string") values.push(v);
  else if (v && typeof v === "object") Object.values(v).forEach(walk);
})(stubOn === "MISSING" ? {} : JSON.parse(stubOn));
const val = values.find((s) => s.indexOf("--no-open") >= 0) || "";
ok(!!val, "the stub records a startup value containing --no-open");
// Packaged, the value is `"<...>\pulse.exe" --no-open`. Run from a source
// checkout (which is how this suite runs) there is no pulse.exe, so it is
// `"<node>" "<server.js>" --no-open` — same shape, one extra quoted path.
// Either way: only quoted ABSOLUTE paths that really exist, then --no-open,
// and nothing else on the line.
const m = /^((?:"[^"]+"\s+)+)--no-open\s*$/.exec(val);
ok(!!m, "value is quoted path(s) followed by --no-open, with no trailing junk (got: " + val + ")");
if (m) {
  const paths = m[1].match(/"[^"]+"/g).map((s) => s.slice(1, -1));
  ok(paths.every((p) => path.isAbsolute(p) && fs.existsSync(p)),
     "every quoted path is absolute and exists (" + paths.join(" | ") + ")");
  ok(paths[0] === process.execPath || /pulse(\.exe)?$/i.test(paths[0]),
     "the launched binary is the Pulse exe (or, from source, this node) — not a relative or stale path");
}

const en2 = J("en2.json");
ok(en2.ok === true && en2.startup.enabled === true, "a second enable still reports enabled (idempotent)");
ok(R("stub-on2.json") === stubOn, "a second enable stores the identical value (no duplicate/drifted entry)");

ok(J("restart-on.json").startup.enabled === true,
   "state survives a restart (read back from the registry stub, not memory)");

const dis = J("dis.json");
ok(dis.ok === true && dis.startup && dis.startup.enabled === false, "POST disable -> {ok:true, enabled:false}");
ok(J("off.json").startup.enabled === false, "summary reflects disabled (memo busted by the write)");
const stubOff = R("stub-off.json");
let offParsed = {}; try { offParsed = JSON.parse(stubOff); } catch (_) {}
ok(stubOff.indexOf("--no-open") < 0 || offParsed.enabled === false,
   "the stub no longer holds an enabled startup entry after disable");
ok(J("restart-off.json").startup.enabled === false, "a fresh server agrees the entry is gone");

// CLI: --startup on|off|status. Fail-open like the other CLI surfaces — always
// exit 0 — and it drives the same stub-backed state.
const [cliOn, cliStatusOn, cliOff, cliStatusOff] =
  [process.argv[4], process.argv[5], process.argv[6], process.argv[7]];
ok(cliOn === "0" && cliOff === "0" && cliStatusOn === "0" && cliStatusOff === "0",
   "--startup on|off|status all exit 0 (got " + [cliOn, cliOff, cliStatusOn, cliStatusOff].join(",") + ")");
ok(R("stub-cli-on.json").indexOf("--no-open") >= 0, "--startup on writes the same startup value");
const stubCliOff = R("stub-cli-off.json");
let cliOffParsed = {}; try { cliOffParsed = JSON.parse(stubCliOff); } catch (_) {}
ok(stubCliOff.indexOf("--no-open") < 0 || cliOffParsed.enabled === false,
   "--startup off clears it again");
// Must name the feature AND its state — "already running on port …" from a
// fallthrough must not be able to satisfy this.
const statusOn = R("cli-status-on.txt"), statusOff = R("cli-status-off.txt");
ok(/start(up)?|windows/i.test(statusOn) && /\b(on|enabled|yes)\b/i.test(statusOn),
   "--startup status names the feature and reports it enabled");
ok(/start(up)?|windows/i.test(statusOff) && /\b(off|disabled|not enabled|no)\b/i.test(statusOff),
   "--startup status names the feature and reports it disabled");
process.exit(fail);
' "$TMP" "$GETEN" "$GETDIS" "$CLI_ON" "$CLI_STATUS_ON" "$CLI_OFF" "$CLI_STATUS_OFF"
RES=$?
echo "---- exit $RES"
exit $RES
