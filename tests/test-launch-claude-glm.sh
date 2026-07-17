#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LAUNCHER="$SCRIPT_DIR/../.claude/skills/pm-orchestrator/scripts/launch-claude-glm.sh"
LAUNCHER_DIR=$(CDPATH= cd -- "$(dirname -- "$LAUNCHER")" && pwd)
LAUNCHER="$LAUNCHER_DIR/launch-claude-glm.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -x "$LAUNCHER" ] || fail "launch-claude-glm.sh is missing or not executable"

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/launch-claude-test.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM

cat > "$SANDBOX/claude" <<'EOF'
#!/bin/sh
set -eu
OUT=${CLAUDE_LAUNCH_TEST_OUT:?}
{
  echo "ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN-<unset>}"
  echo "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN-<unset>}"
  echo "CLAUDE_CODE_EFFORT_LEVEL=${CLAUDE_CODE_EFFORT_LEVEL-<unset>}"
  echo "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL-<unset>}"
  echo "ANTHROPIC_MODEL=${ANTHROPIC_MODEL-<unset>}"
  echo "ANTHROPIC_DEFAULT_HAIKU_MODEL=${ANTHROPIC_DEFAULT_HAIKU_MODEL-<unset>}"
  echo "ANTHROPIC_DEFAULT_SONNET_MODEL=${ANTHROPIC_DEFAULT_SONNET_MODEL-<unset>}"
  echo "ANTHROPIC_DEFAULT_OPUS_MODEL=${ANTHROPIC_DEFAULT_OPUS_MODEL-<unset>}"
  echo "CLAUDE_CODE_SUBAGENT_MODEL=${CLAUDE_CODE_SUBAGENT_MODEL-<unset>}"
  echo "CLAUDE_MODEL=${CLAUDE_MODEL-<unset>}"
  echo "CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=${CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY-<unset>}"
  echo "PM_HANDOFF_TOOL=${PM_HANDOFF_TOOL-<unset>}"
  echo "PM_CLAUDE_LAUNCHER=${PM_CLAUDE_LAUNCHER-<unset>}"
  printf 'ARGS='
  printf '<%s>' "$@"
  printf '\n'
} > "$OUT"
EOF
chmod +x "$SANDBOX/claude"

OUT="$SANDBOX/result"
PATH="$SANDBOX:$PATH" \
CLAUDE_LAUNCH_TEST_OUT="$OUT" \
ANTHROPIC_AUTH_TOKEN=old-auth \
CLAUDE_CODE_OAUTH_TOKEN=old-oauth \
CLAUDE_CODE_EFFORT_LEVEL=max \
ANTHROPIC_BASE_URL=https://api.sfkey.cn \
DEEPSEEK_BASE_URL=https://relay.example/v1 \
CLAUDE_CODE_SUBAGENT_MODEL=old-subagent \
CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=6 \
"$LAUNCHER" --name test-session

grep -Fxq 'ANTHROPIC_AUTH_TOKEN=old-auth' "$OUT" || fail "DeepSeek auth token was not preserved"
grep -Fxq 'CLAUDE_CODE_OAUTH_TOKEN=<unset>' "$OUT" || fail "OAuth token was not cleared"
grep -Fxq 'CLAUDE_CODE_EFFORT_LEVEL=<unset>' "$OUT" || fail "effort override was not cleared"
grep -Fxq 'ANTHROPIC_BASE_URL=https://relay.example/v1' "$OUT" || fail "base URL override was lost"
grep -Fxq 'ANTHROPIC_MODEL=deepseek-v4-pro' "$OUT" || fail "main model was not pinned"
grep -Fxq 'ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-v4-pro' "$OUT" || fail "Haiku model was not pinned"
grep -Fxq 'ANTHROPIC_DEFAULT_SONNET_MODEL=deepseek-v4-pro' "$OUT" || fail "Sonnet model was not pinned"
grep -Fxq 'ANTHROPIC_DEFAULT_OPUS_MODEL=deepseek-v4-pro' "$OUT" || fail "Opus model was not pinned"
grep -Fxq 'CLAUDE_CODE_SUBAGENT_MODEL=<unset>' "$OUT" || fail "subagent model override was not cleared"
grep -Fxq 'CLAUDE_MODEL=deepseek-v4-pro' "$OUT" || fail "Claude model was not pinned"
grep -Fxq 'CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=6' "$OUT" || fail "concurrency override was lost"
grep -Fxq "PM_HANDOFF_TOOL=$(dirname "$LAUNCHER")/pm-handoff.sh" "$OUT" || fail "handoff tool path was not exported"
grep -Fxq "PM_CLAUDE_LAUNCHER=$LAUNCHER" "$OUT" || fail "launcher path was not exported"
grep -Fxq 'ARGS=<--model><deepseek-v4-pro><--permission-mode><bypassPermissions><--name><test-session>' "$OUT" || fail "Claude arguments were incorrect"

echo "PASS: Claude DeepSeek launcher"
