#!/bin/bash
# Account meters e2e: codex meters survive at-limit snapshots without
# used_percent; every meter row is provider-labeled; model-scoped weekly
# windows come from the limits[] array (deduped, ordered).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CL=$TMP/claude; CX=$TMP/codex; PH=$TMP/pulse
mkdir -p "$CL/projects/demo" "$CX/sessions/2026/07/15" "$PH"
echo '{"accountMeters": true}' > "$PH/config.json"
# fake login (mock endpoint validates this exact token; NEVER a real one)
echo '{"claudeAiOauth":{"accessToken":"sk-test-oauth-token","expiresAt":9999999999999}}' > "$CL/.credentials.json"

node -e '
const fs = require("fs");
const dir = process.argv[1];
const now = Date.now();
const iso = (ms) => new Date(ms).toISOString();
const ep = (ms) => Math.round(ms / 1000);          // epoch seconds, codex style
const lines = [
  { timestamp: iso(now - 30 * 60e3), type: "session_meta",
    payload: { session_id: "limit-1", cwd: "/p" } },
  // GOOD snapshot: primary window pinned at 100%
  { timestamp: iso(now - 20 * 60e3), type: "event_msg", payload: { type: "token_count",
    info: { last_token_usage: { input_tokens: 100, cached_input_tokens: 0, output_tokens: 50, total_tokens: 150 },
            total_token_usage: { input_tokens: 100, cached_input_tokens: 0, output_tokens: 50, total_tokens: 150 } },
    rate_limits: { primary:   { used_percent: 100, window_minutes: 300,   resets_at: ep(now + 90 * 60e3) },
                   secondary: { used_percent: 87,  window_minutes: 10080, resets_at: ep(now + 5 * 86400e3) } } } },
  // NEWER, MALFORMED snapshot: the at-limit variant with no used_percent anywhere
  { timestamp: iso(now - 5 * 60e3), type: "event_msg", payload: { type: "token_count",
    info: null,
    rate_limits: { primary: { window_minutes: 300, resets_at: ep(now + 90 * 60e3) }, secondary: null } } },
];
fs.writeFileSync(dir + "/sessions/2026/07/15/rollout-limit.jsonl",
  lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
' "$CX"

node "$ROOT/test/mocks/mock-meters.js" >/dev/null 2>&1 &
MOCK=$!
sleep 0.4

PORT=4881
PULSE_HOME=$PH CLAUDE_DIR=$CL CODEX_DIR=$CX \
PULSE_METERS_API=http://127.0.0.1:4870/usage-ok PULSE_METERS_CACHE_MS=500 \
node "$ROOT/server.js" --port $PORT --no-update-check >"$TMP/srv.log" 2>&1 &
SRV=$!
sleep 2.5

# first hit kicks off the async meters fetch; poll until it leaves "loading"
for i in 1 2 3 4 5 6 7 8; do
  curl -s "http://127.0.0.1:$PORT/api/summary" > "$TMP/out.json"
  ST=$(node -e 'const s=require(process.argv[1]);console.log(s.meters&&s.meters.status||"")' "$TMP/out.json")
  [ "$ST" != "loading" ] && [ -n "$ST" ] && break
  sleep 1
done
kill $SRV $MOCK 2>/dev/null

node -e '
const s = require(process.argv[1] + "/out.json");
let fail = 0;
const ok = (cond, msg) => { console.log((cond ? "PASS" : "FAIL") + "  " + msg); if (!cond) fail = 1; };

// (a) codex meters survived the malformed newer snapshot
const cm = s.codexMeters;
ok(!!cm && Array.isArray(cm.buckets) && cm.buckets.length === 2, "codexMeters present with 2 buckets");
if (cm && cm.buckets) {
  const prim = cm.buckets.find((b) => b.key === "codex_primary");
  const sec  = cm.buckets.find((b) => b.key === "codex_secondary");
  ok(prim && prim.pct === 100, "primary bucket pinned at 100% (was: " + (prim && prim.pct) + ")");
  ok(sec && sec.pct === 87, "secondary bucket 87%");
  ok(prim && !prim.stale, "primary not stale (reset is in the future)");
  ok(cm.buckets.every((b) => /^Codex · /.test(b.label)), "all codex rows labeled Codex · …  [" + cm.buckets.map((b) => b.label).join(" | ") + "]");
}

// (b) Claude meter rows provider-labeled
const m = s.meters;
ok(m && m.status === "ok", "claude meters status ok (was: " + (m && m.status) + " " + (m && m.error || "") + ")");
if (m && m.buckets) {
  ok(m.buckets.length >= 3, "claude buckets present (" + m.buckets.length + ")");
  ok(m.buckets.every((b) => /^Claude · /.test(b.label)), "all claude rows labeled Claude · …  [" + m.buckets.map((b) => b.label).join(" | ") + "]");

  // (c) model-scoped weekly windows from the limits[] array
  const fable = m.buckets.find((b) => b.key === "model_scoped:fable");
  ok(fable && fable.pct === 76 && fable.label === "Claude · weekly · Fable" && fable.resetsAt > Date.now(),
     "Fable row from limits[] (label=" + (fable && fable.label) + " pct=" + (fable && fable.pct) + ")");
  const opusRows = m.buckets.filter((b) => /weekly · Opus/i.test(b.label));
  ok(opusRows.length === 1 && opusRows[0].key === "seven_day_opus",
     "limits[] Opus deduped against legacy seven_day_opus (" + opusRows.length + " row)");
  ok(!m.buckets.some((b) => /Nope|apps|Broken/i.test(b.label)),
     "wrong-kind / surface-scoped / malformed limits entries ignored");
  ok(m.buckets[0].key === "five_hour" && m.buckets[1].key === "seven_day",
     "order: 5h, overall weekly, then scoped [" + m.buckets.map((b) => b.key).join(", ") + "]");
}
process.exit(fail);
' "$TMP"
RES=$?
echo "---- exit $RES"
exit $RES
