#!/bin/bash
# Custom user-defined sources (config `customSources`): a JSONL usage log
# written by the user's OWN tooling (e.g. a local model harness) is ingested
# read-only as its own source. Verifies: token accounting (cached ⊆ input),
# $0 default cost + trusted record-level cost, id dedup (LAST write wins),
# line-index fallback dedup, malformed/empty-token lines skipped, epoch-seconds
# timestamps, directory mode, label via payload.sourceMeta, estimate badging,
# name validation (reserved/bad names dropped), ?sources= filtering, and that
# custom entries stay OUT of the Claude 5h block / Discord activeProvider.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CL=$TMP/claude; PH=$TMP/pulse; FM=$TMP/foreman; LT=$TMP/labtool
mkdir -p "$CL/projects/demo" "$PH" "$FM" "$LT"

# Config: two valid custom sources (file mode + dir mode) and two invalid rows
# that must be silently dropped (reserved name, malformed name).
node -e '
const fs=require("fs");
fs.writeFileSync(process.argv[1], JSON.stringify({ customSources: [
  { name: "foreman", label: "FOREMAN", path: process.argv[2] + "/usage.jsonl" },
  { name: "labtool", path: process.argv[3] },
  { name: "codex",   path: process.argv[3] },      // reserved -> dropped
  { name: "Bad Name!", path: process.argv[3] },     // bad slug -> dropped
] }));
' "$PH/config.json" "$FM" "$LT"

node -e '
const fs=require("fs"); const now=Date.now(); const iso=(m)=>new Date(now-m*60e3).toISOString();
const FM=process.argv[1], LT=process.argv[2], CL=process.argv[3];
// foreman usage.jsonl — expected: tokens 1650+400+15+75 = 2140, cost 1.25, messages 4
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
  // record-level cost is trusted verbatim; NEWEST entry overall -> activeProvider must stay null
  JSON.stringify({ ts: iso(1), id: "u9", model: "foreman-7b", input: 10, output: 5, cost: 1.25, sessionId: "fm-s1", project: "fivem-server" }),
].join("\n")+"\n");
// labtool dir mode: two *.jsonl files, estimate:true on one -> est badge; 450 tokens, $0, 2 msgs
fs.writeFileSync(LT+"/a.jsonl", JSON.stringify({ ts: iso(12), model: "lab-1", input: 100, output: 50, estimate: true, sessionId: "lt1" })+"\n");
fs.writeFileSync(LT+"/b.jsonl", JSON.stringify({ ts: iso(11), model: "lab-1", input: 200, output: 100 })+"\n");
// Claude anchor -> source "cli"; the ONLY entry allowed in the 5h block
fs.writeFileSync(CL+"/projects/demo/s.jsonl", JSON.stringify({
  type:"assistant", timestamp: iso(3), sessionId:"cc1", requestId:"rr1", cwd:"/p",
  message:{ id:"mm1", model:"claude-fable-5", usage:{ input_tokens:0, output_tokens:100000 } } })+"\n");
' "$FM" "$LT" "$CL"

PORT=4916
if curl -s -m 1 "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
  echo "FAIL  port $PORT already in use"; echo "---- exit 1"; exit 1
fi
PULSE_HOME=$PH CLAUDE_DIR=$CL CODEX_DIR=$TMP/no-codex \
node "$ROOT/server.js" --port $PORT --no-update-check >"$TMP/srv.log" 2>&1 &
SRV=$!
sleep 2.5
curl -s "http://127.0.0.1:$PORT/api/summary" > "$TMP/all.json"
curl -s "http://127.0.0.1:$PORT/api/summary?sources=foreman" > "$TMP/fm.json"
curl -s "http://127.0.0.1:$PORT/api/export?format=csv&data=sources&period=last30" > "$TMP/sources.csv"
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

node -e '
const fs=require("fs"); const T=process.argv[1];
let fail=0; const ok=(c,m)=>{console.log((c?"PASS":"FAIL")+"  "+m); if(!c) fail=1;};
const near=(a,b)=>Math.abs(a-b)<1e-9;
const s=require(T+"/all.json");
const p=(s.periods||[]).find(x=>x.key==="last30");

// discovery + validation
ok(JSON.stringify(s.allSources)===JSON.stringify(["cli","foreman","labtool"]),
  "allSources = cli+foreman+labtool, invalid config rows dropped (got "+JSON.stringify(s.allSources)+")");
ok(s.sourceMeta && s.sourceMeta.foreman && s.sourceMeta.foreman.label==="FOREMAN",
  "sourceMeta carries the FOREMAN label");
ok(!(s.sourceMeta||{}).labtool, "identity label (labtool) not emitted in sourceMeta");

// foreman accounting
const fm=p&&p.bySource&&p.bySource.foreman;
ok(fm && fm.tokens===2140, "foreman tokens: last-write-wins dedup + line fallback + epoch-seconds ts (want 2140, got "+(fm&&fm.tokens)+")");
ok(fm && fm.messages===4, "foreman messages=4 (malformed + token-less lines skipped, got "+(fm&&fm.messages)+")");
ok(fm && near(fm.cost,1.25), "foreman cost = trusted record cost only (want 1.25, got "+(fm&&fm.cost)+")");

// labtool dir mode + estimate badge
const lt=p&&p.bySource&&p.bySource.labtool;
ok(lt && lt.tokens===450 && lt.messages===2, "labtool dir mode: both *.jsonl ingested (450 tokens / 2 msgs)");
ok(lt && lt.cost===0, "labtool cost $0 (no record-level cost)");
ok((s.estimatedSources||[]).includes("labtool") && !(s.estimatedSources||[]).includes("foreman"),
  "estimate flag: labtool badged, foreman not");

// Claude 5h block + Discord gate stay honest
ok(s.currentBlock && s.currentBlock.messages===1 && s.currentBlock.tokens===100000,
  "5h block counts ONLY the Claude entry (got "+JSON.stringify(s.currentBlock&&{m:s.currentBlock.messages,t:s.currentBlock.tokens})+")");
ok(s.activeProvider===null, "newest entry is custom -> activeProvider null, never claude (got "+JSON.stringify(s.activeProvider)+")");
ok(s.selfCheck && s.selfCheck.ok, "selfCheck ok (got "+JSON.stringify(s.selfCheck&&s.selfCheck.issues)+")");

// server-side ?sources= filter
const f=require(T+"/fm.json");
ok(f.week && f.week.tokens===2140 && f.week.messages===4 && near(f.week.cost,1.25),
  "?sources=foreman scopes the payload (week: "+JSON.stringify(f.week&&{t:f.week.tokens,m:f.week.messages,c:f.week.cost})+")");
ok(JSON.stringify(f.allSources)===JSON.stringify(["cli","foreman","labtool"]),
  "filtered build keeps allSources unfiltered (chips stay stable)");

// CSV export sees the source (raw key — keys stay raw everywhere)
const csv=fs.readFileSync(T+"/sources.csv","utf8");
ok(/foreman/.test(csv) && /labtool/.test(csv), "CSV sources export includes custom sources");

// walked-files log line mentions the custom files
const log=fs.readFileSync(T+"/srv.log","utf8");
ok(/3 custom/.test(log), "parseAll log reports 3 custom file(s)");
process.exit(fail);
' "$TMP"
RES=$?
echo "---- exit $RES"
exit $RES
