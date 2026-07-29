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

feishu off >/dev/null
echo "PASS: Claude Feishu CLI and fake webhook"
