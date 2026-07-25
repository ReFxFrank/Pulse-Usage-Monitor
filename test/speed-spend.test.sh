#!/bin/bash
# Speed spend e2e: every spend period splits cost/tokens/messages by fast vs
# standard mode and reports fastPremium — what the fast entries cost ON TOP of
# that model's standard rate. Fast rows exist only on claude-opus-5 and
# claude-opus-4-8 (10/50 fast vs 5/25 standard), so for those models the
# premium equals the standard-rate cost of the same tokens.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/claudeA/projects/demo" "$TMP/pulseA" \
         "$TMP/claudeB/projects/demo" "$TMP/pulseB"

# All entries are TODAY: speed is a per-entry field and the sealed archive keeps
# no per-entry detail, so this breakdown is LIVE-only (same convention as
# effortSpend/byProject).
node -e '
const fs = require("fs");
const T = process.argv[1];
const now = Date.now();
const mid = new Date(); mid.setHours(0, 0, 0, 0);
const ts = (n) => new Date(Math.max(now - n * 60e3, mid.getTime())).toISOString();
const E = (t, id, model, usage) => ({ type: "assistant", timestamp: t, sessionId: "s1", requestId: "r" + id,
  cwd: "/p", message: { id: "m" + id, model, usage } });
const w = (dir, lines) => fs.writeFileSync(T + "/" + dir + "/projects/demo/s.jsonl", lines.map(JSON.stringify).join("\n") + "\n");

// --- A: fast + standard in the same period ---------------------------------
// claude-opus-5 FAST (10/50): 1M in + 1M out = 10.00 + 50.00 = 60.00
//   at standard (5/25) the same tokens are 5.00 + 25.00 = 30.00 -> premium 30.00
// claude-opus-4-8 FAST (10/50): 0.2M out = 10.00 ; standard 25 -> 5.00 -> premium 5.00
// claude-opus-5 standard: 2M in + 0.4M out = 10.00 + 10.00 = 20.00
// claude-fable-5 (no fast row at all): 0.1M out = 5.00, contributes NO premium
// -> fast     { cost 70.00, tokens 2.2M, messages 2 }
//    standard { cost 25.00, tokens 2.5M, messages 2 }
//    fastPremium 35.00 ; period cost 95.00
w("claudeA", [
  E(ts(40), 1, "claude-opus-5",   { input_tokens: 1000000, output_tokens: 1000000, speed: "fast" }),
  E(ts(35), 2, "claude-opus-4-8", { input_tokens: 0,       output_tokens: 200000,  speed: "fast" }),
  E(ts(30), 3, "claude-opus-5",   { input_tokens: 2000000, output_tokens: 400000 }),
  E(ts(25), 4, "claude-fable-5",  { input_tokens: 0,       output_tokens: 100000 }),
]);

// --- B: no fast usage at all ------------------------------------------------
// claude-opus-5, speed absent:            1M in + 1M out = 5.00 + 25.00 = 30.00
// claude-opus-5, speed explicitly standard:        0.2M out =            5.00
// -> standard { cost 35.00, tokens 2.2M, messages 2 } ; fast all zero
w("claudeB", [
  E(ts(40), 1, "claude-opus-5", { input_tokens: 1000000, output_tokens: 1000000 }),
  E(ts(35), 2, "claude-opus-5", { input_tokens: 0, output_tokens: 200000, speed: "standard" }),
]);
' "$TMP"

PORT=4913
# A stray listener on this port would silently answer our curls with someone
# else's data — a wrong PASS is worse than a loud failure.
if curl -s -m 1 "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
  echo "FAIL  port $PORT already in use"; echo "---- exit 1"; exit 1
fi
run() { # $1 = fixture letter, $2 = outfile
  PULSE_HOME=$TMP/pulse$1 CLAUDE_DIR=$TMP/claude$1 CODEX_DIR=$TMP/no-codex \
  PULSE_SUMMARY_MEMO_MS=0 \
  node "$ROOT/server.js" --port $PORT --no-update-check >"$TMP/srv$1.log" 2>&1 &
  local SRV=$!
  sleep 2.5
  curl -s "http://127.0.0.1:$PORT/api/summary" > "$2"
  kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
}
run A "$TMP/a.json"
run B "$TMP/b.json"

node -e '
const T = process.argv[1];
let fail = 0;
const ok = (c, m) => { console.log((c ? "PASS" : "FAIL") + "  " + m); if (!c) fail = 1; };
const near = (a, b) => typeof a === "number" && Math.abs(a - b) < 1e-6;
const P = (f, key) => (require(T + "/" + f).periods || []).find((p) => p.key === key);

const a = P("a.json", "last30");
ok(!!a, "last30 period present");
const ss = a && a.speedSpend;
ok(!!ss && ss.fast && ss.standard, "period.speedSpend present with fast + standard blocks");
ok(ss && near(ss.fast.cost, 70), "fast cost = 60.00 (opus5) + 10.00 (opus4.8) = 70.00 (got " + (ss && ss.fast.cost) + ")");
ok(ss && ss.fast.tokens === 2200000, "fast tokens = 2.2M (got " + (ss && ss.fast.tokens) + ")");
ok(ss && ss.fast.messages === 2, "fast messages = 2 (got " + (ss && ss.fast.messages) + ")");
ok(ss && near(ss.standard.cost, 25), "standard cost = 20.00 (opus5) + 5.00 (fable5) = 25.00 (got " + (ss && ss.standard.cost) + ")");
ok(ss && ss.standard.tokens === 2500000, "standard tokens = 2.5M (got " + (ss && ss.standard.tokens) + ")");
ok(ss && ss.standard.messages === 2, "standard messages = 2 (got " + (ss && ss.standard.messages) + ")");
// fast is exactly 2x standard on both fast-capable models, so the premium is
// the standard-rate cost of those same entries: 30.00 + 5.00.
ok(ss && near(ss.fastPremium, 35), "fastPremium = 35.00 = fast cost 70.00 - standard-rate 35.00 (got " + (ss && ss.fastPremium) + ")");
ok(ss && near(ss.fastPremium, ss.fast.cost / 2), "fastPremium = half the fast spend (10/50 vs 5/25) — no non-fast model leaked in");
ok(near(ss.fast.cost + ss.standard.cost, a.cost) && near(a.cost, 95),
   "fast + standard = period cost 95.00 (got " + (ss.fast.cost + ss.standard.cost) + " vs " + a.cost + ")");
ok(ss.fast.tokens + ss.standard.tokens === a.tokens, "fast + standard tokens = period tokens");
ok(ss.fast.messages + ss.standard.messages === a.messages, "fast + standard messages = period messages");
const all = require(T + "/a.json").periods || [];
ok(all.length > 1 && all.every((p) => p.speedSpend && p.speedSpend.fast && p.speedSpend.standard
   && typeof p.speedSpend.fastPremium === "number"),
   "speedSpend on EVERY period (" + all.length + " periods)");
const cur = all.find((p) => /^\d{4}-\d{2}$/.test(p.key));
ok(cur && near(cur.speedSpend.fastPremium, 35), "current month period reports the same premium");

// ---- coverage disclosure ----------------------------------------------------
// speedSpend is LIVE-only while period.cost merges live + sealed archive, so on
// a long window the fast/standard split can describe a small slice of the
// headline spend. period.liveCost is how much of the period the live pass saw —
// the UI has to disclose it rather than imply full coverage.
ok(all.every((p) => typeof p.liveCost === "number" && isFinite(p.liveCost)),
   "liveCost is a finite number on EVERY period (" + all.length + " periods)");
ok(all.every((p) => p.liveCost <= p.cost + 1e-9), "liveCost never exceeds the period cost");
// No archive in this fixture, so the split covers the period exactly, and the
// two halves of the split add back up to it.
ok(near(a.liveCost, 95) && near(a.liveCost, a.cost),
   "A: liveCost = cost = 95.00 — the split covers the whole period (got " + a.liveCost + ")");
ok(near(ss.fast.cost + ss.standard.cost, a.liveCost),
   "A: fast + standard = liveCost, i.e. the split accounts for exactly what it saw");

const b = P("b.json", "last30").speedSpend;
ok(!!b, "no fast usage -> speedSpend still present");
ok(near(b.fast.cost, 0) && b.fast.tokens === 0 && b.fast.messages === 0,
   "no fast usage -> fast block zeroed (got " + JSON.stringify(b.fast) + ")");
ok(near(b.fastPremium, 0), "no fast usage -> fastPremium 0 (got " + b.fastPremium + ")");
ok(near(b.standard.cost, 35) && b.standard.tokens === 2200000 && b.standard.messages === 2,
   "explicit speed:standard and an absent speed both count as standard (got " + JSON.stringify(b.standard) + ")");
process.exit(fail);
' "$TMP"
RES=$?
echo "---- exit $RES"
exit $RES
