#!/bin/bash
# Plan value e2e: payload.planValue expresses API-list spend against what the
# subscription actually costs. Fixture spend is exact by construction, so the
# multiplier arithmetic is asserted, not just its type. Also covers the
# POST /api/plan/set guards (mutation-only, clears BOTH keys) and the all-time
# totals.bySource rollup.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CL=$TMP/claude; PH=$TMP/pulse; GEM=$TMP/gemini
mkdir -p "$CL/projects/demo" "$PH" "$GEM/tmp/proj/chats"

# Fixture (two sources, three calendar months, exact dollars):
#   Claude Code (cli), claude-fable-5 $10/$50 per MTok
#     today        2.0M output -> $100.00
#     4 months ago 1.0M output -> $ 50.00
#     5 months ago 0.4M output -> $ 20.00
#   Gemini CLI (gemini), gemini-3-pro $2/$12 per MTok
#     today        5.0M input  -> $ 10.00
#     4 months ago 2.5M input  -> $  5.00
# -> last30 (today only) = $110.00   all-time = $185.00
#    months: m-5 $20.00 · m-4 $55.00 · current $110.00
# The old entries sit 4+ months back so they can never drift into last30.
node -e '
const fs = require("fs");
const CL = process.argv[1], GEM = process.argv[2], OUT = process.argv[3];
const now = Date.now();
const mid = new Date(); mid.setHours(0, 0, 0, 0);
const todayTs = Math.max(now - 2 * 60e3, mid.getTime()); // safe even a minute after midnight
const mkey = (d) => d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0");
const back = (n) => new Date(mid.getFullYear(), mid.getMonth() - n, 15, 12, 0, 0);
const m4 = back(4), m5 = back(5);
const A = (ts, id, out) => ({ type: "assistant", timestamp: new Date(ts).toISOString(),
  sessionId: "s" + id, requestId: "r" + id, cwd: "/p",
  message: { id: "m" + id, model: "claude-fable-5", usage: { input_tokens: 0, output_tokens: out } } });
fs.writeFileSync(CL + "/projects/demo/s.jsonl", [
  A(todayTs, 1, 2000000),
  A(m4.getTime(), 2, 1000000),
  A(m5.getTime(), 3, 400000),
].map(JSON.stringify).join("\n") + "\n");
const G = (ts, id, inp) => ({ id: "g" + id, sessionId: "gs", timestamp: new Date(ts).toISOString(),
  model: "gemini-3-pro", tokens: { input: inp, output: 0, cached: 0, thoughts: 0, tool: 0, total: inp } });
fs.writeFileSync(GEM + "/tmp/proj/chats/session-1.jsonl", [
  G(todayTs, 1, 5000000),
  G(m4.getTime(), 2, 2500000),
].map(JSON.stringify).join("\n") + "\n");
// The in-progress month is only a FRACTION of a month of plan cost, so its
// entry has to say so. Whether the server measures elapsed time to the ms or
// to whole days, the fraction must land between (day-1)/daysInMonth and
// day/daysInMonth — local time, like every other date in the codebase.
const daysInMonth = new Date(mid.getFullYear(), mid.getMonth() + 1, 0).getDate();
fs.writeFileSync(OUT, JSON.stringify({
  cur: mkey(mid), m4: mkey(m4), m5: mkey(m5),
  spend30: 110, monthSpend: { [mkey(mid)]: 110, [mkey(m4)]: 55, [mkey(m5)]: 20 },
  totalCost: 185, bySource: { cli: 170, gemini: 15 },
  efLo: (mid.getDate() - 1) / daysInMonth, efHi: mid.getDate() / daysInMonth,
}));
' "$CL" "$GEM" "$TMP/expect.json"

PORT=4911
# A stray listener on this port would silently answer our curls with someone
# else's data — a wrong PASS is worse than a loud failure.
if curl -s -m 1 "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
  echo "FAIL  port $PORT already in use"; echo "---- exit 1"; exit 1
fi
echo '{}' > "$PH/config.json"
PULSE_HOME=$PH CLAUDE_DIR=$CL CODEX_DIR=$TMP/no-codex GEMINI_DIR=$GEM \
PULSE_SUMMARY_MEMO_MS=0 \
node "$ROOT/server.js" --port $PORT --no-update-check >"$TMP/srv.log" 2>&1 &
SRV=$!
sleep 2.5

BASE="http://127.0.0.1:$PORT"
curl -s "$BASE/api/summary" > "$TMP/default.json"
# GET on a mutation route is refused (allowMutation: POST + X-Pulse + loopback).
curl -s -o /dev/null -w '%{http_code}' "$BASE/api/plan/set?amount=500&label=Nope" > "$TMP/getcode.txt"
# POST without the X-Pulse header is refused too.
curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/plan/set?amount=500" > "$TMP/nohdrcode.txt"
curl -s "$BASE/api/summary" > "$TMP/afterrefused.json"
curl -s -X POST -H 'X-Pulse: 1' "$BASE/api/plan/set?amount=200&label=Max%2020x" > "$TMP/setresp.json"
curl -s "$BASE/api/summary" > "$TMP/afterset.json"
# A denormal (5e-324) passes isFinite && > 0 but makes spend/planCost Infinity,
# which JSON-serializes to null — the card would render "—x" next to a
# confident dollar figure and --summary would call the plan "$0.00/mo".
# Out-of-range amounts must be REFUSED outright, leaving the $200 plan intact.
curl -s -o "$TMP/denormresp.json" -w '%{http_code}' -X POST -H 'X-Pulse: 1' "$BASE/api/plan/set?amount=5e-324" > "$TMP/denormcode.txt"
cp "$PH/config.json" "$TMP/cfg-denorm.json"
curl -s "$BASE/api/summary" > "$TMP/afterdenorm.json"
curl -s -o "$TMP/bigresp.json" -w '%{http_code}' -X POST -H 'X-Pulse: 1' "$BASE/api/plan/set?amount=1e9" > "$TMP/bigcode.txt"
curl -s "$BASE/api/summary" > "$TMP/afterbig.json"
# ...but a real (if tiny) plan price inside the accepted range still works.
curl -s -X POST -H 'X-Pulse: 1' "$BASE/api/plan/set?amount=0.01" > "$TMP/smallresp.json"
curl -s "$BASE/api/summary" > "$TMP/aftersmall.json"
# Label carrying ESC[2J (clear screen) + ESC[31m (red) + DEL. --summary prints
# the label OUTSIDE the colour gate and the server echoes it to pulse.log, so
# an unsanitized label is a write primitive into the user's terminal. Restores
# the $200 plan for the source-filter and clear checks below.
curl -s -X POST -H 'X-Pulse: 1' "$BASE/api/plan/set?amount=200&label=%1B%5B2J%1B%5B31mMax%2020x%7F" > "$TMP/ansiresp.json"
cp "$PH/config.json" "$TMP/cfg-ansi.json"
curl -s "$BASE/api/summary" > "$TMP/afteransi.json"
# planValue.spend30 is ALL sources even when the dashboard is source-filtered.
curl -s "$BASE/api/summary?sources=cli" > "$TMP/filtered.json"
curl -s -X POST -H 'X-Pulse: 1' "$BASE/api/plan/set?amount=0" > "$TMP/clearresp.json"
curl -s "$BASE/api/summary" > "$TMP/afterclear.json"
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

node -e '
const fs = require("fs"); const T = process.argv[1];
let fail = 0;
const ok = (c, m) => { console.log((c ? "PASS" : "FAIL") + "  " + m); if (!c) fail = 1; };
const near = (a, b) => typeof a === "number" && Math.abs(a - b) < 0.005;
const X = require(T + "/expect.json");
const J = (f) => require(T + "/" + f);

// ---- unconfigured ----
const d = J("default.json"), pv = d.planValue;
ok(!!pv && typeof pv === "object", "payload.planValue present with no config");
ok(pv && pv.configured === false, "unconfigured -> configured false (got " + (pv && pv.configured) + ")");
ok(pv && pv.cost === null && pv.label === null, "unconfigured -> cost/label null");
ok(pv && pv.multiplier === null, "unconfigured -> multiplier null (got " + (pv && pv.multiplier) + ")");
ok(pv && near(pv.spend30, X.spend30), "spend30 = last30 cost $" + X.spend30 + " even unconfigured (got " + (pv && pv.spend30) + ")");
const l30 = (d.periods || []).find((p) => p.key === "last30");
ok(l30 && near(pv.spend30, l30.cost), "spend30 matches the last30 period cost exactly");

// ---- months: oldest first, and each one equals its month period ----
const byKey = {}; for (const p of d.periods || []) byKey[p.key] = p;
const mos = (pv && pv.months) || [];
ok(mos.length === 3, "3 calendar months in the fixture -> 3 month rows (got " + mos.length + ")");
ok(mos.length === 3 && mos[0].key === X.m5 && mos[1].key === X.m4 && mos[2].key === X.cur,
   "months are OLDEST FIRST (" + mos.map((m) => m.key).join(",") + " vs " + [X.m5, X.m4, X.cur].join(",") + ")");
ok(mos.every((m) => near(m.spend, X.monthSpend[m.key])),
   "month spends = " + JSON.stringify(X.monthSpend) + " (got " + JSON.stringify(mos.map((m) => [m.key, m.spend])) + ")");
ok(mos.every((m) => byKey[m.key] && near(m.spend, byKey[m.key].cost)),
   "each month row matches its own payload.periods entry");
ok(mos.every((m) => m.multiplier == null), "unconfigured -> per-month multiplier null");
ok(mos.length <= 6, "months capped at 6");

// ---- partial current month ----
// The newest bar divides a PARTIAL month of spend by a FULL month of plan
// cost, so on the 3rd of the month it reads as "the plan is not paying for
// itself" no matter how heavy usage is. The datum that lets the UI say "so
// far" instead has to be in the payload, on the current month only.
const curMo = mos[mos.length - 1];
ok(curMo && curMo.key === X.cur && curMo.partial === true,
   "current month is flagged partial:true (got " + JSON.stringify(curMo && curMo.partial) + ")");
ok(curMo && typeof curMo.elapsedFraction === "number" && curMo.elapsedFraction > 0 && curMo.elapsedFraction <= 1,
   "elapsedFraction is a number in (0,1] (got " + (curMo && curMo.elapsedFraction) + ")");
ok(curMo && curMo.elapsedFraction >= X.efLo - 1e-9 && curMo.elapsedFraction <= X.efHi + 1e-9,
   "elapsedFraction = elapsed/days-in-month, i.e. between " + X.efLo.toFixed(4) + " and " + X.efHi.toFixed(4) +
   " (got " + (curMo && curMo.elapsedFraction) + ")");
const done = mos.slice(0, -1);
ok(done.length === 2 && done.every((m) => m.partial !== true),
   "completed months are NOT flagged partial (" + JSON.stringify(done.map((m) => [m.key, m.partial])) + ")");
ok(done.every((m) => m.elapsedFraction == null),
   "completed months carry no elapsedFraction — a full month needs no fraction");

// ---- guards ----
ok(fs.readFileSync(T + "/getcode.txt", "utf8").trim() === "403", "GET /api/plan/set -> 403 (got " + fs.readFileSync(T + "/getcode.txt", "utf8").trim() + ")");
ok(fs.readFileSync(T + "/nohdrcode.txt", "utf8").trim() === "403", "POST without X-Pulse -> 403");
ok(J("afterrefused.json").planValue.configured === false, "refused calls did not write config");

// ---- set ----
const sr = J("setresp.json");
ok(sr.ok === true && sr.planValue && sr.planValue.configured === true && sr.planValue.cost === 200,
   "POST set -> {ok:true, planValue:{configured,cost:200}}");
const a = J("afterset.json").planValue;
ok(a.configured === true && a.cost === 200, "after set: configured, cost 200");
ok(a.label === "Max 20x", "label round-trips url-decoded (got " + JSON.stringify(a.label) + ")");
// $110 of list-price usage on a $200 plan -> 0.55x
ok(near(a.multiplier, X.spend30 / 200), "multiplier = spend30/planCost = " + (X.spend30 / 200) + " (got " + a.multiplier + ")");
ok((a.months || []).every((m) => near(m.multiplier, X.monthSpend[m.key] / 200)),
   "per-month multiplier = that month spend / planCost");
ok((a.months || []).some((m) => m.key === X.cur && m.partial === true),
   "configured too: the current month keeps its partial flag");

// ---- out-of-range plan prices are refused, never stored ----
const safeJson = (f) => { try { return JSON.parse(fs.readFileSync(T + "/" + f, "utf8")); } catch (_) { return null; } };
const noBadPlan = (resp, what) => {
  const p = resp && resp.planValue;
  // The exact failure mode: a plan that claims to be configured while its
  // multiplier is null/non-finite — a dollar figure with a "—x" beside it.
  ok(!p || !(p.configured === true && (p.multiplier == null || !isFinite(p.multiplier))),
     what + ": never answers with a configured plan whose multiplier is null (got " +
     JSON.stringify(p && { configured: p.configured, cost: p.cost, multiplier: p.multiplier }) + ")");
};
noBadPlan(safeJson("denormresp.json"), "amount=5e-324");
noBadPlan(safeJson("bigresp.json"), "amount=1e9");
// Refused loudly, not accepted-then-ignored: the dashboard has to be able to
// tell the user the price did not take.
const dcode = fs.readFileSync(T + "/denormcode.txt", "utf8").trim();
const bcode = fs.readFileSync(T + "/bigcode.txt", "utf8").trim();
ok(/^4\d\d$/.test(dcode), "amount=5e-324 -> 4xx (got " + dcode + ")");
ok(/^4\d\d$/.test(bcode), "amount=1e9 -> 4xx (got " + bcode + ")");
ok((safeJson("denormresp.json") || {}).ok !== true && (safeJson("bigresp.json") || {}).ok !== true,
   "a refused amount never answers ok:true");
const cfgDen = safeJson("cfg-denorm.json") || {};
ok(cfgDen.planCost === 200, "amount=5e-324 (denormal, > 0 and finite) left config.planCost at 200 (got " + cfgDen.planCost + ")");
const ad = J("afterdenorm.json").planValue;
ok(ad.configured === true && ad.cost === 200 && near(ad.multiplier, X.spend30 / 200),
   "after the denormal: still the $200 plan at " + (X.spend30 / 200) + "x (got cost " + ad.cost + ", multiplier " + ad.multiplier + ")");
const ab = J("afterbig.json").planValue;
ok(ab.cost === 200 && near(ab.multiplier, X.spend30 / 200), "amount=1e9 is out of range too — plan unchanged (got " + ab.cost + ")");
// 0.01 is the low end of the accepted range: it must still be a real plan.
// $110 of usage against a 1-cent plan = 11000x — large, but finite and true.
const as = J("aftersmall.json").planValue;
ok(as.configured === true && as.cost === 0.01, "amount=0.01 is accepted (got cost " + as.cost + ")");
ok(typeof as.multiplier === "number" && isFinite(as.multiplier) && near(as.multiplier, X.spend30 / 0.01),
   "multiplier = 110/0.01 = 11000, finite (got " + as.multiplier + ")");

// ---- a label can never carry control characters ----
// Sent: ESC [ 2 J ESC [ 3 1 m M a x _ 2 0 x DEL. Stripping /[\x00-\x1f\x7f-\x9f]/g
// leaves the printable remainder "[2J[31mMax 20x" — the payload keeps what the
// user typed minus anything that can drive a terminal.
const CTRL = /[\x00-\x1f\x7f-\x9f]/;
const an = J("afteransi.json").planValue;
ok(typeof an.label === "string" && !CTRL.test(an.label),
   "payload label has NO control characters (got " + JSON.stringify(an.label) + ")");
ok(an.label === "[2J[31mMax 20x",
   "control bytes stripped, printable text kept (got " + JSON.stringify(an.label) + ")");
const cfgAnsi = safeJson("cfg-ansi.json") || {};
ok(typeof cfgAnsi.planLabel === "string" && !CTRL.test(cfgAnsi.planLabel),
   "STORED config.planLabel has no control characters (got " + JSON.stringify(cfgAnsi.planLabel) + ")");
ok(cfgAnsi.planCost === 200, "the ANSI-label set still stored its amount (got " + cfgAnsi.planCost + ")");
// The route echoes the label to stdout, which the Windows daemon tees into
// ~/.pulse/pulse.log — a replayed ESC fires again every time that log is read.
const srvLog = fs.readFileSync(T + "/srv.log", "utf8");
const planLines = srvLog.split("\n").filter((l) => /\[pulse\] plan /.test(l));
ok(planLines.length > 0, "server logged the plan changes (" + planLines.length + " lines)");
ok(planLines.every((l) => !CTRL.test(l.replace(/\r$/, ""))),
   "no control characters echoed to the server log (" + JSON.stringify(planLines.find((l) => CTRL.test(l.replace(/\r$/, "")))) + ")");

// ---- source filter must NOT scope the plan comparison ----
const f = J("filtered.json");
const f30 = (f.periods || []).find((p) => p.key === "last30");
ok(f30 && near(f30.cost, 100), "?sources=cli scopes the periods (last30 = $100 cli-only)");
ok(near(f.planValue.spend30, X.spend30) && near(f.planValue.multiplier, X.spend30 / 200),
   "planValue.spend30 stays ALL sources under a filter (got " + f.planValue.spend30 + ")");

// ---- clear ----
const c = J("afterclear.json").planValue;
ok(c.configured === false && c.cost === null && c.label === null, "amount=0 clears BOTH planCost and planLabel");
ok(c.multiplier === null, "cleared -> multiplier null");
ok(near(c.spend30, X.spend30), "cleared -> spend30 still reported");
const cfgRaw = fs.readFileSync(T + "/pulse/config.json", "utf8");
const cfg = JSON.parse(cfgRaw || "{}");
ok(!cfg.planCost && !cfg.planLabel, "config.json holds no live planCost/planLabel after the clear (got " + cfgRaw.trim() + ")");

// ---- totals.bySource (all-time, live + archive) ----
const t = d.totals;
ok(t && t.bySource && typeof t.bySource === "object", "totals.bySource present");
const bs = (t && t.bySource) || {};
ok(Object.keys(bs).sort().join(",") === "cli,gemini", "totals.bySource keys = cli,gemini (got " + Object.keys(bs).join(",") + ")");
ok(near(bs.cli && bs.cli.cost, X.bySource.cli), "totals.bySource.cli = $" + X.bySource.cli + " all-time (got " + (bs.cli && bs.cli.cost) + ")");
ok(near(bs.gemini && bs.gemini.cost, X.bySource.gemini), "totals.bySource.gemini = $" + X.bySource.gemini + " (got " + (bs.gemini && bs.gemini.cost) + ")");
const sum = Object.values(bs).reduce((s, v) => s + v.cost, 0);
ok(near(sum, t.cost) && near(t.cost, X.totalCost), "per-source costs sum to totals.cost ($" + X.totalCost + ", got " + sum + " vs " + t.cost + ")");
const tokSum = Object.values(bs).reduce((s, v) => s + v.tokens, 0);
const msgSum = Object.values(bs).reduce((s, v) => s + v.messages, 0);
ok(tokSum === t.tokens, "per-source tokens sum to totals.tokens (" + tokSum + " vs " + t.tokens + ")");
ok(msgSum === t.messages && t.messages === 5, "per-source messages sum to totals.messages (5 entries)");
process.exit(fail);
' "$TMP"
RES=$?
echo "---- exit $RES"
exit $RES
