#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE_CLAUDE=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
TARGET_CLAUDE=${PM_CLAUDE_HOME:-"$HOME/.claude"}

if [ "$SOURCE_CLAUDE" = "$TARGET_CLAUDE" ]; then
  printf 'PM orchestrator is already running from %s\n' "$TARGET_CLAUDE"
  exit 0
fi

copy_tree() {
  SOURCE=$1
  TARGET=$2
  mkdir -p "$TARGET"
  cp -R "$SOURCE/." "$TARGET/"
}

mkdir -p "$TARGET_CLAUDE"
copy_tree "$SOURCE_CLAUDE/agents" "$TARGET_CLAUDE/agents"
copy_tree "$SOURCE_CLAUDE/commands" "$TARGET_CLAUDE/commands"
copy_tree "$SOURCE_CLAUDE/templates" "$TARGET_CLAUDE/templates"
copy_tree "$SOURCE_CLAUDE/skills/pm-orchestrator" "$TARGET_CLAUDE/skills/pm-orchestrator"

for OLD_LAUNCHER in \
  "$TARGET_CLAUDE/skills/pm-orchestrator/scripts/launch-claude-glm.sh" \
  "$TARGET_CLAUDE/skills/pm-orchestrator/scripts/launch-claude-deepseek.sh"
do
  [ ! -f "$OLD_LAUNCHER" ] || rm -f "$OLD_LAUNCHER"
done

chmod +x "$TARGET_CLAUDE/skills/pm-orchestrator/scripts/"*.sh
chmod +x "$TARGET_CLAUDE/skills/pm-orchestrator/scripts/claude-pm"
chmod +x "$TARGET_CLAUDE/skills/pm-orchestrator/scripts/claude-yolo"
chmod +x "$TARGET_CLAUDE/skills/pm-orchestrator/scripts/claude-feishu"
chmod +x "$TARGET_CLAUDE/skills/pm-orchestrator/scripts/pm-feishu-hook.py"
mkdir -p "$TARGET_CLAUDE/bin"
ln -sf "$TARGET_CLAUDE/skills/pm-orchestrator/scripts/claude-pm" "$TARGET_CLAUDE/bin/claude-pm"
ln -sf "$TARGET_CLAUDE/skills/pm-orchestrator/scripts/claude-yolo" "$TARGET_CLAUDE/bin/claude-yolo"
ln -sf "$TARGET_CLAUDE/bin/claude-yolo" "$TARGET_CLAUDE/bin/claude-yolo-minimax"
ln -sf "$TARGET_CLAUDE/skills/pm-orchestrator/scripts/claude-feishu" "$TARGET_CLAUDE/bin/claude-feishu"

GLOBAL_BIN=${PM_GLOBAL_BIN:-}
if [ -z "$GLOBAL_BIN" ]; then
  EXISTING_YOLO=$(command -v claude-yolo 2>/dev/null || true)
  if [ -n "$EXISTING_YOLO" ]; then
    GLOBAL_BIN=$(dirname "$EXISTING_YOLO")
  else
    GLOBAL_BIN="$TARGET_CLAUDE/bin"
  fi
fi
mkdir -p "$GLOBAL_BIN"
if [ "$GLOBAL_BIN" != "$TARGET_CLAUDE/bin" ]; then
  ln -sf "$TARGET_CLAUDE/bin/claude-pm" "$GLOBAL_BIN/claude-pm"
  ln -sf "$TARGET_CLAUDE/bin/claude-yolo" "$GLOBAL_BIN/claude-yolo"
  ln -sf "$TARGET_CLAUDE/bin/claude-yolo-minimax" "$GLOBAL_BIN/claude-yolo-minimax"
  ln -sf "$TARGET_CLAUDE/bin/claude-feishu" "$GLOBAL_BIN/claude-feishu"
fi

printf 'Installed PM orchestrator into %s\n' "$TARGET_CLAUDE"
printf 'Installed shell commands into %s\n' "$GLOBAL_BIN"
printf 'Existing settings.json and credentials were not modified.\n'
