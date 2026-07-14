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

chmod +x "$TARGET_CLAUDE/skills/pm-orchestrator/scripts/"*.sh

printf 'Installed PM orchestrator into %s\n' "$TARGET_CLAUDE"
printf 'Existing settings.json and credentials were not modified.\n'
