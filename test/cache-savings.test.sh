#!/bin/bash
# Cache savings e2e: every spend period carries what prompt caching actually
# bought — the discount on cache READS minus the premium paid on cache WRITES.
# The fixture token counts are chosen so saved / writePremium / net are exact
# decimal dollars, and it spans three models (incl. one fast-mode entry) so a
# single hard-coded global rate cannot pass.
#
# Cache multipliers (server.js §5), applied to the model's INPUT price:
#   read 0.10x · 5m write 1.25x · 1h write 2.00x
# so per MTok:  saved = in x 0.90 · 5m premium = in x 0.25 · 1h premium = in x 1.00
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/claudeA/projects/demo" "$TMP/pulseA" \
         "$TMP/claudeB/projects/demo" "$TMP/pulseB" \
         "$TMP/claudeC/projects/demo" "$TMP/pulseC" \
         "$TMP/claudeD/projects/demo" "$TMP/pulseD" "$TMP/clineD/tasks/task-d1"

# All entries are TODAY: cacheSavings is derived per-entry, and the sealed
# history archive keeps no per-entry cache detail (LIVE-only, same convention
# as effortSpend/byProject).
node -e '
const fs = require("fs");
const T = process.argv[1];
const now = Date.now();
const mid = new Date(); mid.setHours(0, 0, 0, 0);
const tsn = (n) => Math.max(now - n * 60e3, mid.getTime());
const ts = (n) => new Date(tsn(n)).toISOString();
const E = (t, id, model, usage) => ({ type: "assistant", timestamp: t, sessionId: "s1", requestId: "r" + id,
  cwd: "/p", message: { id: "m" + id, model, usage } });
const w = (dir, lines) => fs.writeFileSync(T + "/" + dir + "/projects/demo/s.jsonl", lines.map(JSON.stringify).join("\n") + "\n");

// --- A: positive net, three price points -----------------------------------
// claude-opus-4-8 (in $5): read 10M, write 4M @5m + 2M @1h
//   saved       = 10 * 5 * 0.90 = 45.00
//   writePremium= 4 * 5 * 0.25 + 2 * 5 * 1.00 = 5.00 + 10.00 = 15.00
// claude-haiku-4-5 (in $1): read 20M -> saved = 20 * 1 * 0.90 = 18.00
// claude-opus-5 SPEED=fast (in $10, not $5): read 1M -> saved = 1 * 10 * 0.90 = 9.00
//   (a speed-blind lookup would give 4.50 and miss by 4.50)
// totals: readTokens 31M · saved 72.00 · writePremium 15.00 · net 57.00
// period cost = 5.00 + 25.00 + 20.00 + 2.00 + 1.00 = 53.00
w("claudeA", [
  E(ts(30), 1, "claude-opus-4-8", { input_tokens: 0, output_tokens: 0,
    cache_read_input_tokens: 10000000,
    cache_creation: { ephemeral_5m_input_tokens: 4000000, ephemeral_1h_input_tokens: 2000000 } }),
  E(ts(25), 2, "claude-haiku-4-5", { input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 20000000 }),
  E(ts(20), 3, "claude-opus-5", { input_tokens: 0, output_tokens: 0, speed: "fast", cache_read_input_tokens: 1000000 }),
]);

// --- B: NEGATIVE net (writes never read back) -------------------------------
// claude-opus-4-8 (in $5): read 0.1M, write 10M @1h
//   saved        = 0.1 * 5 * 0.90 =  0.45
//   writePremium = 10  * 5 * 1.00 = 50.00
//   net = 0.45 - 50.00 = -49.55  <- must NOT be clamped to 0
w("claudeB", [
  E(ts(30), 1, "claude-opus-4-8", { input_tokens: 0, output_tokens: 0,
    cache_read_input_tokens: 100000,
    cache_creation: { ephemeral_5m_input_tokens: 0, ephemeral_1h_input_tokens: 10000000 } }),
]);

// --- C: no cache tokens at all -> all four fields zero ----------------------
w("claudeC", [
  E(ts(30), 1, "claude-opus-4-8", { input_tokens: 1000000, output_tokens: 200000 }),
]);

// --- D: entries that must contribute NOTHING to the savings aggregate -------
// One real Claude entry supplies the whole expected figure; everything else in
// this fixture has cache traffic that is worth exactly $0 and must not be able
// to move `saved`, `writePremium` or `readTokens`.
//
// claude-opus-4-8 (in $5) — the ONLY genuine contributor:
//   read 2M, write 1M @5m
//   saved        = 2 * 5 * 0.90 =  9.00
//   writePremium = 1 * 5 * 0.25 =  1.25   -> net 7.75
//   entry cost   = 2 * 5 * 0.10 + 1 * 5 * 1.25 = 1.00 + 6.25 = 7.25
//
// <synthetic> (in $0) read 3M and glm-4.7-flash (a FREE Z.ai row, in $0)
// read 4M + write 1M: reads on a $0 input price save $0, so counting their
// 7M tokens in the denominator would advertise "saved $9.00 off 9M cached
// reads" — a rate that is off by 4.5x. readTokens tracks only tokens that
// actually bought a discount.
w("claudeD", [
  E(ts(30), 1, "claude-opus-4-8", { input_tokens: 0, output_tokens: 0,
    cache_read_input_tokens: 2000000,
    cache_creation: { ephemeral_5m_input_tokens: 1000000, ephemeral_1h_input_tokens: 0 } }),
  E(ts(28), 2, "<synthetic>", { input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 3000000 }),
  E(ts(26), 3, "glm-4.7-flash", { input_tokens: 0, output_tokens: 0,
    cache_read_input_tokens: 4000000,
    cache_creation: { ephemeral_5m_input_tokens: 1000000, ephemeral_1h_input_tokens: 0 } }),
]);
// Cline task: the agent recorded its OWN cost ($0.37) and there is no
// task_metadata.json, so the model resolves to the coarse "unknown" label and
// would re-price at the __default__ $3/$15 row. Re-pricing a cost we did not
// compute invents savings unrelated to the dollars on screen: 0.5M reads x $3
// x 0.90 = $1.35 "saved" and 0.2M writes x $3 x 0.25 = $0.15 premium on an
// entry whose entire cost was $0.37. Both must be ZERO — but the $0.37 itself
// still counts toward the period.
fs.writeFileSync(T + "/clineD/tasks/task-d1/ui_messages.json", JSON.stringify([
  { type: "say", say: "api_req_started", ts: tsn(24),
    text: JSON.stringify({ tokensIn: 10000, tokensOut: 5000, cacheWrites: 200000, cacheReads: 500000, cost: 0.37 }) },
]));
' "$TMP"

PORT=4912
# A stray listener on this port would silently answer our curls with someone
# else's data — a wrong PASS is worse than a loud failure.
if curl -s -m 1 "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
  echo "FAIL  port $PORT already in use"; echo "---- exit 1"; exit 1
fi
run() { # $1 = fixture letter, $2 = outfile
  # CLINE_DIR always points at this fixture's own tree — it exists only for D;
  # a missing dir simply yields no Cline tasks (same as CODEX_DIR above).
  PULSE_HOME=$TMP/pulse$1 CLAUDE_DIR=$TMP/claude$1 CODEX_DIR=$TMP/no-codex \
  CLINE_DIR=$TMP/cline$1 \
  PULSE_SUMMARY_MEMO_MS=0 \
  node "$ROOT/server.js" --port $PORT --no-update-check >"$TMP/srv$1.log" 2>&1 &
  local SRV=$!
  sleep 2.5
  curl -s "http://127.0.0.1:$PORT/api/summary" > "$2"
  kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
}
run A "$TMP/a.json"
run B "$TMP/b.json"
run C "$TMP/c.json"
run D "$TMP/d.json"

node -e '
const T = process.argv[1];
let fail = 0;
const ok = (c, m) => { console.log((c ? "PASS" : "FAIL") + "  " + m); if (!c) fail = 1; };
// exact decimal dollars by construction; epsilon only covers float rounding
const near = (a, b) => typeof a === "number" && Math.abs(a - b) < 1e-6;
const P = (f, key) => (require(T + "/" + f).periods || []).find((p) => p.key === key);

const a = P("a.json", "last30");
ok(!!a, "last30 period present");
const cs = a && a.cacheSavings;
ok(!!cs && typeof cs === "object", "period.cacheSavings present");
ok(cs && cs.readTokens === 31000000, "readTokens = 31M (got " + (cs && cs.readTokens) + ")");
ok(cs && near(cs.saved, 72), "saved = 45.00 (opus4.8) + 18.00 (haiku) + 9.00 (opus5 FAST rate) = 72.00 (got " + (cs && cs.saved) + ")");
ok(cs && near(cs.writePremium, 15), "writePremium = 5.00 (5m x0.25) + 10.00 (1h x1.00) = 15.00 (got " + (cs && cs.writePremium) + ")");
ok(cs && near(cs.net, 57), "net = 72.00 - 15.00 = 57.00 (got " + (cs && cs.net) + ")");
ok(cs && near(cs.net, cs.saved - cs.writePremium), "net is exactly saved - writePremium");
ok(near(a.cost, 53), "sanity: period cost = 53.00, so the savings are measured against the same prices (got " + a.cost + ")");
// every period, not just last30
const all = require(T + "/a.json").periods || [];
ok(all.length > 1 && all.every((p) => p.cacheSavings && ["readTokens", "saved", "writePremium", "net"]
   .every((k) => typeof p.cacheSavings[k] === "number")),
   "cacheSavings on EVERY period (" + all.length + " periods)");
const cur = all.find((p) => /^\d{4}-\d{2}$/.test(p.key));
ok(cur && cur.cacheSavings && near(cur.cacheSavings.net, 57), "current month period reports the same net (got " + (cur && cur.cacheSavings && cur.cacheSavings.net) + ")");

// ---- coverage disclosure (F1) ----------------------------------------------
// cacheSavings/speedSpend are accumulated from LIVE entries only, while
// period.cost merges live + sealed archive. period.liveCost is the amount of
// the period the live pass actually saw, and it is what the UI must disclose
// next to the savings figure ("covers $X of the $Y this period"). If it goes
// missing the number silently reverts to being presented as full coverage.
ok(all.every((p) => typeof p.liveCost === "number" && isFinite(p.liveCost)),
   "liveCost is a finite number on EVERY period (" + all.length + " periods)");
ok(all.every((p) => p.liveCost <= p.cost + 1e-9),
   "liveCost never exceeds the period cost it discloses coverage of");
// Fixture A has no archive, so the live pass covers the period exactly.
ok(near(a.liveCost, 53) && near(a.liveCost, a.cost),
   "A: all spend is live -> liveCost = cost = 53.00 (got " + a.liveCost + ")");

const b = P("b.json", "last30").cacheSavings;
ok(near(b.saved, 0.45), "B: saved = 0.1M x $5 x 0.90 = 0.45 (got " + b.saved + ")");
ok(near(b.writePremium, 50), "B: writePremium = 10M x $5 x 1.00 = 50.00 (got " + b.writePremium + ")");
ok(near(b.net, -49.55), "B: net = -49.55 — write-heavy caching is a LOSS (got " + b.net + ")");
ok(b.net < 0, "B: negative net is not clamped to 0");

const c = P("c.json", "last30").cacheSavings;
ok(c && c.readTokens === 0 && near(c.saved, 0) && near(c.writePremium, 0) && near(c.net, 0),
   "C: no cache tokens -> all four fields 0 (got " + JSON.stringify(c) + ")");

// ---- D: only cache traffic that actually bought something may count --------
const dp = P("d.json", "last30");
const d = dp && dp.cacheSavings;
ok(!!d, "D: last30 cacheSavings present");
// Every figure below is the opus-4-8 entry ALONE. The Cline entry (own recorded
// cost, unresolvable model), the <synthetic> entry and the free glm-4.7-flash
// entry each carry cache traffic and must add exactly nothing.
ok(d && near(d.saved, 9), "D: saved = 2M x $5 x 0.90 = 9.00 — the opus entry alone (got " + (d && d.saved) + ")");
ok(d && near(d.writePremium, 1.25), "D: writePremium = 1M x $5 x 0.25 = 1.25 (got " + (d && d.writePremium) + ")");
ok(d && near(d.net, 7.75), "D: net = 9.00 - 1.25 = 7.75 (got " + (d && d.net) + ")");
// F5: re-pricing the Cline 0.5M reads at the __default__ $3 row would have added
// 1.35 to saved, 0.15 to writePremium and 500k to readTokens.
ok(d && !near(d.saved, 10.35) && !near(d.writePremium, 1.4),
   "D (F5): a source-costed Cline entry invents no savings (saved is not 9.00+1.35)");
// F6: <synthetic> (3M) + glm-4.7-flash (4M) price input at $0 — their reads
// saved $0, so they may not pad the denominator (2M, not 9M or 9.5M).
ok(d && d.readTokens === 2000000,
   "D (F6): readTokens = 2M — $0-priced models and the Cline entry excluded (got " + (d && d.readTokens) + ")");
// The exclusions are about cache ECONOMICS only: the dollars still count.
// 7.25 (opus) + 0.00 (<synthetic>) + 0.00 (glm flash) + 0.37 (Cline, its own
// recorded cost) = 7.62.
ok(near(dp.cost, 7.62), "D: period cost still 7.62 — zeroing the economics dropped no spend (got " + dp.cost + ")");
ok(near(dp.liveCost, 7.62), "D: liveCost = 7.62, the whole period is live (got " + dp.liveCost + ")");
process.exit(fail);
' "$TMP"
RES=$?
echo "---- exit $RES"
exit $RES
