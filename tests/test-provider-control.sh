#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PROVIDER_TOOL="$REPO_ROOT/.claude/skills/pm-orchestrator/scripts/pm-provider.py"
CONFIG_TEMPLATE="$REPO_ROOT/.claude/templates/provider-router-config.json"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -f "$PROVIDER_TOOL" ] || fail "provider control script is missing"
[ -f "$CONFIG_TEMPLATE" ] || fail "provider router config template is missing"

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/pm-provider-test.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
export HOME="$SANDBOX/home"
export PM_PROVIDER_HOME="$SANDBOX/provider-home"
export PM_PROVIDER_KEYCHAIN_DIR="$SANDBOX/fake-keychain"
mkdir -p "$HOME"

SECRET_MINIMAX='  test-secret-minimax-7T8vQ  '
SECRET_GLM='test-secret-glm-4J2pK'
SECRET_DEEPSEEK='test-secret-deepseek-9N6xM'
COMMAND_STDOUT="$SANDBOX/commands.stdout"
COMMAND_STDERR="$SANDBOX/commands.stderr"
: >"$COMMAND_STDOUT"
: >"$COMMAND_STDERR"

run_provider() {
  python3 "$PROVIDER_TOOL" "$@"
}

assert_mode_600() {
  mode=$(stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1")
  [ "$mode" = "600" ] || fail "$1 has mode $mode instead of 600"
}

assert_no_secrets() {
  target=$1
  for secret in "$SECRET_MINIMAX" "$SECRET_GLM" "$SECRET_DEEPSEEK"; do
    if [ -d "$target" ]; then
      ! grep -R -F "$secret" "$target" >/dev/null 2>&1 ||
        fail "secret leaked under $target"
    elif [ -e "$target" ]; then
      ! grep -F "$secret" "$target" >/dev/null 2>&1 ||
        fail "secret leaked into $target"
    fi
  done
}

KEYCHAIN_ERROR="$SANDBOX/keychain-error.txt"
if ! python3 - "$PROVIDER_TOOL" "$SECRET_MINIMAX" >"$KEYCHAIN_ERROR" 2>&1 <<'PY'
import contextlib
import importlib.util
import io
import os
import subprocess
import sys

tool_path, secret = sys.argv[1:]
os.environ.pop("PM_PROVIDER_KEYCHAIN_DIR", None)
spec = importlib.util.spec_from_file_location("pm_provider", tool_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

def expect_sanitized_failure(callback, expected):
    stdout = io.StringIO()
    stderr = io.StringIO()
    try:
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            callback()
    except SystemExit:
        pass
    else:
        raise AssertionError("simulated security failure unexpectedly succeeded")
    combined = stdout.getvalue() + stderr.getvalue()
    assert secret not in combined
    assert expected in stderr.getvalue()
    assert "Traceback" not in combined

def fake_security(arguments, **kwargs):
    assert kwargs["stdout"] is subprocess.PIPE
    assert kwargs["stderr"] is subprocess.PIPE
    return subprocess.CompletedProcess(arguments, 0, stdout="", stderr="")

module.subprocess.run = fake_security
module.store_credential("minimax", secret)
expected_store_argv = [
    "/usr/bin/security",
    "add-generic-password",
    "-U",
    "-s",
    module.SERVICE,
    "-a",
    "minimax",
    "-w",
]

recorded = {}
def recording_store(arguments, **kwargs):
    recorded["argv"] = arguments
    recorded["stdin"] = kwargs.get("input")
    assert kwargs["stdout"] is subprocess.PIPE
    assert kwargs["stderr"] is subprocess.PIPE
    return subprocess.CompletedProcess(arguments, 0, stdout="", stderr="")

module.subprocess.run = recording_store
module.store_credential("minimax", secret)
assert recorded["argv"] == expected_store_argv
assert secret not in recorded["argv"]
assert recorded["stdin"] == secret + "\n"

def security_failure(arguments, **kwargs):
    assert kwargs["stdout"] is subprocess.PIPE
    assert kwargs["stderr"] is subprocess.PIPE
    return subprocess.CompletedProcess(arguments, 50, stdout=secret, stderr=secret)

module.subprocess.run = security_failure
expect_sanitized_failure(
    lambda: module.store_credential("minimax", secret),
    "pm-provider: could not store credential for minimax",
)

def find_not_found(arguments, **kwargs):
    assert arguments[1] == "find-generic-password"
    assert kwargs["stdout"] is subprocess.PIPE
    assert kwargs["stderr"] is subprocess.PIPE
    return subprocess.CompletedProcess(arguments, 44, stdout=secret, stderr=secret)

module.subprocess.run = find_not_found
assert module.credential_is_configured("minimax") is False

module.subprocess.run = security_failure
expect_sanitized_failure(
    lambda: module.credential_is_configured("minimax"),
    "pm-provider: could not query credential for minimax",
)

delete_operations = []
def delete_not_found(arguments, **kwargs):
    delete_operations.append(arguments[1])
    assert kwargs["stdout"] is subprocess.PIPE
    assert kwargs["stderr"] is subprocess.PIPE
    if arguments[1] == "find-generic-password":
        return subprocess.CompletedProcess(arguments, 0, stdout=secret, stderr=secret)
    return subprocess.CompletedProcess(arguments, 44, stdout=secret, stderr=secret)

module.subprocess.run = delete_not_found
module.remove_credential("minimax")
assert delete_operations == ["delete-generic-password"]

module.subprocess.run = security_failure
expect_sanitized_failure(
    lambda: module.remove_credential("minimax"),
    "pm-provider: could not remove credential for minimax",
)
PY
then
  fail "production security boundary test failed"
fi
assert_no_secrets "$KEYCHAIN_ERROR"

python3 - "$CONFIG_TEMPLATE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    config = json.load(stream)

assert config["version"] == 1
assert config["listen"] == {"host": "127.0.0.1", "port": 41937}
assert config["providers"] == [
    {
        "id": "minimax",
        "base_url": "https://api.minimaxi.com/anthropic",
        "model": "MiniMax-M3",
        "auth_scheme": "bearer",
    },
    {
        "id": "glm",
        "base_url": "https://api.sfkey.cn",
        "model": "glm-5.2",
        "auth_scheme": "bearer",
    },
    {
        "id": "deepseek",
        "base_url": "https://api.deepseek.com/anthropic",
        "model": "deepseek-v4-pro",
        "auth_scheme": "bearer",
    },
]
assert config["retry"] == {"network": 2, "server": 2}
assert config["cooldown_seconds"] == {
    "network": 300,
    "auth": 21600,
    "quota": 86400,
    "rate_limit": 1800,
    "server": 300,
    "stream": 300,
}
PY

printf '%s\n' "$SECRET_MINIMAX" |
  run_provider set minimax >"$SANDBOX/set-minimax.out" 2>>"$COMMAND_STDERR"
printf '%s\n' "$SECRET_GLM" |
  run_provider set glm >"$SANDBOX/set-glm.out" 2>>"$COMMAND_STDERR"
printf '%s\n' "$SECRET_DEEPSEEK" |
  run_provider set deepseek >"$SANDBOX/set-deepseek.out" 2>>"$COMMAND_STDERR"

STATUS_JSON="$SANDBOX/status.json"
run_provider status --json >"$STATUS_JSON" 2>>"$COMMAND_STDERR"
python3 - "$STATUS_JSON" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    status = json.load(stream)

assert status["active"] is False
assert status["mode"] == "auto"
assert status["current_provider"] is None
assert status["cooldowns"] == {}
assert status["last_transition"] is None
assert list(status["providers"]) == ["minimax", "glm", "deepseek"]
assert all(item["configured"] is True for item in status["providers"].values())
PY

run_provider status >"$SANDBOX/status.txt" 2>>"$COMMAND_STDERR"
grep -Fq 'minimax' "$SANDBOX/status.txt" || fail "human status omitted minimax"
grep -Fq 'configured' "$SANDBOX/status.txt" || fail "human status omitted configuration state"
grep -Fq 'last transition: none' "$SANDBOX/status.txt" ||
  fail "human status omitted last_transition"

[ -f "$PM_PROVIDER_HOME/config.json" ] || fail "public config was not initialized"
[ -f "$PM_PROVIDER_HOME/state.json" ] || fail "state was not initialized"
cmp -s "$CONFIG_TEMPLATE" "$PM_PROVIDER_HOME/config.json" ||
  fail "initialized config differs from the repo template"
assert_mode_600 "$PM_PROVIDER_HOME/config.json"
assert_mode_600 "$PM_PROVIDER_HOME/state.json"

for provider in minimax glm deepseek; do
  key_file="$PM_PROVIDER_KEYCHAIN_DIR/$provider"
  [ -f "$key_file" ] || fail "fake Keychain file missing for $provider"
  assert_mode_600 "$key_file"
done
python3 - "$PM_PROVIDER_KEYCHAIN_DIR" \
  "$SECRET_MINIMAX" "$SECRET_GLM" "$SECRET_DEEPSEEK" <<'PY'
from pathlib import Path
import sys

keychain = Path(sys.argv[1])
for provider, expected in zip(("minimax", "glm", "deepseek"), sys.argv[2:]):
    assert (keychain / provider).read_bytes() == expected.encode("utf-8")
PY

assert_no_secrets "$PM_PROVIDER_HOME"
assert_no_secrets "$SANDBOX/set-minimax.out"
assert_no_secrets "$SANDBOX/set-glm.out"
assert_no_secrets "$SANDBOX/set-deepseek.out"
assert_no_secrets "$STATUS_JSON"
assert_no_secrets "$SANDBOX/status.txt"

! run_provider status extra >>"$COMMAND_STDOUT" 2>>"$COMMAND_STDERR" ||
  fail "status accepted an extra argument"
! run_provider set unknown </dev/null >>"$COMMAND_STDOUT" 2>>"$COMMAND_STDERR" ||
  fail "set accepted an invalid provider"
! run_provider remove unknown >>"$COMMAND_STDOUT" 2>>"$COMMAND_STDERR" ||
  fail "remove accepted an invalid provider"
! run_provider use unknown >>"$COMMAND_STDOUT" 2>>"$COMMAND_STDERR" ||
  fail "use accepted an invalid provider"
! run_provider reset unknown >>"$COMMAND_STDOUT" 2>>"$COMMAND_STDERR" ||
  fail "reset accepted an invalid provider"
! printf '\n' |
  run_provider set minimax >>"$COMMAND_STDOUT" 2>>"$COMMAND_STDERR" ||
  fail "set accepted an empty key"

run_provider use glm >>"$COMMAND_STDOUT" 2>>"$COMMAND_STDERR"
python3 - "$PM_PROVIDER_HOME/state.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    state = json.load(stream)
assert state["active"] is True
assert state["mode"] == "glm"
assert state["current_provider"] == "glm"
PY

python3 - "$PM_PROVIDER_HOME/state.json" <<'PY'
import json
import os
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    state = json.load(stream)
state["cooldowns"] = {"glm": {"reason": "server", "until": 4102444800}}
temp = path + ".test-tmp"
with open(temp, "w", encoding="utf-8") as stream:
    json.dump(state, stream)
    stream.flush()
    os.fsync(stream.fileno())
os.chmod(temp, 0o600)
os.replace(temp, path)
PY

run_provider reset glm >>"$COMMAND_STDOUT" 2>>"$COMMAND_STDERR"
python3 - "$PM_PROVIDER_HOME/state.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    state = json.load(stream)
assert "glm" not in state["cooldowns"]
assert state["mode"] == "glm"
PY

run_provider use auto >>"$COMMAND_STDOUT" 2>>"$COMMAND_STDERR"
run_provider reset >>"$COMMAND_STDOUT" 2>>"$COMMAND_STDERR"
python3 - "$PM_PROVIDER_HOME/state.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    state = json.load(stream)
assert state["active"] is True
assert state["mode"] == "auto"
assert state["cooldowns"] == {}
assert state["current_provider"] is None
assert state["last_transition"] is None
PY

python3 - "$PM_PROVIDER_HOME/config.json" <<'PY'
import json
import os
import socket
import sys

path = sys.argv[1]
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
with open(path, encoding="utf-8") as stream:
    config = json.load(stream)
config["listen"]["port"] = port
temporary = path + ".test-tmp"
with open(temporary, "w", encoding="utf-8") as stream:
    json.dump(config, stream, indent=2)
    stream.write("\n")
    stream.flush()
    os.fsync(stream.fileno())
os.chmod(temporary, 0o600)
os.replace(temporary, path)
PY

python3 - "$PM_PROVIDER_HOME/state.json" <<'PY'
import json
import os
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    state = json.load(stream)
state["cooldowns"] = {
    "minimax": {"reason": "quota", "until": 4102444800},
    "glm": {"reason": "server", "until": 4102444800},
}
temporary = path + ".test-tmp"
with open(temporary, "w", encoding="utf-8") as stream:
    json.dump(state, stream, indent=2)
    stream.write("\n")
    stream.flush()
    os.fsync(stream.fileno())
os.chmod(temporary, 0o600)
os.replace(temporary, path)
PY

if ! run_provider ensure >"$SANDBOX/ensure-first.stdout" \
  2>"$SANDBOX/ensure-first.stderr"; then
  cat "$SANDBOX/ensure-first.stderr" >&2
  [ ! -f "$PM_PROVIDER_HOME/router.log" ] ||
    cat "$PM_PROVIDER_HOME/router.log" >&2
  fail "provider ensure is unsupported"
fi

PID_FILE="$PM_PROVIDER_HOME/router.pid"
LOG_FILE="$PM_PROVIDER_HOME/router.log"
[ -f "$PID_FILE" ] || fail "ensure did not create a PID file"
[ -f "$LOG_FILE" ] || fail "ensure did not create an operational log"
assert_mode_600 "$PID_FILE"
assert_mode_600 "$LOG_FILE"
FIRST_PID=$(python3 - "$PID_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    value = json.load(stream)
assert isinstance(value["pid"], int) and value["pid"] > 1
assert isinstance(value["instance_id"], str) and value["instance_id"]
print(value["pid"])
PY
)
kill -0 "$FIRST_PID" 2>/dev/null || fail "ensure daemon is not alive"

run_provider ensure >"$SANDBOX/ensure-second.stdout" \
  2>"$SANDBOX/ensure-second.stderr"
SECOND_PID=$(python3 - "$PID_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    print(json.load(stream)["pid"])
PY
)
[ "$FIRST_PID" = "$SECOND_PID" ] || fail "ensure restarted a healthy daemon"

run_provider status --json >"$SANDBOX/daemon-status.json" \
  2>>"$COMMAND_STDERR"
python3 - "$SANDBOX/daemon-status.json" "$FIRST_PID" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    status = json.load(stream)
assert status["daemon"] == {"running": True, "pid": int(sys.argv[2])}
assert status["mode"] == "auto"
assert status["current_provider"] is None
PY

run_provider use glm >>"$COMMAND_STDOUT" 2>>"$COMMAND_STDERR"
THIRD_PID=$(python3 - "$PID_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    print(json.load(stream)["pid"])
PY
)
[ "$FIRST_PID" = "$THIRD_PID" ] || fail "use glm restarted the daemon"
run_provider status --json >"$SANDBOX/glm-status.json" \
  2>>"$COMMAND_STDERR"
python3 - "$SANDBOX/glm-status.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    status = json.load(stream)
assert status["mode"] == "glm"
assert status["current_provider"] == "glm"
PY

run_provider reset minimax >>"$COMMAND_STDOUT" 2>>"$COMMAND_STDERR"
run_provider status --json >"$SANDBOX/reset-status.json" \
  2>>"$COMMAND_STDERR"
python3 - "$SANDBOX/reset-status.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    status = json.load(stream)
assert "minimax" not in status["cooldowns"]
assert status["cooldowns"]["glm"]["reason"] == "server"
PY

run_provider exec python3 -c '
import os
from pathlib import Path
assert os.environ["ANTHROPIC_BASE_URL"].startswith("http://127.0.0.1:")
assert os.environ["ANTHROPIC_AUTH_TOKEN"] == Path(
    os.environ["PM_PROVIDER_KEYCHAIN_DIR"], "router-local"
).read_text()
for name in (
    "ANTHROPIC_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
):
    assert os.environ[name] == "pm-auto"
' >>"$COMMAND_STDOUT" 2>>"$COMMAND_STDERR"

LOCAL_TOKEN=$(cat "$PM_PROVIDER_KEYCHAIN_DIR/router-local")
[ -n "$LOCAL_TOKEN" ] || fail "ensure stored an empty router-local credential"
assert_mode_600 "$PM_PROVIDER_KEYCHAIN_DIR/router-local"
! grep -R -F "$LOCAL_TOKEN" "$PM_PROVIDER_HOME" >/dev/null 2>&1 ||
  fail "router-local credential leaked under provider home"
assert_no_secrets "$PM_PROVIDER_HOME"

run_provider stop >"$SANDBOX/stop.stdout" 2>"$SANDBOX/stop.stderr"
if kill -0 "$FIRST_PID" 2>/dev/null; then
  fail "stop left the owned daemon alive"
fi
[ ! -e "$PID_FILE" ] || fail "stop left the PID file behind"
run_provider status --json >"$SANDBOX/stopped-status.json" \
  2>>"$COMMAND_STDERR"
python3 - "$SANDBOX/stopped-status.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    status = json.load(stream)
assert status["daemon"] == {"running": False, "pid": None}
PY

sleep 30 &
UNRELATED_PID=$!
python3 - "$PID_FILE" "$UNRELATED_PID" <<'PY'
import json
import os
import sys

path, pid = sys.argv[1:]
with open(path, "w", encoding="utf-8") as stream:
    json.dump({"pid": int(pid), "instance_id": "not-the-router"}, stream)
    stream.write("\n")
os.chmod(path, 0o600)
PY
if run_provider ensure >"$SANDBOX/unrelated.stdout" \
  2>"$SANDBOX/unrelated.stderr"; then
  kill "$UNRELATED_PID" 2>/dev/null || true
  fail "ensure accepted an unrelated live PID"
fi
grep -Fq 'refusing unrelated live process' "$SANDBOX/unrelated.stderr" ||
  fail "unrelated live PID failure was not explicit"
kill "$UNRELATED_PID" 2>/dev/null || true
wait "$UNRELATED_PID" 2>/dev/null || true
rm -f "$PID_FILE"

run_provider remove minimax >>"$COMMAND_STDOUT" 2>>"$COMMAND_STDERR"
run_provider remove minimax >>"$COMMAND_STDOUT" 2>>"$COMMAND_STDERR"
run_provider status --json >"$STATUS_JSON" 2>>"$COMMAND_STDERR"
python3 - "$STATUS_JSON" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    status = json.load(stream)
assert status["providers"]["minimax"]["configured"] is False
assert status["providers"]["glm"]["configured"] is True
assert status["providers"]["deepseek"]["configured"] is True
PY

assert_no_secrets "$PM_PROVIDER_HOME"
assert_no_secrets "$STATUS_JSON"
assert_no_secrets "$COMMAND_STDOUT"
assert_no_secrets "$COMMAND_STDERR"
assert_mode_600 "$PM_PROVIDER_HOME/config.json"
assert_mode_600 "$PM_PROVIDER_HOME/state.json"

ERROR_KEYCHAIN="$SANDBOX/error-keychain"
mkdir -p "$ERROR_KEYCHAIN"
: >"$ERROR_KEYCHAIN/.find-error-minimax"
if PM_PROVIDER_KEYCHAIN_DIR="$ERROR_KEYCHAIN" run_provider status \
  >"$SANDBOX/find-error.stdout" 2>"$SANDBOX/find-error.stderr"; then
  fail "fake Keychain find error was reported as an unconfigured provider"
fi
grep -Fq 'pm-provider: could not query credential for minimax' \
  "$SANDBOX/find-error.stderr" || fail "fake Keychain find error was not sanitized"
! grep -Fq 'Traceback' "$SANDBOX/find-error.stderr" ||
  fail "fake Keychain find error emitted a traceback"

rm "$ERROR_KEYCHAIN/.find-error-minimax"
: >"$ERROR_KEYCHAIN/.delete-error-minimax"
if PM_PROVIDER_KEYCHAIN_DIR="$ERROR_KEYCHAIN" run_provider remove minimax \
  >"$SANDBOX/delete-error.stdout" 2>"$SANDBOX/delete-error.stderr"; then
  fail "fake Keychain delete error was reported as success"
fi
grep -Fq 'pm-provider: could not remove credential for minimax' \
  "$SANDBOX/delete-error.stderr" || fail "fake Keychain delete error was not sanitized"
! grep -Fq 'Traceback' "$SANDBOX/delete-error.stderr" ||
  fail "fake Keychain delete error emitted a traceback"

INVALID_KEYCHAIN="$SANDBOX/keychain-is-a-file"
printf '%s\n' 'not a directory' >"$INVALID_KEYCHAIN"
if printf '%s\n' "$SECRET_MINIMAX" |
  PM_PROVIDER_KEYCHAIN_DIR="$INVALID_KEYCHAIN" run_provider set minimax \
    >"$SANDBOX/io-error.stdout" 2>"$SANDBOX/io-error.stderr"; then
  fail "invalid fake Keychain storage was reported as success"
fi
grep -Fq 'pm-provider: could not store credential for minimax' \
  "$SANDBOX/io-error.stderr" || fail "fake Keychain I/O error was not sanitized"
! grep -Fq 'Traceback' "$SANDBOX/io-error.stderr" ||
  fail "fake Keychain I/O error emitted a traceback"

INVALID_HOME="$SANDBOX/provider-home-is-a-file"
printf '%s\n' 'not a directory' >"$INVALID_HOME"
if PM_PROVIDER_HOME="$INVALID_HOME" run_provider status \
  >"$SANDBOX/home-error.stdout" 2>"$SANDBOX/home-error.stderr"; then
  fail "invalid provider home was reported as success"
fi
grep -Fq 'pm-provider: could not initialize config' \
  "$SANDBOX/home-error.stderr" || fail "provider home I/O error was not sanitized"
! grep -Fq 'Traceback' "$SANDBOX/home-error.stderr" ||
  fail "provider home I/O error emitted a traceback"

for stream in \
  "$SANDBOX/find-error.stdout" "$SANDBOX/find-error.stderr" \
  "$SANDBOX/delete-error.stdout" "$SANDBOX/delete-error.stderr" \
  "$SANDBOX/io-error.stdout" "$SANDBOX/io-error.stderr" \
  "$SANDBOX/home-error.stdout" "$SANDBOX/home-error.stderr"; do
  assert_no_secrets "$stream"
done

echo "PASS: provider control, Keychain, and daemon lifecycle"
