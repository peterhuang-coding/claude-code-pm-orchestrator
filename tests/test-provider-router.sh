#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ROUTER="$ROOT/.claude/skills/pm-orchestrator/scripts/pm-provider-router.js"
HELPER="$ROOT/tests/helpers/mock-anthropic-server.js"
TMP=$(mktemp -d)
PIDS=""
FILTER=${PM_ROUTER_TEST_FILTER:-all}
router_backoff_ms=1
trap 'for p in $PIDS; do kill "$p" 2>/dev/null || true; done; rm -rf "$TMP"' EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ -f "$ROUTER" ] || fail "router implementation missing: $ROUTER"
safe_log_tail() {
  tail -20 "$1" 2>/dev/null |
    sed -e 's/upstream-minimax-secret/[REDACTED]/g' \
        -e 's/upstream-glm-secret/[REDACTED]/g' \
        -e 's/upstream-deepseek-secret/[REDACTED]/g' \
        -e 's/local-secret-token/[REDACTED]/g' \
        -e 's/PROMPT_MARKER_DO_NOT_LEAK/[REDACTED]/g' >&2 || true
}
wait_file() {
  ready=$1 child=$2 log=$3 i=0
  while [ ! -s "$ready" ]; do
    if ! kill -0 "$child" 2>/dev/null; then
      safe_log_tail "$log"
      fail "child exited before creating $ready"
    fi
    i=$((i+1))
    [ "$i" -lt 100 ] || { safe_log_tail "$log"; fail "timeout waiting for $ready"; }
    sleep .02
  done
}
wait_router() {
  i=0
  until curl --noproxy '*' -fsS \
    -H 'Authorization: Bearer local-secret-token' \
    "http://127.0.0.1:$router_port/_pm/health" >"$TMP/health" 2>/dev/null; do
    if ! kill -0 "$router_pid" 2>/dev/null; then
      safe_log_tail "$TMP/router.log"
      fail "router exited before becoming healthy"
    fi
    i=$((i+1))
    [ "$i" -lt 100 ] || { safe_log_tail "$TMP/router.log"; fail "router health timeout"; }
    sleep .02
  done
}

start_mock() {
  name=$1
  node "$HELPER" 0 "$TMP/$name.scenario" "$TMP/$name.records" "$TMP/$name.ready" >"$TMP/$name.log" 2>&1 &
  pid=$!; PIDS="$PIDS $pid"; wait_file "$TMP/$name.ready" "$pid" "$TMP/$name.log"
  eval "${name}_port=\$(cat \"\$TMP/$name.ready\")"
}

write_scenario() {
  name=$1; shift
  printf '%s\n' "$*" >"$TMP/$name.scenario"
  : >"$TMP/$name.records"
  rm -f "$TMP/$name.records.cleanup"
}

request() {
  path=$1
  node - "$router_port" "$path" "$TMP/response.json" <<'NODE'
const http = require('http'), fs = require('fs');
const [port, path, out] = process.argv.slice(2);
const body = JSON.stringify({
  model:'caller-model',
  messages:[{role:'user',content:'PROMPT_MARKER_DO_NOT_LEAK'}],
  max_tokens:17,
  tools:[{name:'weather',description:'Lookup',input_schema:{type:'object',properties:{city:{type:'string'}}}}],
  metadata:{user_id:'test-user'},
  stream:false,
  extra:{keep:true}
});
const req = http.request({host:'127.0.0.1',port,path,method:'POST',headers:{
  authorization:'Bearer local-secret-token','content-type':'application/json',
  accept:'application/json','user-agent':'pm-router-test/1','x-request-id':'inbound-safe-id',
  'anthropic-version':'2023-06-01','anthropic-beta':'feature-x'
}}, res => {
  const chunks=[]; res.on('data', c=>chunks.push(c)); res.on('end',()=>fs.writeFileSync(out,JSON.stringify({
    status:res.statusCode,headers:res.headers,body:Buffer.concat(chunks).toString('utf8')
  })));
});
req.on('error', e=>{console.error(e.message);process.exit(2)}); req.end(body);
NODE
}

stream_request() {
  output=$1
  node - "$router_port" "$output" <<'NODE'
const http = require('http'), fs = require('fs');
const [port, out] = process.argv.slice(2);
const started = Date.now();
const body = JSON.stringify({
  model:'caller-model',
  messages:[{role:'user',content:'PROMPT_MARKER_DO_NOT_LEAK'}],
  max_tokens:17,
  tools:[{name:'weather',description:'Lookup',input_schema:{type:'object',properties:{city:{type:'string'}}}}],
  metadata:{user_id:'test-user'},
  stream:false,
  extra:{keep:true}
});
let settled = false;
function finish(value) {
  if (settled) return;
  settled = true;
  fs.writeFileSync(out, JSON.stringify(value));
}
const req = http.request({host:'127.0.0.1',port,path:'/v1/messages?trace=1',method:'POST',headers:{
  authorization:'Bearer local-secret-token','content-type':'application/json',
  accept:'text/event-stream','user-agent':'pm-router-test/1','x-request-id':'inbound-safe-id',
  'anthropic-version':'2023-06-01','anthropic-beta':'feature-x'
}}, res => {
  const chunks=[]; let firstMs=null;
  res.on('data', chunk => {
    if (firstMs === null) firstMs = Date.now() - started;
    chunks.push(chunk);
  });
  res.on('end', () => finish({
    event:'end',status:res.statusCode,headers:res.headers,
    body:Buffer.concat(chunks).toString('utf8'),first_ms:firstMs,total_ms:Date.now()-started
  }));
  res.on('aborted', () => finish({
    event:'aborted',status:res.statusCode,headers:res.headers,
    body:Buffer.concat(chunks).toString('utf8'),first_ms:firstMs,total_ms:Date.now()-started
  }));
  res.on('error', error => finish({
    event:'response_error',status:res.statusCode,headers:res.headers,
    body:Buffer.concat(chunks).toString('utf8'),first_ms:firstMs,total_ms:Date.now()-started,
    error:error.code || error.message
  }));
});
req.on('error', error => finish({event:'request_error',error:error.code || error.message,total_ms:Date.now()-started}));
req.end(body);
setTimeout(() => {
  if (!settled) {
    req.destroy();
    finish({event:'timeout',total_ms:Date.now()-started});
  }
}, 5000).unref();
NODE
}

assert_state_safe() {
  python3 - "$TMP/home/state.json" "$TMP/home" <<'PY'
import json, pathlib, stat, sys
state=pathlib.Path(sys.argv[1]); home=pathlib.Path(sys.argv[2])
assert stat.S_IMODE(state.stat().st_mode)==0o600
value=json.loads(state.read_text())
assert set(value) <= {"active","mode","cooldowns","current_provider","last_transition"}
assert not list(home.glob(".state.json.*.tmp"))
PY
}

run_stream_tests() {
  # A successful SSE response is visible before the final chunk and is byte-identical.
  write_scenario minimax '[{"status":200,"contentType":"text/event-stream","requestId":"stream-ok-id","headers":{"cache-control":"no-cache"},"chunks":["event: message_start\ndata: {\"type\":\"message_start\"}\n\n","event: content_block_delta\ndata: {\"delta\":{\"text\":\"STREAM_EXPECTED_ONLY\"}}\n\n","event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"],"chunk_delay_ms":250}]'
  write_scenario glm '[]'; write_scenario deepseek '[]'; restart_router
  stream_request "$TMP/stream-success.json"
  python3 - "$TMP/stream-success.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
expected='event: message_start\ndata: {"type":"message_start"}\n\nevent: content_block_delta\ndata: {"delta":{"text":"STREAM_EXPECTED_ONLY"}}\n\nevent: message_stop\ndata: {"type":"message_stop"}\n\n'
assert r["event"]=="end", r
assert r["status"]==200, r
assert r["headers"]["content-type"]=="text/event-stream", r
assert r["headers"]["x-request-id"]=="stream-ok-id", r
assert r["body"]==expected, (repr(r["body"]),repr(expected))
assert r["first_ms"] is not None and r["total_ms"]-r["first_ms"] >= 350, r
assert r["headers"]["cache-control"]=="no-cache", r
PY

  # A 2xx that aborts before any body byte remains eligible for fallback.
  write_scenario minimax '[
    {"status":200,"contentType":"text/event-stream","chunks":["unused"],"abort_after_chunk":0},
    {"status":200,"contentType":"text/event-stream","chunks":["unused"],"abort_after_chunk":0}
  ]'
  write_scenario glm '[{"status":200,"contentType":"text/event-stream","chunks":["event: message_stop\ndata: {\"provider\":\"glm-before-byte\"}\n\n"]}]'
  write_scenario deepseek '[]'; restart_router
  stream_request "$TMP/stream-before-byte.json"
  python3 - "$TMP/stream-before-byte.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert r["event"]=="end" and r["status"]==200, r
assert r["body"]=='event: message_stop\ndata: {"provider":"glm-before-byte"}\n\n', r
PY
  [ "$(wc -l <"$TMP/minimax.records" | tr -d ' ')" = 2 ] || fail "pre-byte network error did not retry MiniMax"
  [ "$(wc -l <"$TMP/glm.records" | tr -d ' ')" = 1 ] || fail "pre-byte network error did not fall back to GLM"

  # Once a byte is committed, abort the client response and never fan out.
  write_scenario minimax '[{"status":200,"contentType":"text/event-stream","chunks":["event: message_start\ndata: {\"partial\":\"ONLY_CLIENT_CAPTURE\"}\n\n","event: message_stop\ndata: {}\n\n"],"chunk_delay_ms":50,"abort_after_chunk":1}]'
  write_scenario glm '[]'; write_scenario deepseek '[]'; restart_router
  stream_request "$TMP/stream-partial.json"
  python3 - "$TMP/stream-partial.json" "$TMP/home/state.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert r["event"] in ("aborted","response_error"), r
assert r["status"]==200, r
assert r["body"]=='event: message_start\ndata: {"partial":"ONLY_CLIENT_CAPTURE"}\n\n', r
assert "providers_unavailable" not in r["body"] and "router" not in r["body"], r
s=json.load(open(sys.argv[2]))
assert s["cooldowns"]["minimax"]["reason"]=="stream", s
PY
  [ ! -s "$TMP/glm.records" ] || fail "partial stream fell back to GLM"
  [ ! -s "$TMP/deepseek.records" ] || fail "partial stream fell back to DeepSeek"
  kill -0 "$router_pid" 2>/dev/null || fail "router crashed after partial stream"

  # A later request sees the stream cooldown and starts at GLM.
  write_scenario minimax '[]'
  write_scenario glm '[{"status":200,"contentType":"text/event-stream","chunks":["event: message_stop\ndata: {\"provider\":\"glm-cooldown\"}\n\n"]}]'
  write_scenario deepseek '[]'
  stream_request "$TMP/stream-cooldown.json"
  python3 - "$TMP/stream-cooldown.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert r["event"]=="end" and '"glm-cooldown"' in r["body"], r
PY
  [ ! -s "$TMP/minimax.records" ] || fail "stream cooldown did not skip MiniMax"
  [ "$(wc -l <"$TMP/glm.records" | tr -d ' ')" = 1 ] || fail "cooldown request did not use GLM"

  # A downstream client can disconnect mid-stream without crashing or replaying.
  write_scenario minimax '[{"status":200,"contentType":"text/event-stream","chunks":["data: client-will-close\n\n","data: must-not-crash\n\n"],"chunk_delay_ms":100}]'
  write_scenario glm '[]'; write_scenario deepseek '[]'; restart_router
  node - "$router_port" "$TMP/downstream-abort.json" <<'NODE'
const http=require('http'),fs=require('fs');
const [port,out]=process.argv.slice(2);
const body=JSON.stringify({model:'caller',messages:[{role:'user',content:'PROMPT_MARKER_DO_NOT_LEAK'}],
  max_tokens:17,tools:[{name:'weather',input_schema:{properties:{city:{type:'string'}}}}],
  metadata:{user_id:'test-user'},stream:false,extra:{keep:true}});
const req=http.request({host:'127.0.0.1',port,path:'/v1/messages?trace=1',method:'POST',headers:{
  authorization:'Bearer local-secret-token','content-type':'application/json',accept:'text/event-stream',
  'user-agent':'pm-router-test/1','x-request-id':'inbound-safe-id',
  'anthropic-version':'2023-06-01','anthropic-beta':'feature-x'
}},res=>{
  res.once('data',chunk=>{
    fs.writeFileSync(out,JSON.stringify({event:'client_destroy',body:chunk.toString('utf8')}));
    res.destroy();
  });
  res.on('error',()=>{});
});
req.on('error',()=>{});
req.end(body);
setTimeout(()=>{if(!fs.existsSync(out)){fs.writeFileSync(out,JSON.stringify({event:'timeout'}));req.destroy()}},2000);
NODE
  sleep .2
  python3 - "$TMP/downstream-abort.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert r["event"]=="client_destroy" and r["body"]=="data: client-will-close\n\n", r
PY
  [ ! -s "$TMP/glm.records" ] || fail "downstream abort replayed to GLM"
  [ ! -s "$TMP/deepseek.records" ] || fail "downstream abort replayed to DeepSeek"
  kill -0 "$router_pid" 2>/dev/null || fail "router crashed after downstream abort"
  python3 - "$TMP/minimax.records.cleanup" <<'PY'
import json,sys
events=[json.loads(line) for line in open(sys.argv[1])]
assert events and any(event["reason"] in ("response_close","socket_close") for event in events), events
PY

  # Closing during retry backoff cancels before another upstream attempt.
  router_backoff_ms=500
  write_scenario minimax '[
    {"disconnect":true},
    {"status":200,"contentType":"text/event-stream","chunks":["data: forbidden-retry\n\n"]}
  ]'
  write_scenario glm '[{"status":200,"body":{"ok":"forbidden-fallback"}}]'
  write_scenario deepseek '[]'; restart_router
  node - "$router_port" "$TMP/backoff-abort.json" <<'NODE'
const http=require('http'),fs=require('fs');
const [port,out]=process.argv.slice(2);
const body=JSON.stringify({model:'caller',messages:[{role:'user',content:'PROMPT_MARKER_DO_NOT_LEAK'}],
  max_tokens:17,tools:[{name:'weather',input_schema:{properties:{city:{type:'string'}}}}],
  metadata:{user_id:'test-user'},stream:false,extra:{keep:true}});
const req=http.request({host:'127.0.0.1',port,path:'/v1/messages?trace=1',method:'POST',headers:{
  authorization:'Bearer local-secret-token','content-type':'application/json',accept:'text/event-stream',
  'user-agent':'pm-router-test/1','x-request-id':'inbound-safe-id',
  'anthropic-version':'2023-06-01','anthropic-beta':'feature-x'
}});
req.on('error',()=>{});
req.end(body);
setTimeout(()=>{
  req.destroy();
  fs.writeFileSync(out,JSON.stringify({event:'client_destroy_during_backoff'}));
},100);
NODE
  sleep .7
  [ "$(wc -l <"$TMP/minimax.records" | tr -d ' ')" = 1 ] || fail "client abort during backoff started another MiniMax request"
  [ ! -s "$TMP/glm.records" ] || fail "client abort during backoff fell back to GLM"
  [ ! -s "$TMP/deepseek.records" ] || fail "client abort during backoff fell back to DeepSeek"
  kill -0 "$router_pid" 2>/dev/null || fail "router crashed after backoff abort"
  router_backoff_ms=1

  # Buffered 4xx strips stale encoding and recomputes body length.
  write_scenario minimax '[{"status":418,"contentType":"application/json","headers":{"content-encoding":"gzip"},"body":"{\"error\":{\"type\":\"invalid_request\",\"message\":\"plain buffered body\"}}"}]'
  write_scenario glm '[]'; write_scenario deepseek '[]'; restart_router
  node - "$router_port" "$TMP/buffered-headers.json" <<'NODE'
const http=require('http'),fs=require('fs');
const [port,out]=process.argv.slice(2);
const body=JSON.stringify({model:'caller',messages:[{role:'user',content:'PROMPT_MARKER_DO_NOT_LEAK'}],
  max_tokens:17,tools:[{name:'weather',input_schema:{properties:{city:{type:'string'}}}}],
  metadata:{user_id:'test-user'},stream:false,extra:{keep:true}});
let settled=false;
const finish=value=>{if(settled)return;settled=true;fs.writeFileSync(out,JSON.stringify(value))};
const req=http.request({host:'127.0.0.1',port,path:'/v1/messages?trace=1',method:'POST',headers:{
  authorization:'Bearer local-secret-token','content-type':'application/json',accept:'application/json',
  'user-agent':'pm-router-test/1','x-request-id':'inbound-safe-id',
  'anthropic-version':'2023-06-01','anthropic-beta':'feature-x'
}},res=>{
  const chunks=[];
  res.on('data',chunk=>chunks.push(chunk));
  res.on('end',()=>finish({event:'end',status:res.statusCode,headers:res.headers,body:Buffer.concat(chunks).toString()}));
  res.on('aborted',()=>finish({event:'aborted',status:res.statusCode,headers:res.headers,body:Buffer.concat(chunks).toString()}));
  res.on('error',error=>finish({event:'response_error',error:error.code||error.message}));
});
req.on('error',error=>finish({event:'request_error',error:error.code||error.message}));
req.end(body);
setTimeout(()=>{if(!settled){req.destroy();finish({event:'timeout'})}},1500);
NODE
  python3 - "$TMP/buffered-headers.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert r["event"]=="end" and r["status"]==418, r
assert "content-encoding" not in r["headers"], r
assert int(r["headers"]["content-length"])==len(r["body"].encode()), r
b=json.loads(r["body"])
assert b["error"]["type"]=="upstream_error", b
assert "plain buffered body" not in r["body"], r
PY

  # A truncated non-fallback 4xx becomes bounded uncompressed diagnostic JSON.
  write_scenario minimax '[{"status":418,"contentType":"application/json","largeErrorBytes":70000,"errorType":"oversized_request_error"}]'
  write_scenario glm '[]'; write_scenario deepseek '[]'; restart_router
  request '/v1/messages?trace=1'
  python3 - "$TMP/response.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert r["status"]==418, r
assert int(r["headers"]["content-length"])==len(r["body"].encode()), r
assert "content-encoding" not in r["headers"], r
b=json.loads(r["body"])
assert b["error"]["type"]=="upstream_error", b
assert "XXXX" not in r["body"] and len(r["body"])<65536, r
PY

  # Twelve overlapping successes and quota fallbacks leave durable valid state.
  write_scenario minimax '[
    {"status":200,"contentType":"text/event-stream","chunks":["data: success-1\n\n","data: done-1\n\n"],"chunk_delay_ms":20},
    {"status":402,"body":{"error":{"type":"quota"}}},
    {"status":200,"contentType":"text/event-stream","chunks":["data: success-2\n\n","data: done-2\n\n"],"chunk_delay_ms":20},
    {"status":402,"body":{"error":{"type":"quota"}}},
    {"status":200,"contentType":"text/event-stream","chunks":["data: success-3\n\n","data: done-3\n\n"],"chunk_delay_ms":20},
    {"status":402,"body":{"error":{"type":"quota"}}},
    {"status":200,"contentType":"text/event-stream","chunks":["data: success-4\n\n","data: done-4\n\n"],"chunk_delay_ms":20},
    {"status":402,"body":{"error":{"type":"quota"}}},
    {"status":200,"contentType":"text/event-stream","chunks":["data: success-5\n\n","data: done-5\n\n"],"chunk_delay_ms":20},
    {"status":402,"body":{"error":{"type":"quota"}}},
    {"status":200,"contentType":"text/event-stream","chunks":["data: success-6\n\n","data: done-6\n\n"],"chunk_delay_ms":20},
    {"status":402,"body":{"error":{"type":"quota"}}}
  ]'
  write_scenario glm '[
    {"status":200,"contentType":"text/event-stream","chunks":["data: glm-1\n\n"]},
    {"status":200,"contentType":"text/event-stream","chunks":["data: glm-2\n\n"]},
    {"status":200,"contentType":"text/event-stream","chunks":["data: glm-3\n\n"]},
    {"status":200,"contentType":"text/event-stream","chunks":["data: glm-4\n\n"]},
    {"status":200,"contentType":"text/event-stream","chunks":["data: glm-5\n\n"]},
    {"status":200,"contentType":"text/event-stream","chunks":["data: glm-6\n\n"]}
  ]'
  write_scenario deepseek '[]'; restart_router
  node - "$router_port" "$TMP/concurrent-output.json" "$TMP/home/state.json" <<'NODE'
const http=require('http'),fs=require('fs');
const [port,out,statePath]=process.argv.slice(2);
const body=JSON.stringify({model:'caller',messages:[{role:'user',content:'PROMPT_MARKER_DO_NOT_LEAK'}],
  max_tokens:17,tools:[{name:'weather',input_schema:{properties:{city:{type:'string'}}}}],
  metadata:{user_id:'test-user'},stream:false,extra:{keep:true}});
let parseError=null;
const monitor=setInterval(()=>{
  try { JSON.parse(fs.readFileSync(statePath,'utf8')); } catch (error) { parseError=error.message; }
},1);
const active=new Set();
const watchdog=setTimeout(()=>{
  for(const req of active) req.destroy();
  console.error(`concurrency watchdog expired: active=${active.size}`);
  process.exit(3);
},5000);
const one=index=>new Promise(resolve=>{
  let settled=false;
  let req;
  const done=value=>{if(!settled){settled=true;active.delete(req);resolve({index,...value})}};
  req=http.request({host:'127.0.0.1',port,path:'/v1/messages?trace=1',method:'POST',headers:{
    authorization:'Bearer local-secret-token','content-type':'application/json',accept:'text/event-stream',
    'user-agent':'pm-router-test/1','x-request-id':'inbound-safe-id',
    'anthropic-version':'2023-06-01','anthropic-beta':'feature-x'
  }},res=>{
    const chunks=[];res.on('data',c=>chunks.push(c));
    res.on('end',()=>done({event:'end',status:res.statusCode,bytes:Buffer.concat(chunks).length}));
    res.on('aborted',()=>done({event:'aborted',status:res.statusCode,bytes:Buffer.concat(chunks).length}));
    res.on('error',e=>done({event:'response_error',error:e.code||e.message}));
  });
  active.add(req);
  req.on('error',e=>done({event:'request_error',error:e.code||e.message}));
  req.end(body);
});
Promise.all(Array.from({length:12},(_,i)=>one(i))).then(results=>{
  clearTimeout(watchdog);
  clearInterval(monitor);
  fs.writeFileSync(out,JSON.stringify({results,parseError}));
}).catch(error=>{clearTimeout(watchdog);clearInterval(monitor);console.error(error);process.exit(2)});
NODE
  python3 - "$TMP/concurrent-output.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
assert r["parseError"] is None, r
assert len(r["results"])==12, r
assert all(x["event"]=="end" and x["status"]==200 and x["bytes"]>0 for x in r["results"]), r
PY
  assert_state_safe
  kill -0 "$router_pid" 2>/dev/null || fail "router crashed under concurrency"
}

assert_case() {
  expected_status=$1 expected_provider=$2 expected_model=$3
  python3 - "$TMP/response.json" "$TMP" "$expected_status" "$expected_provider" "$expected_model" <<'PY'
import json, pathlib, sys
response, root, status, provider, model = sys.argv[1:]
r=json.load(open(response)); assert r["status"] == int(status), r
root=pathlib.Path(root)
counts={}
for p in ("minimax","glm","deepseek"):
    f=root/f"{p}.records"
    rows=[json.loads(x) for x in f.read_text().splitlines()] if f.exists() else []
    counts[p]=len(rows)
    for row in rows:
        assert "PROMPT_MARKER" not in json.dumps(row)
        assert "authorization" not in row["headers"]
        assert row["payload_valid"] is True, row
        assert row["host_valid"] is True, row
        assert row["content_length_valid"] is True, row
        if row["auth_valid"] is not None:
            assert row["auth_valid"] is True, row
            assert row["auth_header"] == "x-api-key", row
        assert row["path"].endswith("/v1/messages?trace=1"), row
        assert row["headers"]["content-type"] == "application/json"
        assert row["headers"]["accept"] == "application/json"
        assert row["headers"]["user-agent"] == "pm-router-test/1"
        assert row["headers"]["x-request-id"] == "inbound-safe-id"
        assert row["headers"]["anthropic-version"] == "2023-06-01"
        assert row["headers"]["anthropic-beta"] == "feature-x"
if provider != "-":
    assert counts[provider] >= 1, counts
    row=json.loads((root/f"{provider}.records").read_text().splitlines()[-1])
    assert row["model"] == model, row
PY
}

restart_router() {
  kill "$router_pid" 2>/dev/null || true
  wait "$router_pid" 2>/dev/null || true
  if [ "$#" -gt 0 ]; then state_json=$1
  else state_json='{"active":true,"mode":"auto","cooldowns":{},"current_provider":null,"last_transition":null}'; fi
  printf '%s\n' "$state_json" >"$TMP/home/state.json"
  PM_PROVIDER_HOME="$TMP/home" PM_PROVIDER_KEYCHAIN_DIR="$TMP/keys" PM_PROVIDER_BACKOFF_MS="$router_backoff_ms" node "$ROUTER" >"$TMP/router.log" 2>&1 &
  router_pid=$!; PIDS="$PIDS $router_pid"; wait_router
}

mkdir -p "$TMP/home" "$TMP/keys"
chmod 700 "$TMP/home" "$TMP/keys"
printf '%s' local-secret-token >"$TMP/keys/router-local"
printf '%s' upstream-minimax-secret >"$TMP/keys/minimax"
printf '%s' upstream-glm-secret >"$TMP/keys/glm"
printf '%s' upstream-deepseek-secret >"$TMP/keys/deepseek"

auth_hash() {
node - "$1" <<'NODE'
const fs=require('fs'),crypto=require('crypto');
const key=fs.readFileSync(process.argv[2],'utf8');
console.log(crypto.createHash('sha256').update(key).digest('hex'));
NODE
}
minimax_auth_hash=$(auth_hash "$TMP/keys/minimax")
glm_auth_hash=$(auth_hash "$TMP/keys/glm")
deepseek_auth_hash=$(auth_hash "$TMP/keys/deepseek")
write_scenario minimax "[{\"status\":200,\"expectedAuthSha256\":\"$minimax_auth_hash\",\"body\":{\"ok\":\"minimax\"}}]"
write_scenario glm '[{"status":200,"body":{"ok":"glm"}}]'
write_scenario deepseek '[{"status":200,"body":{"ok":"deepseek"}}]'
start_mock minimax; start_mock glm; start_mock deepseek

router_port=$(node -e "const s=require('net').createServer();s.listen(0,'127.0.0.1',()=>{console.log(s.address().port);s.close()})")
cat >"$TMP/home/config.json" <<EOF
{"version":1,"listen":{"host":"127.0.0.1","port":$router_port},"providers":[
{"id":"minimax","base_url":"http://127.0.0.1:$minimax_port/anthropic","model":"MiniMax-M3","auth_scheme":"x-api-key"},
{"id":"glm","base_url":"http://127.0.0.1:$glm_port","model":"glm-5.2","auth_scheme":"x-api-key"},
{"id":"deepseek","base_url":"http://127.0.0.1:$deepseek_port/anthropic","model":"deepseek-v4-pro","auth_scheme":"x-api-key"}],
"retry":{"network":1,"server":1},"cooldown_seconds":{"network":1,"auth":1,"quota":1,"rate_limit":1,"server":1,"stream":30}}
EOF
printf '%s\n' '{"active":true,"mode":"auto","cooldowns":{},"current_provider":null,"last_transition":null}' >"$TMP/home/state.json"

PM_PROVIDER_HOME="$TMP/home" PM_PROVIDER_KEYCHAIN_DIR="$TMP/keys" PM_PROVIDER_BACKOFF_MS="$router_backoff_ms" \
  node "$ROUTER" >"$TMP/router.log" 2>&1 &
router_pid=$!; PIDS="$PIDS $router_pid"
wait_router

if [ "$FILTER" = stream ]; then
  run_stream_tests
  assert_state_safe
  for secret in upstream-minimax-secret upstream-glm-secret upstream-deepseek-secret local-secret-token PROMPT_MARKER_DO_NOT_LEAK; do
    ! grep -R -F "$secret" "$TMP" --exclude='minimax' --exclude='glm' --exclude='deepseek' --exclude='router-local' >/dev/null 2>&1 ||
      fail "secret leaked: $secret"
  done
  printf 'provider router stream tests: PASS\n'
  exit 0
fi

# Healthy priority and path/query/header/model preservation.
request '/v1/messages?trace=1'; assert_case 200 minimax MiniMax-M3

# Quota fallback through each provider.
write_scenario minimax '[{"status":402,"body":{"error":{"type":"quota"}}}]'
write_scenario glm '[{"status":402,"body":{"error":{"type":"quota"}}}]'
write_scenario deepseek '[{"status":200,"body":{"ok":"deepseek"}}]'
restart_router
request '/v1/messages?trace=1'; assert_case 200 deepseek deepseek-v4-pro

# A single MiniMax quota failure lands on GLM.
write_scenario minimax '[{"status":402,"body":{"error":{"type":"quota"}}}]'
write_scenario glm '[{"status":200,"body":{"ok":"glm"}}]'; write_scenario deepseek '[]'
restart_router
request '/v1/messages?trace=1'; assert_case 200 glm glm-5.2

# Context errors and other request 4xx are returned unchanged, without fallback.
write_scenario minimax '[{"status":400,"body":{"error":{"type":"invalid_request_error","code":"model_context_window_exceeded"}}}]'
write_scenario glm '[]'; write_scenario deepseek '[]'
restart_router
request '/v1/messages?trace=1'; assert_case 400 minimax MiniMax-M3
[ ! -s "$TMP/glm.records" ] || fail "context error fell back"

# Other request errors also do not fall back.
write_scenario minimax '[{"status":418,"body":{"error":{"type":"invalid_request"}}}]'
write_scenario glm '[]'; write_scenario deepseek '[]'; restart_router
request '/v1/messages?trace=1'; assert_case 418 minimax MiniMax-M3
[ ! -s "$TMP/glm.records" ] || fail "request error fell back"

# Auth, rate limit, server, and network categories fall back; retryable failures retry once first.
for spec in \
  '401|{"error":{"type":"auth"}}|1' \
  '403|{"error":{"type":"auth"}}|1' \
  '429|{"error":{"type":"rate"}}|1' \
  '500|{"error":{"type":"server"}}|2' \
  '0|{}|2'
do
  status=${spec%%|*}; rest=${spec#*|}; body=${rest%%|*}; attempts=${rest##*|}
  if [ "$status" = 0 ]; then
    write_scenario minimax '[{"disconnect":true},{"disconnect":true}]'
  elif [ "$attempts" = 2 ]; then
    write_scenario minimax "[{\"status\":$status,\"body\":$body},{\"status\":$status,\"body\":$body}]"
  elif [ "$status" = 429 ]; then
    write_scenario minimax "[{\"status\":429,\"headers\":{\"retry-after\":\"5\"},\"body\":$body}]"
  else
    write_scenario minimax "[{\"status\":$status,\"body\":$body}]"
  fi
  write_scenario glm '[{"status":200,"body":{"ok":"glm"}}]'; write_scenario deepseek '[]'
  restart_router
  request '/v1/messages?trace=1'; assert_case 200 glm glm-5.2
  [ "$(wc -l <"$TMP/minimax.records" | tr -d ' ')" = "$attempts" ] || fail "wrong retry count for $status"
  if [ "$status" = 429 ]; then
    python3 - "$TMP/home/state.json" <<'PY'
import json,sys,time
s=json.load(open(sys.argv[1]))
assert s["cooldowns"]["minimax"]["reason"]=="rate_limit"
assert s["cooldowns"]["minimax"]["until"] >= int(time.time())+4
PY
  fi
done

# Manual mode never falls through and unavailable candidates produce bounded attempted IDs.
write_scenario minimax '[{"status":402,"requestId":"manual-quota-id","body":{"error":{"type":"quota"}}}]'; write_scenario glm '[]'; write_scenario deepseek '[]'
restart_router '{"active":true,"mode":"minimax","cooldowns":{},"current_provider":"minimax","last_transition":null}'
request '/v1/messages?trace=1'
python3 - "$TMP/response.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); assert r["status"]==402, r
b=json.loads(r["body"]); assert b["error"]["attempted_providers"]==["minimax"], b
assert b["error"]["category"]=="quota", b
assert b["error"]["upstream_status"]==402, b
assert b["error"]["request_id"]=="manual-quota-id", b
assert len(r["body"]) < 65536
PY
[ ! -s "$TMP/glm.records" ] || fail "manual mode fell back"

# Auto exhaustion is bounded and reports all actually attempted IDs.
write_scenario minimax "[{\"status\":401,\"expectedAuthSha256\":\"$minimax_auth_hash\",\"body\":{\"error\":{\"type\":\"authentication_error\"}}}]"
write_scenario glm "[{\"status\":402,\"expectedAuthSha256\":\"$glm_auth_hash\",\"body\":{\"error\":{\"type\":\"quota_error\"}}}]"
write_scenario deepseek "[{\"status\":429,\"requestId\":\"final-rate-id\",\"expectedAuthSha256\":\"$deepseek_auth_hash\",\"body\":{\"error\":{\"type\":\"rate_limit_error\",\"message\":\"bounded safe message\"}}}]"
restart_router
request '/v1/messages?trace=1'
python3 - "$TMP/response.json" "$TMP" <<'PY'
import json,pathlib,sys
r=json.load(open(sys.argv[1])); assert r["status"]==429, r
b=json.loads(r["body"]); assert b["error"]["attempted_providers"]==["minimax","glm","deepseek"], b
assert b["error"]["category"]=="rate_limit", b
assert b["error"]["upstream_status"]==429, b
assert b["error"]["upstream_error_type"]=="rate_limit_error", b
assert b["error"]["request_id"]=="final-rate-id", b
assert len(r["body"]) < 65536
models={"minimax":"MiniMax-M3","glm":"glm-5.2","deepseek":"deepseek-v4-pro"}
for provider in ("minimax","glm","deepseek"):
    rows=[json.loads(x) for x in (pathlib.Path(sys.argv[2])/f"{provider}.records").read_text().splitlines()]
    assert rows and all(row["auth_valid"] is True for row in rows), (provider,rows)
    assert all(row["auth_header"] == "x-api-key" for row in rows), (provider,rows)
    for row in rows:
        assert row["model"] == models[provider], row
        assert row["payload_valid"] is True, row
        assert row["host_valid"] is True, row
        assert row["content_length_valid"] is True, row
        assert row["headers"] == {
            "anthropic-version":"2023-06-01",
            "anthropic-beta":"feature-x",
            "content-type":"application/json",
            "accept":"application/json",
            "user-agent":"pm-router-test/1",
            "x-request-id":"inbound-safe-id",
        }, row
PY

# A huge final upstream error is summarized, never relayed.
write_scenario minimax '[{"status":402,"body":{}}]'
write_scenario glm '[{"status":402,"body":{}}]'
write_scenario deepseek '[{"status":429,"requestId":"huge-final-id","headers":{"content-encoding":"gzip"},"largeErrorBytes":70000,"errorType":"huge_rate_error"}]'
restart_router
request '/v1/messages?trace=1'
python3 - "$TMP/response.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); assert r["status"]==429, r
assert len(r["body"].encode()) < 65536
b=json.loads(r["body"]); assert b["error"]["upstream_error_type"]=="huge_rate_error", b
assert b["error"]["request_id"]=="huge-final-id", b
assert "XXXX" not in r["body"]
assert "PROMPT_MARKER" not in r["body"]
assert "content-encoding" not in r["headers"], r
assert int(r["headers"]["content-length"])==len(r["body"].encode()), r
PY

# Token counting uses the same model rewrite and preserves the base path.
write_scenario minimax '[{"status":200,"body":{"input_tokens":3}}]'
write_scenario glm '[]'; write_scenario deepseek '[]'; restart_router
request '/v1/messages/count_tokens?trace=1'
python3 - "$TMP/minimax.records" <<'PY'
import json,sys
r=json.loads(open(sys.argv[1]).readline())
assert r["path"]=="/anthropic/v1/messages/count_tokens?trace=1", r
assert r["model"]=="MiniMax-M3"
PY

# Auto mode skips active cooldowns and providers without a credential.
write_scenario minimax '[]'; write_scenario glm '[]'
write_scenario deepseek '[{"status":200,"body":{"ok":"deepseek"}}]'
rm "$TMP/keys/glm"
future=$(( $(date +%s) + 60 ))
restart_router "{\"active\":true,\"mode\":\"auto\",\"cooldowns\":{\"minimax\":{\"reason\":\"quota\",\"until\":$future}},\"current_provider\":null,\"last_transition\":null}"
request '/v1/messages?trace=1'; assert_case 200 deepseek deepseek-v4-pro
[ ! -s "$TMP/minimax.records" ] || fail "active cooldown was not skipped"
[ ! -s "$TMP/glm.records" ] || fail "provider without key was not skipped"
printf '%s' upstream-glm-secret >"$TMP/keys/glm"

# Invalid local auth is rejected before upstream.
before=$(wc -l <"$TMP/minimax.records")
node - "$router_port" <<'NODE'
const http=require('http');
const q=http.request({host:'127.0.0.1',port:process.argv[2],path:'/v1/messages',method:'POST',
headers:{authorization:'Bearer wrong','content-type':'application/json'}},r=>{if(r.statusCode!==401)process.exit(1);r.resume()});
q.end('{}');
NODE
[ "$(wc -l <"$TMP/minimax.records")" = "$before" ] || fail "invalid local auth reached upstream"

# Inbound bodies are hard-limited.
node - "$router_port" <<'NODE'
const http=require('http');
const q=http.request({host:'127.0.0.1',port:process.argv[2],path:'/v1/messages',method:'POST',
headers:{authorization:'Bearer local-secret-token','content-type':'application/json'}},r=>{
  if(r.statusCode!==413)process.exitCode=1;r.resume();
});
q.end(Buffer.alloc(32*1024*1024+1, 32));
NODE

run_stream_tests

# Invalid critical configuration is rejected before binding.
kill "$router_pid"; wait "$router_pid" 2>/dev/null || true
mkdir "$TMP/bad-home"
printf '%s\n' '{}' >"$TMP/bad-home/state.json"
assert_bad_config() {
  label=$1 mutation=$2
  python3 - "$TMP/home/config.json" "$TMP/bad-home/config.json" "$mutation" <<'PY'
import json,sys
c=json.load(open(sys.argv[1])); mutation=sys.argv[3]
if mutation=="host": c["listen"]["host"]="0.0.0.0"
elif mutation=="retry-high": c["retry"]["network"]=999
elif mutation=="retry-negative": c["retry"]["server"]=-1
elif mutation=="cooldowns-type": c["cooldown_seconds"]=[]
elif mutation=="provider-url": c["providers"][0]["base_url"]="ftp://unsafe.example"
json.dump(c,open(sys.argv[2],"w"))
PY
  PM_PROVIDER_HOME="$TMP/bad-home" PM_PROVIDER_KEYCHAIN_DIR="$TMP/keys" node "$ROUTER" >"$TMP/bad-$label.log" 2>&1 &
  bad_pid=$!
  sleep .1
  if kill -0 "$bad_pid" 2>/dev/null; then
    kill "$bad_pid" 2>/dev/null || true
    wait "$bad_pid" 2>/dev/null || true
    fail "router accepted invalid config: $label"
  fi
  wait "$bad_pid" 2>/dev/null || true
  grep -Fq 'pm-provider-router: invalid config' "$TMP/bad-$label.log" || {
    safe_log_tail "$TMP/bad-$label.log"; fail "config error was not sanitized: $label";
  }
}
assert_bad_config host host
assert_bad_config retry-high retry-high
assert_bad_config retry-negative retry-negative
assert_bad_config cooldowns-type cooldowns-type
assert_bad_config provider-url provider-url

python3 - "$TMP" <<'PY'
import json, pathlib, stat, sys
root=pathlib.Path(sys.argv[1]); state=root/"home/state.json"
assert stat.S_IMODE(state.stat().st_mode)==0o600
s=json.load(open(state)); raw=json.dumps(s)
for secret in ("upstream-minimax-secret","upstream-glm-secret","upstream-deepseek-secret","local-secret-token","PROMPT_MARKER"):
    assert secret not in raw
allowed={"active","mode","cooldowns","current_provider","last_transition"}
assert set(s)<=allowed
PY

for secret in upstream-minimax-secret upstream-glm-secret upstream-deepseek-secret local-secret-token PROMPT_MARKER_DO_NOT_LEAK; do
  ! grep -R -F "$secret" "$TMP" --exclude='minimax' --exclude='glm' --exclude='deepseek' --exclude='router-local' >/dev/null 2>&1 ||
    fail "secret leaked: $secret"
done

printf 'provider router tests: PASS\n'
