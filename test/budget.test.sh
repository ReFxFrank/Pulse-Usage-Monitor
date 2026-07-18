#!/bin/bash
# Budget goal: payload.budget reports spend against a self-set target, with
# ok/warn/over states and month vs week periods; the POST endpoint sets and
# clears it.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CL=$TMP/claude; PH=$TMP/pulse
mkdir -p "$CL/projects/demo" "$PH"
# One Claude turn TODAY costing exactly $30 (fable-5 $10/$50, 600k output).
node -e 'const fs=require("fs");fs.writeFileSync(process.argv[1]+"/projects/demo/s.jsonl",JSON.stringify({type:"assistant",timestamp:new Date().toISOString(),sessionId:"s",requestId:"r",cwd:"/p",message:{id:"m",model:"claude-fable-5",usage:{input_tokens:0,output_tokens:600000}}})+"\n");' "$CL"

PORT=4896
fetch() { # $1 config json, $2 outfile
  echo "$1" > "$PH/config.json"
  PULSE_HOME=$PH CLAUDE_DIR=$CL CODEX_DIR=$TMP/nc node "$ROOT/server.js" --port $PORT --no-update-check >"$TMP/srv.log" 2>&1 &
  local SRV=$!; sleep 2.2
  curl -s "http://127.0.0.1:$PORT/api/summary" > "$2"
  kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
}

fetch '{"budget":100,"budgetPeriod":"month"}' "$TMP/ok.json"
fetch '{"budget":35,"budgetPeriod":"month"}'  "$TMP/warn.json"
fetch '{"budget":25,"budgetPeriod":"month"}'  "$TMP/over.json"
fetch '{"budget":100,"budgetPeriod":"week"}'   "$TMP/week.json"
fetch '{}' "$TMP/none.json"

# POST set + clear (start a server, mutate, re-read)
echo '{}' > "$PH/config.json"
PULSE_HOME=$PH CLAUDE_DIR=$CL CODEX_DIR=$TMP/nc node "$ROOT/server.js" --port $PORT --no-update-check >"$TMP/srv.log" 2>&1 &
SRV=$!; sleep 2.2
curl -s -X POST -H 'X-Pulse: 1' "http://127.0.0.1:$PORT/api/budget/set?amount=50&period=month" > "$TMP/setresp.json"
curl -s "http://127.0.0.1:$PORT/api/summary" > "$TMP/afterset.json"
curl -s -X POST -H 'X-Pulse: 1' "http://127.0.0.1:$PORT/api/budget/set?amount=0" > /dev/null
curl -s "http://127.0.0.1:$PORT/api/summary" > "$TMP/afterclear.json"
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

node -e '
const fs=require("fs"); const T=process.argv[1];
let fail=0; const ok=(c,m)=>{console.log((c?"PASS":"FAIL")+"  "+m); if(!c) fail=1;};
const near=(a,b)=>typeof a==="number"&&Math.abs(a-b)<0.02;
const B=(f)=>require(T+"/"+f).budget;
const okc=B("ok.json");
ok(okc && near(okc.spent,30) && okc.target===100, "spent $30 of $100 target (got "+(okc&&okc.spent)+")");
ok(okc && near(okc.pct,30) && okc.state==="ok" && near(okc.remaining,70), "30% -> state ok, $70 left");
ok(okc && okc.period==="month" && okc.resetsAt>Date.now(), "month period resets in the future");
ok(B("warn.json").state==="warn", "spend 30/35 = 85.7% -> warn ("+B("warn.json").pct.toFixed(1)+"%)");
const over=B("over.json");
ok(over.state==="over" && near(over.remaining,0), "spend 30/25 = 120% -> over, remaining clamped to 0");
const wk=B("week.json");
ok(wk && near(wk.spent,30) && wk.period==="week" && wk.resetsAt===null, "week period uses trailing-7d spend, no hard reset");
ok(B("none.json")===null || B("none.json")===undefined, "no budget configured -> payload.budget null");

const sr=require(T+"/setresp.json");
ok(sr.ok && sr.budget && sr.budget.target===50, "POST set -> {target:50}");
const as=require(T+"/afterset.json").budget;
ok(as && as.target===50 && near(as.spent,30), "after set: budget active with live spend");
const ac=require(T+"/afterclear.json").budget;
ok(ac===null || ac===undefined, "POST amount=0 clears the budget");
process.exit(fail);
' "$TMP"
RES=$?
echo "---- exit $RES"
exit $RES
