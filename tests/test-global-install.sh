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
GLOBAL_BIN="$SANDBOX/global-bin"
mkdir -p "$TARGET"
mkdir -p "$TARGET/skills/pm-orchestrator/scripts"
printf '%s\n' 'legacy launcher' > "$TARGET/skills/pm-orchestrator/scripts/launch-claude-glm.sh"
printf '%s\n' 'legacy launcher' > "$TARGET/skills/pm-orchestrator/scripts/launch-claude-deepseek.sh"
printf '%s\n' '{"env":{"KEEP_ME":"yes"}}' > "$TARGET/settings.json"
cp "$TARGET/settings.json" "$SANDBOX/settings.before"

HOME="$HOME_DIR" PM_GLOBAL_BIN="$GLOBAL_BIN" "$INSTALLER"

cmp -s "$SANDBOX/settings.before" "$TARGET/settings.json" || fail "installer changed settings.json"
[ -x "$TARGET/skills/pm-orchestrator/scripts/pm-handoff.sh" ] || fail "handoff tool was not installed"
[ -x "$TARGET/skills/pm-orchestrator/scripts/pm-goal.sh" ] || fail "goal tool was not installed"
[ -x "$TARGET/skills/pm-orchestrator/scripts/pm-loop.sh" ] || fail "loop tool was not installed"
[ -x "$TARGET/skills/pm-orchestrator/scripts/launch-claude.sh" ] || fail "neutral launcher was not installed"
[ -x "$TARGET/skills/pm-orchestrator/scripts/claude-pm" ] || fail "Claude PM entrypoint was not installed"
[ -x "$TARGET/skills/pm-orchestrator/scripts/claude-yolo" ] || fail "Claude YOLO entrypoint was not installed"
[ -x "$TARGET/bin/claude-pm" ] || fail "short Claude PM entrypoint was not installed"
[ -x "$TARGET/bin/claude-yolo" ] || fail "short Claude YOLO entrypoint was not installed"
SOURCE_YOLO=$(CDPATH= cd -- "$SCRIPT_DIR/../.claude/skills/pm-orchestrator/scripts" && pwd -P)/claude-yolo
[ "$(readlink "$TARGET/bin/claude-yolo")" = "$SOURCE_YOLO" ] || fail "Claude YOLO entrypoint does not point to source package"
[ -x "$TARGET/bin/claude-feishu" ] || fail "Claude Feishu entrypoint was not installed"
SOURCE_FEISHU=$(CDPATH= cd -- "$SCRIPT_DIR/../.claude/skills/pm-orchestrator/scripts" && pwd -P)/claude-feishu
[ "$(readlink "$TARGET/bin/claude-feishu")" = "$SOURCE_FEISHU" ] || fail "Claude Feishu entrypoint does not point to source package"
[ -x "$GLOBAL_BIN/claude-yolo" ] || fail "shell-visible Claude YOLO entrypoint was not installed"
[ -x "$GLOBAL_BIN/claude-feishu" ] || fail "shell-visible Claude Feishu entrypoint was not installed"
[ -x "$TARGET/skills/pm-orchestrator/scripts/pm-feishu-hook.py" ] || fail "Feishu hook was not installed"
[ -f "$TARGET/skills/pm-orchestrator/scripts/pm_feishu.py" ] || fail "Feishu core was not installed"
[ -x "$TARGET/skills/pm-orchestrator/scripts/pm-hub.sh" ] || fail "Hub tool was not installed"
[ ! -e "$TARGET/skills/pm-orchestrator/scripts/launch-claude-glm.sh" ] || fail "legacy GLM launcher was not removed"
[ ! -e "$TARGET/skills/pm-orchestrator/scripts/launch-claude-deepseek.sh" ] || fail "legacy DeepSeek launcher was not removed"
[ -x "$TARGET/skills/pm-orchestrator/scripts/install-global.sh" ] || fail "installer was not installed"
[ -f "$TARGET/commands/leader-task.md" ] || fail "leader-task command was not installed"
[ -f "$TARGET/commands/leader-resume.md" ] || fail "leader-resume command was not installed"
[ -f "$TARGET/commands/goal.md" ] || fail "goal command was not installed"
[ -f "$TARGET/commands/imageinput.md" ] || fail "imageinput command was not installed"
[ -f "$TARGET/commands/do.md" ] || fail "do command was not installed"
[ -f "$TARGET/commands/wrap-up.md" ] || fail "wrap-up command was not installed"
[ -f "$TARGET/commands/portfolio.md" ] || fail "portfolio command was not installed"
[ -f "$TARGET/commands/idea.md" ] || fail "idea command was not installed"
[ -f "$TARGET/commands/project-register.md" ] || fail "project-register command was not installed"
[ -f "$TARGET/skills/pm-orchestrator/scripts/pm-imageinput.py" ] || fail "image input helper was not installed"
[ -f "$TARGET/agents/dev-agent.md" ] || fail "agents were not installed"
[ -f "$TARGET/templates/leader-handoff.md" ] || fail "templates were not installed"

echo "PASS: global Claude install"
