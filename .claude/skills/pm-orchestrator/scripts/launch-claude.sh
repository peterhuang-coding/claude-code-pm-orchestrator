#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

export PM_HANDOFF_TOOL="$SCRIPT_DIR/pm-handoff.sh"
export PM_HUB_TOOL="$SCRIPT_DIR/pm-hub.sh"
export PM_CLAUDE_LAUNCHER="$SCRIPT_DIR/launch-claude.sh"

exec claude --permission-mode bypassPermissions "$@"
