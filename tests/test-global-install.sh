#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
INSTALLER="$SCRIPT_DIR/../.claude/skills/pm-orchestrator/scripts/install-global.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -x "$INSTALLER" ] || fail "install-global.sh is missing or not executable"

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/pm-global-install-test.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
HOME_DIR="$SANDBOX/home"
TARGET="$HOME_DIR/.claude"
mkdir -p "$TARGET"
printf '%s\n' '{"env":{"KEEP_ME":"yes"}}' > "$TARGET/settings.json"
cp "$TARGET/settings.json" "$SANDBOX/settings.before"

HOME="$HOME_DIR" "$INSTALLER"

cmp -s "$SANDBOX/settings.before" "$TARGET/settings.json" || fail "installer changed settings.json"
[ -x "$TARGET/skills/pm-orchestrator/scripts/pm-handoff.sh" ] || fail "handoff tool was not installed"
[ -x "$TARGET/skills/pm-orchestrator/scripts/pm-goal.sh" ] || fail "goal tool was not installed"
[ -x "$TARGET/skills/pm-orchestrator/scripts/pm-loop.sh" ] || fail "loop tool was not installed"
[ -x "$TARGET/skills/pm-orchestrator/scripts/launch-claude-glm.sh" ] || fail "launcher was not installed"
[ -x "$TARGET/skills/pm-orchestrator/scripts/install-global.sh" ] || fail "installer was not installed"
[ -f "$TARGET/commands/leader-task.md" ] || fail "leader-task command was not installed"
[ -f "$TARGET/commands/leader-resume.md" ] || fail "leader-resume command was not installed"
[ -f "$TARGET/commands/goal.md" ] || fail "goal command was not installed"
[ -f "$TARGET/agents/dev-agent.md" ] || fail "agents were not installed"
[ -f "$TARGET/templates/leader-handoff.md" ] || fail "templates were not installed"

echo "PASS: global Claude install"
