#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

unset CLAUDE_CODE_OAUTH_TOKEN
unset CLAUDE_CODE_EFFORT_LEVEL

MODEL=${DEEPSEEK_MODEL:-deepseek-v4-pro}
export ANTHROPIC_BASE_URL=${DEEPSEEK_BASE_URL:-https://api.deepseek.com/anthropic}
unset ANTHROPIC_API_KEY
export ANTHROPIC_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$MODEL"
export CLAUDE_CODE_SUBAGENT_MODEL="$MODEL"
export CLAUDE_MODEL="$MODEL"
export CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=${CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY:-15}
export PM_HANDOFF_TOOL="$SCRIPT_DIR/pm-handoff.sh"
export PM_CLAUDE_LAUNCHER="$SCRIPT_DIR/launch-claude-glm.sh"

exec claude --model "$MODEL" --permission-mode bypassPermissions "$@"
