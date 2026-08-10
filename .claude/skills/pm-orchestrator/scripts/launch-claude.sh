#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROVIDER_TOOL=${PM_PROVIDER_TOOL:-"$SCRIPT_DIR/pm-provider.py"}

export PM_HANDOFF_TOOL="$SCRIPT_DIR/pm-handoff.sh"
export PM_HUB_TOOL="$SCRIPT_DIR/pm-hub.sh"
export PM_CLAUDE_LAUNCHER="$SCRIPT_DIR/launch-claude.sh"
export CLAUDE_CODE_EFFORT_LEVEL=max
export CLAUDE_CODE_DISABLE_THINKING=0
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
export CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=${CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY:-12}

if [ "${PM_PROVIDER_ROUTING:-0}" = 1 ]; then
  exec python3 "$PROVIDER_TOOL" exec claude \
    --permission-mode bypassPermissions \
    --effort max \
    --teammate-mode in-process \
    "$@"
fi

exec claude \
  --permission-mode bypassPermissions \
  --effort max \
  --teammate-mode in-process \
  "$@"
