#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HOOK="$ROOT/.claude/skills/pm-orchestrator/scripts/pm-session-start.py"
CONFIGURE="$ROOT/.claude/skills/pm-orchestrator/scripts/configure-claude-user.py"
HUB_TOOL="$ROOT/.claude/skills/pm-orchestrator/scripts/pm-hub.sh"
FEATURE_TOOL="$ROOT/.claude/skills/pm-orchestrator/scripts/pm-feature.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -f "$HOOK" ] || fail "SessionStart hook is missing"
[ -f "$CONFIGURE" ] || fail "user configurator is missing"

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/pm-session-start-test.XXXXXX")
SANDBOX=$(CDPATH= cd -- "$SANDBOX" && pwd -P)
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
HUB="$SANDBOX/hub"
PROJECT="$SANDBOX/project"
UNKNOWN="$SANDBOX/unknown"
SETTINGS="$SANDBOX/settings.json"
DEFAULT_SETTINGS="$SANDBOX/default-settings.json"
mkdir -p "$PROJECT" "$UNKNOWN"

PM_HUB_HOME="$HUB" "$HUB_TOOL" init >/dev/null
PM_HUB_HOME="$HUB" "$HUB_TOOL" register "$PROJECT" sample >/dev/null
cat > "$SANDBOX/brief.md" <<'EOF'
# Tracked cold start

- Acceptance: visible in the next session
EOF
FEATURE_ID=$(PM_HUB_HOME="$HUB" PM_HUB_TOOL="$HUB_TOOL" \
  "$FEATURE_TOOL" new tracked-cold-start "$SANDBOX/brief.md" "$PROJECT")

PROJECT_OUT=$(printf '{"hook_event_name":"SessionStart","source":"startup","cwd":"%s","model":"test-model","session_id":"s1"}\n' "$PROJECT" |
  PM_HUB_HOME="$HUB" PM_HUB_TOOL="$HUB_TOOL" python3 "$HOOK")
printf '%s' "$PROJECT_OUT" | grep -Fq '"hookEventName": "SessionStart"' || fail "hook output shape is invalid"
printf '%s' "$PROJECT_OUT" | grep -Fq '"reloadSkills": true' || fail "hook does not reload Skills"
printf '%s' "$PROJECT_OUT" | grep -Fq '"sessionTitle": "PM: sample"' || fail "project session title missing"
printf '%s' "$PROJECT_OUT" | grep -Fq 'sample' || fail "project context missing"
printf '%s' "$PROJECT_OUT" | grep -Fq "$FEATURE_ID" || fail "active Feature missing from cold start"
[ "${#PROJECT_OUT}" -le 16000 ] || fail "SessionStart output is unbounded"

AGENT_OUT=$(printf '{"hook_event_name":"SessionStart","source":"startup","cwd":"%s","agent_type":"review","session_id":"s-agent"}\n' "$PROJECT" |
  PM_HUB_HOME="$HUB" PM_HUB_TOOL="$HUB_TOOL" python3 "$HOOK")
[ "$AGENT_OUT" = "{}" ] || fail "subagent received lead-session cold start instructions"

UNKNOWN_OUT=$(printf '{"hook_event_name":"SessionStart","source":"startup","cwd":"%s","model":"test-model","session_id":"s2"}\n' "$UNKNOWN" |
  PM_HUB_HOME="$HUB" PM_HUB_TOOL="$HUB_TOOL" python3 "$HOOK")
[ "$UNKNOWN_OUT" = "{}" ] || fail "unknown directory should not receive PM context"

cat > "$SETTINGS" <<'EOF'
{
  "env": {
    "ANTHROPIC_MODEL": "keep-model",
    "ANTHROPIC_AUTH_TOKEN": "keep-secret",
    "CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY": "7"
  },
  "permissions": {
    "allow": ["Bash(git status)"]
  }
}
EOF

PM_CLAUDE_SETTINGS="$SETTINGS" python3 "$CONFIGURE"
cp "$SETTINGS" "$SANDBOX/settings.once"
PM_CLAUDE_SETTINGS="$SETTINGS" python3 "$CONFIGURE"
cmp -s "$SETTINGS" "$SANDBOX/settings.once" || fail "configurator is not idempotent"

python3 - "$SETTINGS" <<'PY' || fail "Feishu managed hooks are incomplete"
import json
import sys

settings = json.load(open(sys.argv[1], encoding="utf-8"))
hooks = settings.get("hooks", {})
for event in ("SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "Notification"):
    managed = [
        hook
        for group in hooks.get(event, [])
        for hook in group.get("hooks", [])
        if "pm-feishu-hook.py" in hook.get("command", "")
    ]
    if len(managed) != 1:
        raise SystemExit(f"{event}: expected one Feishu hook, got {managed}")
    hook = managed[0]
    if event in ("SessionStart", "UserPromptSubmit"):
        if hook.get("async") is True or hook.get("timeout", 99) > 2:
            raise SystemExit(f"{event}: state-changing hook is not bounded and ordered")
    elif hook.get("async") is not True or hook.get("timeout", 99) > 5:
        raise SystemExit(f"{event}: notification hook is not bounded and async")
PY

printf '{}\n' > "$DEFAULT_SETTINGS"
PM_CLAUDE_SETTINGS="$DEFAULT_SETTINGS" python3 "$CONFIGURE" &
PID_CONFIG_1=$!
PM_CLAUDE_SETTINGS="$DEFAULT_SETTINGS" python3 "$CONFIGURE" &
PID_CONFIG_2=$!
wait "$PID_CONFIG_1"
wait "$PID_CONFIG_2"

python3 - "$SETTINGS" "$HOOK" "$DEFAULT_SETTINGS" <<'PY'
import json
import sys
from pathlib import Path

settings = json.loads(Path(sys.argv[1]).read_text())
assert settings["env"]["ANTHROPIC_MODEL"] == "keep-model"
assert settings["env"]["ANTHROPIC_AUTH_TOKEN"] == "keep-secret"
assert settings["env"]["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] == "1"
assert settings["env"]["CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY"] == "7"
assert settings["permissions"]["defaultMode"] == "bypassPermissions"
assert settings["permissions"]["allow"] == ["Bash(git status)"]
assert settings["teammateMode"] == "in-process"
hooks = settings["hooks"]["SessionStart"]
commands = [h["command"] for group in hooks for h in group["hooks"]]
assert len(commands) == 2
assert any(str(Path(sys.argv[2]).resolve()) in command for command in commands)
assert any("pm-feishu-hook.py" in command for command in commands)
defaults = json.loads(Path(sys.argv[3]).read_text())
assert defaults["env"]["CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY"] == "12"
PY

echo "PASS: SessionStart cold start and user config"
