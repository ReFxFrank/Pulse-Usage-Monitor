#!/bin/bash
# A PRICE CHANGE must reach days that are already sealed in ~/.pulse/history.
# pickCell breaks an equal-message tie toward the LIVE / freshly-sealed side, so
# a day still present in the live logs is re-priced from the current table and
# the next re-seal heals the month file — while the non-shrinking guarantee
# (an archived cell with MORE messages still wins) is preserved.
#
# Fixture, all on YESTERDAY (sealable; today is never sealed):
#   cli/claude-sonnet-5   live 1 msg @ $2/$10 = 12   archive says 18 (the
#                         v1.29.0 over-billed price) -> LIVE 12 must win
#   cli/claude-opus-4-8   live 1 msg = 5             archive 9 msgs = 9
#                         -> ARCHIVE must win (more complete, non-shrinking)
#   codex/gpt-5.6-luna    no live entries            archive 5 msgs = 50
#                         -> archive survives untouched
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CL=$TMP/claude; PH=$TMP/pulse
mkdir -p "$CL/projects/demo" "$PH/history"

node -e '
const fs=require("fs");
const CL=process.argv[1], PH=process.argv[2];
const d=new Date(Date.now()-864e5); d.setHours(12,0,0,0);          // yesterday noon, local
const p2=(n)=>String(n).padStart(2,"0");
const ds=d.getFullYear()+"-"+p2(d.getMonth()+1)+"-"+p2(d.getDate());
const A=(id,model,inTok,outTok)=>({ type:"assistant", timestamp:d.toISOString(), sessionId:"s-"+id,
  requestId:"r"+id, cwd:"/p", message:{ id:"m"+id, model, usage:{ input_tokens:inTok, output_tokens:outTok } } });
fs.writeFileSync(CL+"/projects/demo/s.jsonl", [
  A("son","claude-sonnet-5",1000000,1000000),   // $2/$10 -> 12
  A("op","claude-opus-4-8",0,200000),           // $25/MTok out -> 5
].map(JSON.stringify).join("\n")+"\n");
const hist={}; hist[ds]={ rows:[
  { source:"cli",   model:"claude-sonnet-5", cost:18, tokens:2000000, messages:1 },
  { source:"cli",   model:"claude-opus-4-8", cost:9,  tokens:1000000, messages:9 },
  { source:"codex", model:"gpt-5.6-luna",    cost:50, tokens:5000000, messages:5 },
], sessions:3 };
fs.writeFileSync(PH+"/history/"+ds.slice(0,7)+".json", JSON.stringify(hist));
fs.writeFileSync(PH+"/ds.txt", ds);
' "$CL" "$PH"

PORT=4917
if curl -s -m 1 "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
  echo "FAIL  port $PORT already in use"; echo "---- exit 1"; exit 1
fi
PULSE_HOME=$PH CLAUDE_DIR=$CL CODEX_DIR=$TMP/no-codex PULSE_SUMMARY_MEMO_MS=0 \
node "$ROOT/server.js" --port $PORT --no-update-check >"$TMP/srv.log" 2>&1 &
SRV=$!
sleep 2.5
curl -s "http://127.0.0.1:$PORT/api/summary" > "$TMP/out.json"
sleep 0.6
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

node -e '
const fs=require("fs"); const T=process.argv[1]; const PH=process.argv[2];
let fail=0; const ok=(c,m)=>{console.log((c?"PASS":"FAIL")+"  "+m); if(!c) fail=1;};
const near=(a,b)=>Math.abs(a-b)<0.005;
const s=require(T+"/out.json");
const ds=fs.readFileSync(PH+"/ds.txt","utf8").trim();
const p=(s.periods||[]).find(x=>x.key==="last30")||{};
const day=(p.daily||[]).find(b=>b.date===ds);

ok(day && near(day.total, 71), "yesterday total = 12 (re-priced) + 9 (archive) + 50 = 71 (got "+(day&&day.total)+")");
ok(day && near(day.bySource.cli, 21), "cli = re-priced 12 + preserved 9 = 21 (got "+(day&&day.bySource&&day.bySource.cli)+")");
ok(day && near(day.bySource.codex, 50), "archive-only codex cell survives = 50 (got "+(day&&day.bySource&&day.bySource.codex)+")");
const bm=p.byModel||{};
ok(bm["claude-sonnet-5"] && near(bm["claude-sonnet-5"].cost, 12),
   "RE-PRICE: live 12 beats the stale sealed 18 on an equal message count (got "+(bm["claude-sonnet-5"]&&bm["claude-sonnet-5"].cost)+")");
ok(bm["claude-opus-4-8"] && near(bm["claude-opus-4-8"].cost, 9),
   "NON-SHRINK: archived 9-message cell still beats the 1-message live one (got "+(bm["claude-opus-4-8"]&&bm["claude-opus-4-8"].cost)+")");

// the seal must HEAL the month file, not re-inflate it
const month=JSON.parse(fs.readFileSync(PH+"/history/"+ds.slice(0,7)+".json","utf8"));
const rows=(month[ds]||{}).rows||[];
const row=(src,mdl)=>rows.find(r=>r.source===src&&r.model===mdl);
ok(row("cli","claude-sonnet-5") && near(row("cli","claude-sonnet-5").cost, 12),
   "month file HEALED to 12 (got "+JSON.stringify(row("cli","claude-sonnet-5"))+")");
ok(row("cli","claude-opus-4-8") && near(row("cli","claude-opus-4-8").cost, 9),
   "re-seal never shrinks the fuller archived cell (got "+JSON.stringify(row("cli","claude-opus-4-8"))+")");
ok(row("codex","gpt-5.6-luna") && near(row("codex","gpt-5.6-luna").cost, 50),
   "archive-only cell untouched by the re-seal (got "+JSON.stringify(row("codex","gpt-5.6-luna"))+")");
ok(!/unknown model/.test(fs.readFileSync(T+"/srv.log","utf8")), "no unknown-model warnings");
process.exit(fail);
' "$TMP" "$PH"
RES=$?
echo "---- exit $RES"
exit $RES
