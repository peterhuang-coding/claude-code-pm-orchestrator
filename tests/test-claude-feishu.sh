#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CLI="$ROOT/.claude/skills/pm-orchestrator/scripts/claude-feishu"
CORE="$ROOT/.claude/skills/pm-orchestrator/scripts/pm_feishu.py"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/claude-feishu-test.XXXXXX")
SANDBOX=$(CDPATH= cd -- "$SANDBOX" && pwd -P)
SERVER_PID=
trap '[ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$SANDBOX"' EXIT HUP INT TERM

mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/lark-cli" <<'SH'
#!/bin/sh
if [ "${1-}" = auth ] && [ "${2-}" = status ]; then
  printf '%s\n' '{"identities":{"user":{"status":"ready","openId":"ou_test_owner"}}}'
  exit 0
fi
if [ "${1-}" = event ]; then
  echo '[event] ready event_key=im.message.receive_v1' >&2
  if [ -n "${PM_FAKE_LARK_EVENT-}" ]; then
    printf '%s\n' "$PM_FAKE_LARK_EVENT"
  fi
  while IFS= read -r _line; do :; done
fi
if [ "${1-}" = im ] && [ "${2-}" = +messages-reply ]; then
  printf '%s\n' "$*" >> "$PM_FAKE_LARK_REPLIES"
  printf '%s\n' '{"ok":true,"data":{"message_id":"om_fake_reply"}}'
  exit 0
fi
SH
chmod +x "$SANDBOX/bin/lark-cli"
cat > "$SANDBOX/bin/claude" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$PM_FAKE_CLAUDE_CALLS"
printf '%s\n' '{"type":"result","result":"远程 Claude 已执行。"}'
SH
chmod +x "$SANDBOX/bin/claude"
PATH="$SANDBOX/bin:$PATH"
export PATH

cat > "$SANDBOX/server.py" <<'PY'
import http.server
import json
import pathlib
import sys

output = pathlib.Path(sys.argv[1])
port_file = pathlib.Path(sys.argv[2])

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length).decode("utf-8")
        with output.open("a", encoding="utf-8") as stream:
            stream.write(body + "\n")
        response = json.dumps({"code": 0, "msg": "success"}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, *_args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
port_file.write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
PY

python3 "$SANDBOX/server.py" "$SANDBOX/requests.jsonl" "$SANDBOX/port" &
SERVER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ ! -s "$SANDBOX/port" ] || break
  sleep 0.1
done
[ -s "$SANDBOX/port" ] || fail "fake Feishu server did not start"
WEBHOOK="http://127.0.0.1:$(cat "$SANDBOX/port")/hook"

[ -x "$CLI" ] || fail "claude-feishu is missing or not executable"
[ -f "$CORE" ] || fail "Feishu core is missing"

feishu() {
  PM_HUB_HOME="$SANDBOX/hub" \
  PM_FEISHU_TEST_WEBHOOK="$WEBHOOK" \
  NO_PROXY="127.0.0.1,localhost" \
  no_proxy="127.0.0.1,localhost" \
  "$CLI" "$@"
}

feishu off >/dev/null
feishu status | grep -Fq 'OFF' || fail "off state was not reported"
feishu on >/dev/null
feishu status | grep -Fq 'ON' || fail "on state was not reported"

feishu configure oc_test_chat >/dev/null
PM_HUB_HOME="$SANDBOX/hub" python3 - "$ROOT" <<'PY'
import sys
import json
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root / ".claude/skills/pm-orchestrator/scripts"))
import pm_feishu

channel = json.loads((pm_feishu.runtime_dir() / "channel.json").read_text())
assert channel["owner_open_id"] == "ou_test_owner"
assert channel["boss_root"] == "/Volumes/SanDisk2TB"
PY
feishu status | grep -Fq 'Duplex offline' ||
  fail "configuration-only status was reported as live"
grep -Fq 'process_pending_once(stop_event=command_stop)' "$CLI" ||
  fail "gateway shutdown cannot cancel an active remote Claude command"

feishu test >/dev/null
grep -Fq 'Claude Feishu Gateway 测试成功' "$SANDBOX/requests.jsonl" ||
  fail "test message was not delivered"

BEFORE=$(wc -l < "$SANDBOX/requests.jsonl" | tr -d ' ')
printf 'cloud status\ncloud quit\n' | feishu > "$SANDBOX/console.out"
grep -Fq 'Gateway 已上线' "$SANDBOX/requests.jsonl" ||
  fail "bare console start did not send online message"
grep -Fq 'ON' "$SANDBOX/console.out" ||
  fail "interactive status did not share enabled state"
AFTER=$(wc -l < "$SANDBOX/requests.jsonl" | tr -d ' ')
[ "$AFTER" -gt "$BEFORE" ] || fail "console startup made no Feishu request"

PM_HUB_HOME="$SANDBOX/hub" python3 - "$ROOT" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root / ".claude/skills/pm-orchestrator/scripts"))
import pm_feishu

pm_feishu.bind_boss("boss-live", "/Volumes/SanDisk2TB")
pm_feishu.set_enabled(True)
assert pm_feishu.enqueue_hook_event({
    "hook_event_name": "Stop",
    "session_id": "boss-live",
    "cwd": "/Volumes/SanDisk2TB",
    "last_assistant_message": "老板回复已经完成",
})
PY

printf 'cloud quit\n' | feishu >/dev/null
grep -Fq '老板回复已经完成' "$SANDBOX/requests.jsonl" ||
  fail "queued boss response was not delivered"

EVENT='{"type":"im.message.receive_v1","chat_id":"oc_test_chat","chat_type":"group","message_id":"om_duplex_e2e","message_type":"text","sender_id":"ou_test_owner","sender_type":"user","content":"汇报三个项目","create_time":"1785680000000"}'
(for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
   [ ! -f "$SANDBOX/hub/runtime/feishu/inbound/processed/om_duplex_e2e.json" ] || break
   sleep 0.2
 done
 printf 'cloud quit\n') | \
  PM_HUB_HOME="$SANDBOX/hub" \
  PM_FEISHU_TEST_WEBHOOK="$WEBHOOK" \
  PM_FAKE_LARK_EVENT="$EVENT" \
  PM_FAKE_LARK_REPLIES="$SANDBOX/replies.log" \
  PM_FAKE_CLAUDE_CALLS="$SANDBOX/claude.log" \
  NO_PROXY="127.0.0.1,localhost" \
  no_proxy="127.0.0.1,localhost" \
  "$CLI" > "$SANDBOX/duplex.out"
grep -Fq '汇报三个项目' "$SANDBOX/claude.log" ||
  fail "inbound owner command did not reach Claude"
CLAUDE_CALL_COUNT=$(grep -c '^--print ' "$SANDBOX/claude.log")
if [ "$CLAUDE_CALL_COUNT" -ne 1 ]; then
  cat "$SANDBOX/claude.log" >&2
  fail "inbound owner command executed $CLAUDE_CALL_COUNT times"
fi
grep -Fq '已收到' "$SANDBOX/replies.log" ||
  fail "inbound command was not acknowledged"
grep -Fq '远程 Claude 已执行' "$SANDBOX/replies.log" ||
  fail "Claude result was not replied to the source Feishu message"
find "$SANDBOX/hub/runtime/feishu/inbound/processed" -name 'om_duplex_e2e.json' \
  -print -quit | grep -q . || fail "inbound command was not durably completed"

feishu off >/dev/null
echo "PASS: Claude Feishu CLI and fake webhook"
