#!/bin/bash
# Custom user-defined sources (config `customSources`): a JSONL usage log
# written by the user's OWN tooling (e.g. a local model harness) is ingested
# read-only as its own source. Verifies: token accounting (cached ⊆ input),
# $0 default cost + trusted record-level cost, id dedup (LAST write wins —
# within a file AND across rotated files by record ts), line-index fallback
# dedup, malformed/token-less lines skipped, epoch-seconds timestamps,
# directory mode, label via payload.sourceMeta (+ spoof/collision fallback),
# name validation (reserved incl. 'mixed' / bad slugs dropped with a warning),
# builtin-overlap paths refused, ?sources= filtering, config rename picked up
# WITHOUT touching the JSONL (route-tagged mtime cache), archive identity
# hygiene (renamed-away custom rows retired from live-covered days + healed
# out of the month file; est rows survive archive-only with the badge), and
# that custom entries stay OUT of the Claude 5h block / Discord activeProvider.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CL=$TMP/claude; PH=$TMP/pulse; FM=$TMP/foreman; LT=$TMP/labtool
mkdir -p "$CL/projects/demo" "$PH/history" "$FM" "$LT"

writeConfig() { # $1 = name for the FM file source (rename test flips it)
  node -e '
const fs=require("fs");
fs.writeFileSync(process.argv[1], JSON.stringify({ customSources: [
  { name: process.argv[4], label: "FOREMAN", path: process.argv[2] + "/usage.jsonl" },
  { name: "labtool", label: "FOREMAN", path: process.argv[3] },  // label collides -> falls back to name
  { name: "mixed",   path: process.argv[3] },                     // reserved (sessions-table alias) -> dropped
  { name: "Bad Name!", path: process.argv[3] },                   // bad slug -> dropped
  { name: "shadow", path: process.argv[5] },                      // builtin-claimed file -> refused at dispatch
] }));
' "$PH/config.json" "$FM" "$LT" "$1" "$CL/projects/demo/s.jsonl"
}
writeConfig foreman

node -e '
const fs=require("fs"); const now=Date.now(); const iso=(m)=>new Date(now-m*60e3).toISOString();
const FM=process.argv[1], LT=process.argv[2], CL=process.argv[3], PH=process.argv[4];
// Deterministic "yesterday noon" (never flips days mid-test, even near midnight)
const yd=new Date(now-864e5); yd.setHours(12,0,0,0);
const ydDs=yd.getFullYear()+"-"+String(yd.getMonth()+1).padStart(2,"0")+"-"+String(yd.getDate()).padStart(2,"0");
// foreman usage.jsonl — expected: tokens 1650+400+15+75+100 = 2240, cost 1.25, messages 5
fs.writeFileSync(FM+"/usage.jsonl", [
  // id "u1" written twice (replay) -> LAST write wins: tokens 1100+550=1650
  JSON.stringify({ ts: iso(10), id: "u1", model: "foreman-7b", input: 1000, output: 500, cached: 200 }),
  JSON.stringify({ ts: iso(9),  id: "u1", model: "foreman-7b", input: 1100, output: 550, cached: 0 }),
  // no id -> line-index dedup, counted once: 400 tokens
  JSON.stringify({ ts: iso(7), model: "foreman-7b", input: 300, output: 100 }),
  "this is not json {{",                                   // malformed -> skipped
  JSON.stringify({ ts: iso(6), note: "boot" }),            // no tokens -> skipped
  // epoch SECONDS timestamp (needs the *1000 heuristic): 75 tokens
  JSON.stringify({ ts: Math.floor((now-8*60e3)/1000), model: "foreman-7b", input: 50, output: 25 }),
  // yesterday-noon record: live custom coverage on the archived day (100 tokens)
  JSON.stringify({ ts: yd.toISOString(), id: "yd1", model: "foreman-7b", input: 60, output: 40 }),
  // record-level cost is trusted verbatim; NEWEST entry overall -> activeProvider must stay null
  JSON.stringify({ ts: iso(1), id: "u9", model: "foreman-7b", input: 10, output: 5, cost: 1.25, sessionId: "fm-s1", project: "fivem-server" }),
].join("\n")+"\n");
// labtool dir mode: a+b (no ids) + the SAME id "dup" across two rotated files —
// the record with the newer ts must win regardless of file/parse order.
// totals: 150 + 300 + 10 = 460 tokens, $0, 3 msgs
fs.writeFileSync(LT+"/a.jsonl", JSON.stringify({ ts: iso(12), model: "lab-1", input: 100, output: 50, estimate: true, sessionId: "lt1" })+"\n");
fs.writeFileSync(LT+"/b.jsonl", JSON.stringify({ ts: iso(11), model: "lab-1", input: 200, output: 100 })+"\n");
fs.writeFileSync(LT+"/c.jsonl", JSON.stringify({ ts: iso(30), id: "dup", model: "lab-1", input: 1000, output: 0 })+"\n");
fs.writeFileSync(LT+"/d.jsonl", JSON.stringify({ ts: iso(2),  id: "dup", model: "lab-1", input: 7, output: 3 })+"\n");
// Claude anchor -> source "cli"; the ONLY entry allowed in the 5h block
fs.writeFileSync(CL+"/projects/demo/s.jsonl", JSON.stringify({
  type:"assistant", timestamp: iso(3), sessionId:"cc1", requestId:"rr1", cwd:"/p",
  message:{ id:"mm1", model:"claude-fable-5", usage:{ input_tokens:0, output_tokens:100000 } } })+"\n");
// Pre-seeded archive for yesterday: "ghost" = a renamed-away custom identity
// (c:1, not in config) that must be retired from the live-covered day and
// healed out of the month file; "esttool" = archive-only est-flagged source
// that must SURVIVE (no c flag) and keep its est badge with no live logs.
const hist={}; hist[ydDs]={ rows:[
  { source:"ghost",   model:"foreman-7b", cost:0, tokens:5000, messages:5, c:1 },
  { source:"esttool", model:"lab-1",      cost:0, tokens:700,  messages:1, est:1 },
], sessions:1 };
fs.writeFileSync(PH+"/history/"+ydDs.slice(0,7)+".json", JSON.stringify(hist));
fs.writeFileSync(PH+"/yd-ds.txt", ydDs);
' "$FM" "$LT" "$CL" "$PH"

PORT=4916
if curl -s -m 1 "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
  echo "FAIL  port $PORT already in use"; echo "---- exit 1"; exit 1
fi
PULSE_HOME=$PH CLAUDE_DIR=$CL CODEX_DIR=$TMP/no-codex PULSE_SUMMARY_MEMO_MS=0 \
node "$ROOT/server.js" --port $PORT --no-update-check >"$TMP/srv.log" 2>&1 &
SRV=$!
sleep 2.5
curl -s "http://127.0.0.1:$PORT/api/summary" > "$TMP/first.json"   # build #1: read-path retirement + seal-heals the month file
sleep 0.6
curl -s "http://127.0.0.1:$PORT/api/summary" > "$TMP/all.json"     # build #2: post-heal roster
curl -s "http://127.0.0.1:$PORT/api/summary?sources=foreman" > "$TMP/fm.json"
curl -s "http://127.0.0.1:$PORT/api/export?format=csv&data=sources&period=last30" > "$TMP/sources.csv"
# Rename foreman -> harness WITHOUT touching the JSONL: the route-tagged mtime
# cache must re-parse and re-attribute on the next build, no restart.
writeConfig harness
sleep 0.6
curl -s "http://127.0.0.1:$PORT/api/summary" > "$TMP/renamed.json"
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

node -e '
const fs=require("fs"); const T=process.argv[1]; const PH=process.argv[2];
let fail=0; const ok=(c,m)=>{console.log((c?"PASS":"FAIL")+"  "+m); if(!c) fail=1;};
const near=(a,b)=>Math.abs(a-b)<1e-9;
const s=require(T+"/all.json");
const p=(s.periods||[]).find(x=>x.key==="last30");

// discovery + validation (post-heal roster: ghost healed out, esttool retained)
ok(JSON.stringify(s.allSources)===JSON.stringify(["cli","esttool","foreman","labtool"]),
  "allSources = cli+esttool+foreman+labtool; invalid/reserved/overlap rows dropped, ghost healed away (got "+JSON.stringify(s.allSources)+")");
ok(s.sourceMeta && s.sourceMeta.foreman && s.sourceMeta.foreman.label==="FOREMAN",
  "sourceMeta carries the FOREMAN label");
ok(!(s.sourceMeta||{}).labtool, "colliding label (FOREMAN on labtool) falls back to the name and is not emitted");

// foreman accounting
const fm=p&&p.bySource&&p.bySource.foreman;
ok(fm && fm.tokens===2240, "foreman tokens: LWW dedup + line fallback + epoch-seconds + yesterday rec (want 2240, got "+(fm&&fm.tokens)+")");
ok(fm && fm.messages===5, "foreman messages=5 (malformed + token-less lines skipped, got "+(fm&&fm.messages)+")");
ok(fm && near(fm.cost,1.25), "foreman cost = trusted record cost only (want 1.25, got "+(fm&&fm.cost)+")");

// labtool dir mode + cross-file id LWW + estimate badge
const lt=p&&p.bySource&&p.bySource.labtool;
ok(lt && lt.tokens===460 && lt.messages===3, "labtool dir mode + cross-file same-id LWW by ts (want 460/3, got "+(lt&&lt.tokens)+"/"+(lt&&lt.messages)+")");
ok(lt && lt.cost===0, "labtool cost $0 (no record-level cost)");
ok((s.estimatedSources||[]).includes("labtool") && !(s.estimatedSources||[]).includes("foreman"),
  "estimate flag: labtool badged, foreman not");

// archive: ghost retired, esttool survives with badge
ok(p && p.bySource && !p.bySource.ghost, "renamed-away custom archive rows (ghost) retired from the live-covered day");
const et=p&&p.bySource&&p.bySource.esttool;
ok(et && et.tokens===700, "archive-only est source (esttool) survives with its data (got "+(et&&et.tokens)+")");
ok((s.estimatedSources||[]).includes("esttool"), "est badge persists from the archive with NO live logs");
const ydDs=fs.readFileSync(PH+"/yd-ds.txt","utf8").trim();
const month=JSON.parse(fs.readFileSync(PH+"/history/"+ydDs.slice(0,7)+".json","utf8"));
const rows=(month[ydDs]||{}).rows||[];
ok(!rows.some(r=>r.source==="ghost") && rows.some(r=>r.source==="esttool"),
  "seal HEALS the month file: ghost dropped, esttool kept (rows: "+JSON.stringify(rows.map(r=>r.source))+")");
ok(rows.some(r=>r.source==="foreman" && r.c===1), "fresh custom rows sealed with the c identity mark");

// Claude 5h block + Discord gate stay honest
ok(s.currentBlock && s.currentBlock.messages===1 && s.currentBlock.tokens===100000,
  "5h block counts ONLY the Claude entry (got "+JSON.stringify(s.currentBlock&&{m:s.currentBlock.messages,t:s.currentBlock.tokens})+")");
ok(s.activeProvider===null, "newest entry is custom -> activeProvider null, never claude");
ok(s.selfCheck && s.selfCheck.ok, "selfCheck ok (got "+JSON.stringify(s.selfCheck&&s.selfCheck.issues)+")");

// server-side ?sources= filter
const f=require(T+"/fm.json");
ok(f.week && f.week.tokens===2240 && f.week.messages===5 && near(f.week.cost,1.25),
  "?sources=foreman scopes the payload (week: "+JSON.stringify(f.week&&{t:f.week.tokens,m:f.week.messages,c:f.week.cost})+")");
ok((f.allSources||[]).includes("labtool"), "filtered build keeps allSources unfiltered (chips stay stable)");

// CSV export sees the source (raw key — keys stay raw everywhere)
const csv=fs.readFileSync(T+"/sources.csv","utf8");
ok(/foreman/.test(csv) && /labtool/.test(csv), "CSV sources export includes custom sources");

// config rename foreman -> harness with the JSONL untouched (route-tagged cache)
const rn=require(T+"/renamed.json");
const rp=(rn.periods||[]).find(x=>x.key==="last30");
const hs=rp&&rp.bySource&&rp.bySource.harness;
ok(hs && hs.tokens===2240 && hs.messages===5, "rename re-attributes WITHOUT touching the file (harness: "+JSON.stringify(hs&&{t:hs.tokens,m:hs.messages})+")");
ok(rp && rp.bySource && !rp.bySource.foreman,
  "no double-count after rename: old name gone from the period (read-path retires the sealed foreman rows)");

// dropped-row + overlap diagnostics (warn-once)
const log=fs.readFileSync(T+"/srv.log","utf8");
ok(/dropped "mixed" — reserved name/.test(log), "reserved name (mixed) dropped with a warning");
ok(/dropped "Bad Name!"/.test(log), "bad slug dropped with a warning");
ok(/"shadow" points at .* another source already ingests/.test(log), "builtin-overlap path refused with a warning");
ok(/\d+ custom/.test(log), "parseAll log reports custom file count");
process.exit(fail);
' "$TMP" "$PH"
RES=$?
echo "---- exit $RES"
exit $RES
