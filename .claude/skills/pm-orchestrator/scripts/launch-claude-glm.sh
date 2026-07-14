#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

unset ANTHROPIC_AUTH_TOKEN
unset CLAUDE_CODE_OAUTH_TOKEN
unset CLAUDE_CODE_EFFORT_LEVEL

export ANTHROPIC_BASE_URL=${SFKEY_BASE_URL:-https://api.sfkey.cn}
export ANTHROPIC_MODEL=glm-5.2
export ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-5.2
export ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5.2
export ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5.2
export CLAUDE_CODE_SUBAGENT_MODEL=glm-5.2
export CLAUDE_MODEL=glm-5.2
export CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=${CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY:-15}
export PM_HANDOFF_TOOL="$SCRIPT_DIR/pm-handoff.sh"
export PM_CLAUDE_LAUNCHER="$SCRIPT_DIR/launch-claude-glm.sh"

exec claude --model glm-5.2 --permission-mode bypassPermissions "$@"
