#!/bin/bash
# Codex account token usage e2e (ChatGPT endpoint).
# A: valid auth.json -> ok, normalized stats, 30-bucket cap, aggregates.
# B: 401 -> expired with re-login hint.
# C: no auth.json -> no-login.
# D: valid-but-empty stats -> ok with zeros, not an error.
# E: corrupt auth.json (header-invalid token) -> no-login, summary still 200.
# F: legacy accountMeters-only config keeps the ChatGPT call OFF.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CL=$TMP/claude; CX=$TMP/codex; PH=$TMP/pulse
mkdir -p "$CL/projects" "$CX/sessions/2026/07/15" "$PH"
echo '{"accountMeters": true, "codexAccountUsage": true}' > "$PH/config.json"
cat > "$CX/auth.json" <<'EOF'
{"OPENAI_API_KEY": null,
 "tokens": {"id_token": "x", "access_token": "fake-cx-token", "refresh_token": "y", "account_id": "acc-test-1"},
 "last_refresh": "2026-07-15T00:00:00Z"}
EOF
# minimal rollout so the machine "has codex"
node -e '
const fs = require("fs"); const now = Date.now();
const iso = (ms) => new Date(ms).toISOString();
fs.writeFileSync(process.argv[1] + "/sessions/2026/07/15/rollout-a.jsonl", [
  { timestamp: iso(now - 60e3), type: "session_meta", payload: { session_id: "s1", cwd: "/p" } },
  { timestamp: iso(now - 30e3), type: "event_msg", payload: { type: "token_count",
    info: { last_token_usage: { input_tokens: 10, cached_input_tokens: 0, output_tokens: 10, total_tokens: 20 },
            total_token_usage: { input_tokens: 10, cached_input_tokens: 0, output_tokens: 10, total_tokens: 20 } },
    rate_limits: { primary: { used_percent: 42, window_minutes: 300, resets_at: Math.round((now + 3600e3) / 1000) } } } },
].map(JSON.stringify).join("\n") + "\n");
' "$CX"

node "$ROOT/test/mocks/mock-cxusage.js" >/dev/null 2>&1 &
MOCK=$!
sleep 0.4

PORT=4883
run_pulse() { # $1 = usage api url, $2 = out json; writes HTTP code to $2.code
  PULSE_HOME=$PH CLAUDE_DIR=$CL CODEX_DIR=$CX \
  PULSE_CODEX_USAGE_API="$1" PULSE_CODEX_USAGE_CACHE_MS=500 \
  node "$ROOT/server.js" --port $PORT --no-update-check >"$TMP/srv.log" 2>&1 &
  SRV=$!
  sleep 2
  for i in 1 2 3 4 5 6; do
    CODE=$(curl -s -o "$2" -w "%{http_code}" "http://127.0.0.1:$PORT/api/summary")
    echo "$CODE" > "$2.code"
    [ "$CODE" != "200" ] && break
    ST=$(node -e 'const s=require(process.argv[1]);console.log(s.codexUsage&&s.codexUsage.status||"")' "$2" 2>/dev/null)
    [ "$ST" != "loading" ] && [ -n "$ST" ] && break
    sleep 1
  done
  kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
}

run_pulse "http://127.0.0.1:4872/profiles-ok" "$TMP/ok.json"
run_pulse "http://127.0.0.1:4872/profiles-401" "$TMP/401.json"
run_pulse "http://127.0.0.1:4872/profiles-zero" "$TMP/zero.json"

# corrupted auth.json: newline inside the token must be no-login, never a 500
printf '{"tokens":{"access_token":"abc\\ndef","account_id":"acc-test-1"}}' > "$CX/auth.json"
run_pulse "http://127.0.0.1:4872/profiles-ok" "$TMP/corrupt.json"

rm "$CX/auth.json"
run_pulse "http://127.0.0.1:4872/profiles-ok" "$TMP/nologin.json"

# legacy config: accountMeters alone (pre-1.6.0 consent) must NOT enable the
# ChatGPT call
printf '{"tokens":{"access_token":"fake-cx-token","account_id":"acc-test-1"}}' > "$CX/auth.json"
echo '{"accountMeters": true}' > "$PH/config.json"
run_pulse "http://127.0.0.1:4872/profiles-ok" "$TMP/legacy.json"
kill $MOCK 2>/dev/null

node -e '
const SP = process.argv[1];
let fail = 0;
const ok = (cond, msg) => { console.log((cond ? "PASS" : "FAIL") + "  " + msg); if (!cond) fail = 1; };

const A = require(SP + "/ok.json").codexUsage;
ok(A && A.enabled && A.status === "ok", "A: status ok (" + (A && A.status) + " " + (A && A.error || "") + ")");
if (A && A.stats) {
  const st = A.stats;
  ok(st.lifetimeTokens === 812345678, "A: lifetime 812,345,678 (got " + st.lifetimeTokens + ")");
  ok(st.peakDailyTokens === 45678901, "A: peak day 45,678,901");
  ok(st.buckets.length === 30, "A: buckets capped at 30 (got " + st.buckets.length + ")");
  ok(st.todayTokens === 1000000, "A: today = today bucket (got " + st.todayTokens + ")");
  // last 7 buckets: i=6..0 -> 7 * 1e6 + (6+5+4+3+2+1+0) * 1e4 = 7,210,000
  ok(st.last7Tokens === 7210000, "A: last-7-day sum (got " + st.last7Tokens + ")");
  const sorted = st.buckets.every((b, i, a) => i === 0 || a[i - 1].date <= b.date);
  ok(sorted, "A: buckets date-sorted ascending");
} else { ok(false, "A: stats present"); }

const B = require(SP + "/401.json").codexUsage;
ok(B && B.status === "expired", "B: 401 -> expired (" + (B && B.status) + ")");
ok(B && /run `codex`/.test(B.error || ""), "B: re-login hint present");

const C = require(SP + "/nologin.json").codexUsage;
ok(C && C.status === "no-login", "C: missing auth.json -> no-login (" + (C && C.status) + ")");

const Z = require(SP + "/zero.json").codexUsage;
ok(Z && Z.status === "ok", "D: empty stats -> ok, not error (" + (Z && Z.status) + ")");
ok(Z && Z.stats && Z.stats.todayTokens === 0 && Z.stats.buckets.length === 0,
   "D: zero-usage stats normalized to zeros");

const fs = require("fs");
const K = require(SP + "/corrupt.json").codexUsage;
const KC = fs.readFileSync(SP + "/corrupt.json.code", "utf8").trim();
ok(KC === "200", "E: corrupt auth.json -> summary still HTTP 200 (got " + KC + ")");
ok(K && K.status === "no-login", "E: header-invalid token -> no-login, not a wedge (" + (K && K.status) + ")");

const L = require(SP + "/legacy.json").codexUsage;
ok(L && L.enabled === false, "F: legacy accountMeters-only config keeps ChatGPT call OFF");

const log = fs.readFileSync(SP + "/srv.log", "utf8");
ok(!/fake-cx-token/.test(log), "token never appears in server logs");
process.exit(fail);
' "$TMP"
RES=$?
echo "---- exit $RES"
exit $RES
