#!/bin/bash
# Meshy (3D-asset generation) e2e.
#
# Meshy has no local log, so unlike every other source this is an OPT-IN
# AUTHENTICATED integration — modelled on the Claude account meters / Codex
# account tokens, not on the transcript parsers. It is also the first
# credential Pulse *stores* rather than reads, so most of this suite exists to
# prove the key stays put:
#
#   - nothing is fetched at all without `meshy: true` AND a key;
#   - the key never reaches the payload (any depth), the server log, the
#     persisted task store, or a URL/query string — only the Authorization
#     header of the Meshy host;
#   - credits are their own unit: turning Meshy on must not move a single
#     dollar figure.
#
# Plus the mechanics: exact credit bucketing, defensive family probing,
# incremental paging, 401 (bad key, stop retrying) and 429 (keep last good).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
MOCK=
SRV=
trap 'kill $SRV $MOCK 2>/dev/null; rm -rf "$TMP"' EXIT

# Obviously-fake key. Distinctive so it can be grepped for anywhere it must not
# appear; the mock demands this exact string in the Authorization header.
KEY='msy-fake-key-DO-NOT-LOG-0123456789'
MPORT=4879
API="http://127.0.0.1:$MPORT"
PORT=4915

CL=$TMP/claude
mkdir -p "$CL/projects/demo"
# One Claude entry so the dollar figures are non-zero — the point of the
# cost-isolation check is that they are IDENTICAL with Meshy off and on.
node -e '
const fs = require("fs");
fs.writeFileSync(process.argv[1] + "/projects/demo/s.jsonl", JSON.stringify({
  type: "assistant", timestamp: new Date().toISOString(), sessionId: "s", requestId: "r", cwd: "/p",
  message: { id: "m", model: "claude-fable-5", usage: { input_tokens: 1000, output_tokens: 10000 } } }) + "\n");
' "$CL"

# ---------------------------------------------------------------------------
# Fixture A — the arithmetic fixture (small, one page).
# ---------------------------------------------------------------------------
cat > "$TMP/gen-a.js" <<'GENA'
// Every task sits at LOCAL NOON of a chosen day offset (today's at "a minute
// ago", clamped to after local midnight) so day bucketing is provable and
// cannot race a midnight rollover. Offsets are walked with setDate(), not ms
// arithmetic, so a DST day is still exactly one day.
//
// Named tasks — credits @ day offset:
//   t1  5 @ 0   text_to_3d_preview
//   t2 10 @ 0   text_to_3d_refine     -> today = 5 + 10                = 15
//   t3 20 @ 1   text_to_3d_preview
//   t4  7 @ 3   text_to_3d_refine
//   t5  3 @ 6   text_to_3d_preview    -> week  = 15 + 20 + 7 + 3       = 45
//   t6 100 @ N  text_to_3d_preview    -> month = 45 + 100              = 145
//        where N = min(20, dayOfMonth - 1), included only when N >= 8.
//        (Run on the 1st-8th of a month there is no day that is both >6 days
//        back and still inside this calendar month, so t6 is dropped and
//        month = week = 45.)
//
// byType: preview = 5 + 20 + 3 + 100 = 128 over 4 tasks
//         refine  = 10 + 7           =  17 over 2 tasks   (sum 145 = allTime)
//
// EVERY task is inside BOTH the current calendar month AND the last 30 days,
// on purpose: `month` is then the same number under either reading of the
// word, so this suite can never fail over a definition it does not own. The
// consequence — allTime == month — is deliberate, not an oversight.
const fs = require('fs');
const out = process.argv[2];
const now = new Date();
const startOfToday = new Date(now); startOfToday.setHours(0, 0, 0, 0);
const noonBack = (off) => { const d = new Date(now); d.setHours(12, 0, 0, 0); d.setDate(d.getDate() - off); return d.getTime(); };
const p2 = (n) => String(n).padStart(2, '0');
const ymd = (ms) => { const d = new Date(ms); return d.getFullYear() + '-' + p2(d.getMonth() + 1) + '-' + p2(d.getDate()); };
const todayTs = Math.max(startOfToday.getTime() + 1000, now.getTime() - 60e3);

const tasks = [];
const add = (id, type, credits, ts) => tasks.push({
  id, type, status: 'SUCCEEDED', prompt: 'fixture ' + id, mode: type.indexOf('refine') >= 0 ? 'refine' : 'preview',
  created_at: ts, started_at: ts + 1000, finished_at: ts + 5000, // epoch MILLISECONDS, as the API sends
  consumed_credits: credits,
});
add('t1', 'text_to_3d_preview', 5, todayTs);
add('t2', 'text_to_3d_refine', 10, todayTs);
add('t3', 'text_to_3d_preview', 20, noonBack(1));
add('t4', 'text_to_3d_refine', 7, noonBack(3));
add('t5', 'text_to_3d_preview', 3, noonBack(6));
const oldOff = Math.min(20, now.getDate() - 1);
if (oldOff >= 8) add('t6', 'text_to_3d_preview', 100, noonBack(oldOff));

// Recompute the expectations from the fixture itself, then check them against
// the hand arithmetic in the comment above — so the comment can never drift.
const dayIndex = (ts) => Math.round((startOfToday.getTime() - new Date(ts).setHours(0, 0, 0, 0)) / 86400e3);
const sum = (f) => tasks.filter(f).reduce((a, t) => a + t.consumed_credits, 0);
const today = sum((t) => dayIndex(t.created_at) === 0);
const week = sum((t) => dayIndex(t.created_at) <= 6);
const month = sum((t) => { const d = new Date(t.created_at); return d.getMonth() === now.getMonth() && d.getFullYear() === now.getFullYear(); });
const allTime = sum(() => true);
const expMonth = oldOff >= 8 ? 145 : 45;
if (today !== 15 || week !== 45 || month !== expMonth || allTime !== month) {
  throw new Error('fixture arithmetic drifted from the comment: ' + JSON.stringify({ today, week, month, allTime }));
}

const byType = {};
for (const t of tasks) {
  const b = byType[t.type] || (byType[t.type] = { credits: 0, tasks: 0 });
  b.credits += t.consumed_credits; b.tasks++;
}
const byDate = {};
for (const t of tasks) {
  const k = ymd(t.created_at);
  const b = byDate[k] || (byDate[k] = { credits: 0, tasks: 0 });
  b.credits += t.consumed_credits; b.tasks++;
}

fs.writeFileSync(out + '/expected.json', JSON.stringify({
  today, week, month, allTime, byType, byDate,
  taskCount: tasks.length,
  ids: tasks.map((t) => t.id),
  todayDate: ymd(startOfToday.getTime()),
  oldestAllowed: ymd(noonBack(29)), // nothing in `daily` may predate this
}, null, 2));

// Newest first, as `sort_by=-created_at` promises, with non-object junk mixed
// in: a list endpoint that hands back a null or a bare string must be survived,
// not crashed on. Junk carries no type/credits, so it cannot perturb any total.
tasks.sort((a, b) => b.created_at - a.created_at);
const list = tasks.slice(0, 2).concat([null], tasks.slice(2), ['garbage', 42]);
fs.writeFileSync(out + '/fixtureA.json', JSON.stringify(list, null, 2));
GENA

# ---------------------------------------------------------------------------
# Fixture B — the paging fixture (used ONLY for request-count assertions).
# 130 tasks inside the 30-day window, then 100 far outside it. At page_size 50
# that is 5 pages, and the 30-day boundary falls inside page 3 — so a server
# that honours "stop once you pass 30 days" (or its own page cap) must never
# ask for page 5.
# ---------------------------------------------------------------------------
cat > "$TMP/gen-b.js" <<'GENB'
const fs = require('fs');
const out = process.argv[2];
const now = new Date();
const startOfToday = new Date(now); startOfToday.setHours(0, 0, 0, 0);
const noonBack = (off) => { const d = new Date(now); d.setHours(12, 0, 0, 0); d.setDate(d.getDate() - off); return d.getTime(); };
const todayTs = Math.max(startOfToday.getTime() + 1000, now.getTime() - 60e3);
const list = [];
for (let i = 0; i < 130; i++) {                  // inside the window
  const off = Math.floor((i * 29) / 129);
  const ts = (off === 0 ? todayTs : noonBack(off)) - i * 1000; // strictly newest-first
  list.push({ id: 'recent-' + i, type: 'bulk', status: 'SUCCEEDED', created_at: ts, finished_at: ts + 1000, consumed_credits: 2 });
}
for (let j = 0; j < 100; j++) {                  // 40-139 days old: must not be walked
  const ts = noonBack(40 + j);
  list.push({ id: 'ancient-' + j, type: 'ancient', status: 'SUCCEEDED', created_at: ts, finished_at: ts + 1000, consumed_credits: 1000 });
}
fs.writeFileSync(out + '/fixtureB.json', JSON.stringify(list));
GENB

node "$TMP/gen-a.js" "$TMP" || { echo "FAIL  fixture A generation"; exit 1; }
node "$TMP/gen-b.js" "$TMP" || { echo "FAIL  fixture B generation"; exit 1; }
cp "$TMP/fixtureA.json" "$TMP/fixture.json"

# A mock left listening on this port by an earlier run would answer every list
# request with an empty array — indistinguishable, from the payload, from a
# server that cannot parse the response. Refuse to start rather than report a
# phantom bug. (Back-to-back runs get a few seconds of grace: a killed process
# can hold its socket briefly after the shell has reaped it.)
for i in $(seq 1 20); do curl -sf -m 2 "$API/__stats" >/dev/null 2>&1 || break; sleep 0.5; done
if curl -sf -m 2 "$API/__stats" >/dev/null 2>&1; then
  echo "FAIL  port $MPORT is already in use (stale mock?) — refusing to run"
  echo "---- exit 1"; exit 1
fi
MESHY_PORT=$MPORT MESHY_KEY="$KEY" MESHY_FIXTURE="$TMP/fixture.json" MESHY_BALANCE=987.5 \
node "$ROOT/test/mocks/mock-meshy.js" >"$TMP/mock.log" 2>&1 &
MOCK=$!
for i in $(seq 1 20); do curl -sf "$API/__stats" >/dev/null 2>&1 && break; sleep 0.2; done
# Prove the mock on the wire is ours and can actually read the fixture, before
# any assertion depends on it.
curl -s -H "Authorization: Bearer $KEY" "$API/openapi/v2/text-to-3d?page_num=1&page_size=50" > "$TMP/mock-hello.json"
node -e '
const fs = require("fs");
const got = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const want = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (!Array.isArray(got) || got.length !== want.length) {
  console.log("FAIL  mock preflight: served " + (Array.isArray(got) ? got.length : "non-array") +
              " records, fixture has " + want.length + " — wrong mock on the port, or it cannot read its fixture");
  process.exit(1);
}
' "$TMP/mock-hello.json" "$TMP/fixture.json" || { echo "---- exit 1"; exit 1; }

start_pulse() { # $1 = PULSE_HOME, $2 = meshy cache ms
  # Wait for the previous phase's socket to actually close. Otherwise the new
  # server loses the bind and the health probe cheerfully answers from the OLD
  # process — with the OLD ~/.pulse — which would silently invalidate a phase.
  for i in $(seq 1 20); do curl -sf -m 2 "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 || break; sleep 0.5; done
  PULSE_HOME=$1 CLAUDE_DIR=$CL CODEX_DIR=$TMP/nocodex \
  PULSE_MESHY_API=$API PULSE_MESHY_CACHE_MS=$2 PULSE_SUMMARY_MEMO_MS=0 \
  PULSE_NO_TRAY_SPAWN=1 PULSE_NO_OPENUSAGE_SPAWN=1 PULSE_NO_STRIP_SPAWN=1 \
  PULSE_STARTUP_STUB=$TMP/startup.json \
  node "$ROOT/server.js" --port $PORT --no-update-check >>"$TMP/srv.log" 2>&1 &
  SRV=$!
  for i in $(seq 1 60); do curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && return 0; sleep 0.25; done
  return 1
}
stop_pulse() { kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; SRV=; }

# Poll /api/summary until payload.meshy.status settles (optionally on a wanted
# value). Always leaves the last payload in $1, so a timeout still asserts.
poll_meshy() { # $1 = out file, $2 = wanted status ("" = anything but loading)
  for i in $(seq 1 24); do
    curl -s "http://127.0.0.1:$PORT/api/summary" > "$1"
    ST=$(node -e 'const fs=require("fs");let s={};try{s=JSON.parse(fs.readFileSync(process.argv[1],"utf8"))}catch(e){}console.log((s.meshy&&s.meshy.status)||"")' "$1")
    if [ -n "$2" ]; then
      [ "$ST" = "$2" ] && return 0
    else
      if [ -n "$ST" ] && [ "$ST" != "loading" ]; then return 0; fi
    fi
    sleep 0.5
  done
  return 1
}

# === PHASE 1 — the consent gate ============================================
# A key present but `meshy` unset must fetch NOTHING (same discipline as the
# pre-1.6.0 accountMeters key not enabling the chatgpt.com call).
PH1=$TMP/ph1; mkdir -p "$PH1"
printf '{"meshyApiKey":"%s"}\n' "$KEY" > "$PH1/config.json"
curl -s "$API/__reset" >/dev/null
start_pulse "$PH1" 700 || echo "FAIL  server did not start (phase 1)"
for i in 1 2 3 4; do curl -s "http://127.0.0.1:$PORT/api/summary" > "$TMP/gate.json"; sleep 0.4; done
curl -s "$API/__stats" > "$TMP/gate-stats.json"
# opt-in but no key: still nothing on the wire
printf '{"meshy":true}\n' > "$PH1/config.json"
for i in 1 2 3 4; do curl -s "http://127.0.0.1:$PORT/api/summary" > "$TMP/nokey.json"; sleep 0.4; done
curl -s "$API/__stats" > "$TMP/nokey-stats.json"
stop_pulse

# === PHASE 2 — exact credits, then 429 -> stale =============================
PH2=$TMP/ph2; mkdir -p "$PH2"
printf '{"meshy":true,"meshyApiKey":"%s"}\n' "$KEY" > "$PH2/config.json"
curl -s "$API/__reset" >/dev/null; curl -s "$API/__mode?set=ok" >/dev/null
start_pulse "$PH2" 700 || echo "FAIL  server did not start (phase 2)"
poll_meshy "$TMP/ok.json" "ok"
curl -s "http://127.0.0.1:$PORT/api/export?format=json" > "$TMP/export.json"
curl -s "http://127.0.0.1:$PORT/api/statusline" > "$TMP/statusline.json"
curl -s "$API/__stats" > "$TMP/ok-stats.json"
# last-good retention: flip the API to 429 and let a cache window lapse
curl -s "$API/__mode?set=429" >/dev/null
poll_meshy "$TMP/stale.json" "stale"
stop_pulse

# === PHASE 3 — 401 is a bad key: report it, then stop knocking ==============
PH3=$TMP/ph3; mkdir -p "$PH3"
printf '{"meshy":true,"meshyApiKey":"%s"}\n' "$KEY" > "$PH3/config.json"
curl -s "$API/__mode?set=401" >/dev/null; curl -s "$API/__reset" >/dev/null
start_pulse "$PH3" 700 || echo "FAIL  server did not start (phase 3)"
poll_meshy "$TMP/e401.json" "error"
curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/api/summary" > "$TMP/e401.code"
curl -s "$API/__reset" >/dev/null
sleep 2 # several 700ms cache windows
for i in 1 2 3 4; do curl -s "http://127.0.0.1:$PORT/api/summary" >/dev/null; sleep 0.4; done
curl -s "$API/__stats" > "$TMP/e401-stats.json"
stop_pulse

# === PHASE 4 — incremental paging ===========================================
# Long cache so each process refreshes once and the page numbers are readable.
PH4=$TMP/ph4; mkdir -p "$PH4"
printf '{"meshy":true,"meshyApiKey":"%s"}\n' "$KEY" > "$PH4/config.json"
cp "$TMP/fixtureB.json" "$TMP/fixture.json"
curl -s "$API/__mode?set=ok" >/dev/null; curl -s "$API/__reset" >/dev/null
start_pulse "$PH4" 60000 || echo "FAIL  server did not start (phase 4a)"
poll_meshy "$TMP/inc1.json" "ok"
curl -s "$API/__stats" > "$TMP/inc1-stats.json"
stop_pulse
# restart against the SAME ~/.pulse: the persisted store must stop the walk
curl -s "$API/__reset" >/dev/null
start_pulse "$PH4" 60000 || echo "FAIL  server did not start (phase 4b)"
poll_meshy "$TMP/inc2.json" ""
curl -s "$API/__stats" > "$TMP/inc2-stats.json"
stop_pulse

# === PHASE 5 — the routes ===================================================
PH5=$TMP/ph5; mkdir -p "$PH5"
printf '{}\n' > "$PH5/config.json"
cp "$TMP/fixtureA.json" "$TMP/fixture.json"
curl -s "$API/__reset" >/dev/null
start_pulse "$PH5" 700 || echo "FAIL  server did not start (phase 5)"
GETCODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/api/meshy/enable")
# The key goes in the BODY, never a query string. The contract fixes the
# transport but not the field name, so send every plausible spelling — the
# assertion is that a body-set key is persisted and used, not which key it was
# read from.
curl -s -X POST -H 'X-Pulse: 1' -H 'Content-Type: application/json' \
  -d "{\"key\":\"$KEY\",\"apiKey\":\"$KEY\",\"meshyApiKey\":\"$KEY\"}" \
  "http://127.0.0.1:$PORT/api/meshy/enable" > "$TMP/r-en.json"
cp "$PH5/config.json" "$TMP/cfg-en.json"
poll_meshy "$TMP/r-on.json" "ok"
curl -s "$API/__stats" > "$TMP/r-stats.json"
# an empty key clears the stored one
curl -s -X POST -H 'X-Pulse: 1' -H 'Content-Type: application/json' \
  -d '{"key":"","apiKey":"","meshyApiKey":""}' \
  "http://127.0.0.1:$PORT/api/meshy/enable" > "$TMP/r-clear.json"
poll_meshy "$TMP/r-nokey.json" "no-key"
cp "$PH5/config.json" "$TMP/cfg-clear.json"
curl -s -X POST -H 'X-Pulse: 1' "http://127.0.0.1:$PORT/api/meshy/disable" > "$TMP/r-dis.json"
curl -s "http://127.0.0.1:$PORT/api/summary" > "$TMP/r-off.json"
cp "$PH5/config.json" "$TMP/cfg-dis.json"
stop_pulse
kill $MOCK 2>/dev/null; wait $MOCK 2>/dev/null; MOCK=

node -e '
const fs = require("fs"), path = require("path");
const T = process.argv[1], KEY = process.argv[2], GETCODE = process.argv[3];
let fail = 0;
const ok = (c, m) => { console.log((c ? "PASS" : "FAIL") + "  " + m); if (!c) fail = 1; };
const raw = (f) => { try { return fs.readFileSync(path.join(T, f), "utf8"); } catch (e) { return ""; } };
const J = (f) => { try { return JSON.parse(raw(f)); } catch (e) { return null; } };
const M = (f) => { const j = J(f); return (j && j.meshy) || null; };
const near = (a, b) => Math.abs(a - b) < 1e-9;

const exp = J("expected.json");
ok(!!exp, "fixture expectations generated");

// ---- consent gate ---------------------------------------------------------
const gate = J("gate.json"), gateM = M("gate.json"), gateS = J("gate-stats.json");
ok(!!gateM, "payload.meshy present even when off");
if (gateM) {
  ok(gateM.enabled === false, "key present but `meshy` unset -> enabled false (got " + gateM.enabled + ")");
  ok(gateM.status === "disabled", "…status disabled (got " + gateM.status + ")");
  ok(gateM.hasKey === true, "…hasKey still reports the stored key (got " + gateM.hasKey + ")");
  ok(gateM.balance === null && gateM.fetchedAt === null, "…no balance / fetchedAt while off");
}
ok(gateS && gateS.total === 0, "ZERO requests reached Meshy without consent (got " + (gateS && gateS.total) + ")");
ok(raw("gate.json").indexOf(KEY) < 0, "key absent from the off-state payload");

const nokeyM = M("nokey.json"), nokeyS = J("nokey-stats.json");
if (nokeyM) {
  ok(nokeyM.enabled === true && nokeyM.hasKey === false, "opt-in without a key -> enabled, hasKey false");
  ok(nokeyM.status === "no-key", "…status no-key (got " + nokeyM.status + ")");
} else { ok(false, "opt-in-without-key payload present"); }
ok(nokeyS && nokeyS.total === 0, "ZERO requests without a key (got " + (nokeyS && nokeyS.total) + ")");

// ---- the good path --------------------------------------------------------
const okP = J("ok.json"), m = M("ok.json"), okS = J("ok-stats.json");
ok(!!m, "ok-phase payload has meshy");
if (m && exp) {
  ok(m.status === "ok", "status ok (got " + m.status + " / " + (m.error || "no error") + ")");
  ok(m.enabled === true && m.hasKey === true, "enabled + hasKey true");
  ok(m.error === null, "error null (got " + JSON.stringify(m.error) + ")");
  ok(near(m.balance, 987.5), "balance 987.5 credits, fraction intact (got " + m.balance + ")");
  ok(typeof m.fetchedAt === "number" && Date.now() - m.fetchedAt < 120000, "fetchedAt is a recent epoch ms");

  const c = m.credits || {};
  ok(c.today === exp.today, "credits.today = " + exp.today + " (got " + c.today + ")");
  ok(c.week === exp.week, "credits.week = " + exp.week + " (got " + c.week + ")");
  ok(c.month === exp.month, "credits.month = " + exp.month + " (got " + c.month + ")");
  ok(c.allTime === exp.allTime, "credits.allTime = " + exp.allTime + " (got " + c.allTime + ")");

  const bt = m.byType || {};
  const btKeys = Object.keys(bt).sort(), expKeys = Object.keys(exp.byType).sort();
  ok(btKeys.join(",") === expKeys.join(","),
     "byType keys exactly [" + expKeys.join(",") + "] (got [" + btKeys.join(",") + "]) — junk records added none");
  for (const k of expKeys) {
    ok(bt[k] && bt[k].credits === exp.byType[k].credits && bt[k].tasks === exp.byType[k].tasks,
       "byType." + k + " = " + JSON.stringify(exp.byType[k]) + " (got " + JSON.stringify(bt[k] || null) + ")");
  }

  const d = Array.isArray(m.daily) ? m.daily : null;
  ok(!!d, "daily is an array");
  if (d) {
    ok(d.length > 0 && d.length <= 30, "daily covers at most 30 days (got " + d.length + ")");
    ok(d.every((r, i) => i === 0 || d[i - 1].date < r.date), "daily is oldest-first, strictly ascending");
    ok(d[d.length - 1].date === exp.todayDate, "daily ends on today (" + exp.todayDate + ", got " + d[d.length - 1].date + ")");
    ok(d.every((r) => r.date >= exp.oldestAllowed), "daily holds nothing older than 30 days (oldest " + d[0].date + ")");
    let mism = [];
    for (const r of d) {
      const e = exp.byDate[r.date] || { credits: 0, tasks: 0 };
      if (r.credits !== e.credits || r.tasks !== e.tasks) mism.push(r.date + " got " + r.credits + "/" + r.tasks + " want " + e.credits + "/" + e.tasks);
    }
    ok(mism.length === 0, "every daily row exact (credits/tasks)" + (mism.length ? " — " + mism.join("; ") : ""));
    ok(Object.keys(exp.byDate).every((k) => d.some((r) => r.date === k)), "every fixture day appears in daily");
    ok(d.reduce((a, r) => a + r.credits, 0) === exp.allTime, "daily credits sum to allTime");
    ok(d.reduce((a, r) => a + r.tasks, 0) === exp.taskCount, "daily task counts sum to " + exp.taskCount);
  }

  // Only text-to-3d answered; the other families 404 / 405 / hand back broken
  // JSON and must be skipped silently without derailing the refresh.
  const fam = Array.isArray(m.families) ? m.families : null;
  ok(!!fam, "families is an array");
  if (fam) {
    ok(fam.length === 1, "exactly one family answered (got [" + fam.join(",") + "])");
    ok(fam.length === 1 && /text.?to.?3d/i.test(String(fam[0])), "…and it is text-to-3d (got " + fam[0] + ")");
  }
}
if (okS) {
  ok(okS.badAuth === 0, "every Meshy request carried the right bearer token (badAuth " + okS.badAuth + ")");
  ok(okS.keyInUrl === 0, "the key NEVER appeared in a URL/query string (got " + okS.keyInUrl + ")");
  ok(okS.balance >= 1 && okS.list >= 1, "both confirmed endpoints were called (balance " + okS.balance + ", list " + okS.list + ")");
}

// ---- the secret stays put (the most important block) ----------------------
ok(raw("ok.json").indexOf(KEY) < 0, "API key absent from /api/summary at ANY depth");
ok(raw("export.json").indexOf(KEY) < 0, "API key absent from /api/export (full payload dump)");
ok(raw("statusline.json").indexOf(KEY) < 0, "API key absent from /api/statusline");
ok(raw("r-en.json").indexOf(KEY) < 0, "API key absent from the enable-route response");
ok(raw("srv.log").indexOf(KEY) < 0, "API key NEVER appears in the server log (all phases)");
{
  const home = path.join(T, "ph2");
  let leaked = [];
  const walk = (dir) => {
    for (const n of fs.readdirSync(dir)) {
      const p = path.join(dir, n);
      const st = fs.statSync(p);
      if (st.isDirectory()) { walk(p); continue; }
      if (fs.readFileSync(p, "utf8").indexOf(KEY) >= 0 && path.basename(p) !== "config.json") leaked.push(path.relative(home, p));
    }
  };
  try { walk(home); } catch (e) { leaked.push("walk failed: " + e.message); }
  ok(leaked.length === 0, "key confined to ~/.pulse/config.json — no other file holds it" + (leaked.length ? " (leaked into " + leaked.join(", ") + ")" : ""));
  const store = path.join(home, "meshy.json");
  ok(fs.existsSync(store), "task store persisted at ~/.pulse/meshy.json");
  if (fs.existsSync(store) && exp) {
    const txt = fs.readFileSync(store, "utf8");
    ok(exp.ids.every((id) => txt.indexOf(id) >= 0), "…and it holds every fetched task id");
  }
}

// ---- 429: keep the last good answer ---------------------------------------
const st = M("stale.json");
if (st) {
  ok(st.status === "stale", "429 -> status stale (got " + st.status + ")");
  ok(near(st.balance, 987.5), "…last-good balance retained (got " + st.balance + ")");
  ok(exp && st.credits && st.credits.allTime === exp.allTime, "…last-good credits retained (got " + (st.credits && st.credits.allTime) + ")");
} else { ok(false, "stale payload captured"); }

// ---- 401: a bad key, reported once, then left alone -----------------------
const e4 = M("e401.json");
ok(raw("e401.code").trim() === "200", "401 from Meshy still leaves /api/summary a 200 (got " + raw("e401.code").trim() + ")");
if (e4) {
  ok(e4.status === "error", "401 -> status error (got " + e4.status + ")");
  ok(typeof e4.error === "string" && e4.error.length > 0, "…with a human-readable error");
  ok(String(e4.error || "").indexOf(KEY) < 0, "…that does not echo the key");
} else { ok(false, "401 payload captured"); }
const e4s = J("e401-stats.json");
ok(e4s && e4s.total === 0, "after a 401 Pulse stops retrying until the config changes (extra requests: " + (e4s && e4s.total) + ")");

// ---- incremental paging ---------------------------------------------------
const s1 = J("inc1-stats.json"), s2 = J("inc2-stats.json");
if (s1 && s2) {
  const p1 = (s1.pages || []).map((p) => p.n), p2 = (s2.pages || []).map((p) => p.n);
  const size = (s1.pages && s1.pages[0] && s1.pages[0].size) || 50;
  const totalPages = Math.ceil(230 / size);
  ok(p1.length >= 2 && Math.max.apply(null, p1.concat([0])) >= 2, "first run pages through the backlog (pages " + p1.join(",") + ")");
  ok(Math.max.apply(null, p1.concat([0])) < totalPages,
     "first run stops before the end of a 230-task history (30-day cutoff / page cap): max page " +
     Math.max.apply(null, p1.concat([0])) + " of " + totalPages);
  ok(p2.every((n) => n === 1), "second run never pages past page 1 — known tasks are not re-fetched (pages " + (p2.join(",") || "none") + ")");
  ok((s2.list || 0) <= 1, "second run makes at most one list call (got " + s2.list + ")");
} else { ok(false, "paging stats captured"); }
const inc1 = M("inc1.json");
if (inc1 && Array.isArray(inc1.daily) && exp) {
  ok(inc1.daily.every((r) => r.date >= exp.oldestAllowed), "40-139 day old tasks never reach daily");
}

// ---- routes ---------------------------------------------------------------
ok(GETCODE === "403" || GETCODE === "404" || GETCODE === "405",
   "GET /api/meshy/enable is refused — allowMutation-guarded (got " + GETCODE + ")");
const rEn = J("r-en.json"), cfgEn = J("cfg-en.json");
ok(rEn && rEn.ok === true, "POST /api/meshy/enable answers ok");
ok(cfgEn && cfgEn.meshy === true, "…and persists meshy:true");
ok(cfgEn && cfgEn.meshyApiKey === KEY, "…and persists the body-supplied key to config.meshyApiKey");
const rOn = M("r-on.json");
ok(rOn && rOn.enabled === true && rOn.hasKey === true && rOn.status === "ok",
   "body-set key produces a working fetch (status " + (rOn && rOn.status) + ")");
const rS = J("r-stats.json");
ok(rS && rS.total > 0 && rS.badAuth === 0 && rS.keyInUrl === 0,
   "…the body-set key was sent as a bearer header, never in a URL (total " + (rS && rS.total) + ", badAuth " + (rS && rS.badAuth) + ")");
const cfgClear = J("cfg-clear.json"), rNoKey = M("r-nokey.json");
ok(cfgClear && !cfgClear.meshyApiKey, "an empty key clears config.meshyApiKey (got " + JSON.stringify(cfgClear && cfgClear.meshyApiKey) + ")");
ok(rNoKey && rNoKey.hasKey === false && rNoKey.status === "no-key", "…and the payload falls back to no-key");
const cfgDis = J("cfg-dis.json"), rOff = M("r-off.json");
ok(cfgDis && cfgDis.meshy === false, "POST /api/meshy/disable persists meshy:false");
ok(rOff && rOff.enabled === false && rOff.status === "disabled", "…and the payload goes back to disabled");

// ---- credits are NOT dollars ----------------------------------------------
// Same Claude fixture, Meshy off (phase 1) vs Meshy on (phase 2): every dollar
// figure must be byte-identical. Credits have no exchange rate and must never
// be invented one.
if (gate && okP) {
  ok(JSON.stringify(gate.totals) === JSON.stringify(okP.totals),
     "totals identical with Meshy off vs on (cost " + (gate.totals && gate.totals.cost) + " vs " + (okP.totals && okP.totals.cost) + ")");
  const costs = (p) => (p.periods || []).map((x) => x.key + "=" + x.cost).join("|");
  ok(costs(gate) === costs(okP), "every period cost unchanged by Meshy data");
  const pv = (p) => JSON.stringify(p.planValue && p.planValue.spend30);
  ok(pv(gate) === pv(okP), "planValue.spend30 unchanged by Meshy data");
}
if (m) {
  const bad = JSON.stringify(m).match(/"[a-zA-Z]*(cost|usd|dollar|price|spend)[a-zA-Z]*"\s*:/gi);
  ok(!bad, "payload.meshy carries no dollar-flavoured field" + (bad ? " (found " + bad.join(",") + ")" : ""));
  ok(m.credits && ["today", "week", "month", "allTime"].every((k) => typeof m.credits[k] === "number"),
     "credits are plain numbers in their own unit");
}

process.exit(fail);
' "$TMP" "$KEY" "$GETCODE"
RES=$?
echo "---- exit $RES"
exit $RES
