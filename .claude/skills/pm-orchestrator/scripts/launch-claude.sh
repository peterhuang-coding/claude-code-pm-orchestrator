#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

MINIMAX_KEY=${PM_MINIMAX_API_KEY:-}
if [ -z "$MINIMAX_KEY" ]; then
  MINIMAX_KEY=$(/usr/bin/security find-generic-password \
    -w -s claude-pm-provider-router -a minimax 2>/dev/null || true)
fi
[ -n "$MINIMAX_KEY" ] || {
  echo "launch-claude: MiniMax key is not configured in macOS Keychain." >&2
  echo "Run: claude-yolo provider set minimax" >&2
  exit 1
}

unset ANTHROPIC_AUTH_TOKEN
unset CLAUDE_CODE_OAUTH_TOKEN
export ANTHROPIC_API_KEY="$MINIMAX_KEY"
export ANTHROPIC_BASE_URL=https://api.minimaxi.com/anthropic
export ANTHROPIC_MODEL=MiniMax-M3
export ANTHROPIC_DEFAULT_HAIKU_MODEL=MiniMax-M3
export ANTHROPIC_DEFAULT_SONNET_MODEL=MiniMax-M3
export ANTHROPIC_DEFAULT_OPUS_MODEL=MiniMax-M3
export CLAUDE_CODE_SUBAGENT_MODEL=MiniMax-M3
export CLAUDE_MODEL=MiniMax-M3

export PM_HANDOFF_TOOL="$SCRIPT_DIR/pm-handoff.sh"
export PM_HUB_TOOL="$SCRIPT_DIR/pm-hub.sh"
export PM_CLAUDE_LAUNCHER="$SCRIPT_DIR/launch-claude.sh"
export CLAUDE_CODE_EFFORT_LEVEL=max
export CLAUDE_CODE_DISABLE_THINKING=0
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
export CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=${CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY:-12}

exec claude --permission-mode bypassPermissions --effort max --teammate-mode in-process "$@"
