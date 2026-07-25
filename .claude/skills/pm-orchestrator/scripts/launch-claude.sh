#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROVIDER_TOOL=${PM_PROVIDER_TOOL:-"$SCRIPT_DIR/pm-provider.py"}

export PM_HANDOFF_TOOL="$SCRIPT_DIR/pm-handoff.sh"
export PM_HUB_TOOL="$SCRIPT_DIR/pm-hub.sh"
export PM_CLAUDE_LAUNCHER="$SCRIPT_DIR/launch-claude.sh"

if [ -x "$PROVIDER_TOOL" ] &&
  "$PROVIDER_TOOL" status --json 2>/dev/null |
    python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("active") is True else 1)'
then
  exec "$PROVIDER_TOOL" exec \
    claude --permission-mode bypassPermissions "$@"
fi

exec claude --permission-mode bypassPermissions "$@"
