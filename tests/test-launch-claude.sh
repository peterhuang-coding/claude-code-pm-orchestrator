#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LAUNCHER="$ROOT/.claude/skills/pm-orchestrator/scripts/launch-claude.sh"
ENTRYPOINT="$ROOT/.claude/skills/pm-orchestrator/scripts/claude-pm"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -x "$LAUNCHER" ] || fail "launch-claude.sh is missing or not executable"
[ -x "$ENTRYPOINT" ] || fail "claude-pm is missing or not executable"

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/launch-claude-test.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
OUT="$SANDBOX/result"

cat > "$SANDBOX/claude" <<'EOF'
#!/bin/sh
set -eu
{
  for key in \
    ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_EFFORT_LEVEL \
    ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL \
    ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL \
    CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_MODEL CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY
  do
    eval "value=\${$key-<unset>}"
    printf '%s=%s\n' "$key" "$value"
  done
  printf 'PM_HANDOFF_TOOL=%s\n' "${PM_HANDOFF_TOOL-<unset>}"
  printf 'PM_HUB_TOOL=%s\n' "${PM_HUB_TOOL-<unset>}"
  printf 'PM_CLAUDE_LAUNCHER=%s\n' "${PM_CLAUDE_LAUNCHER-<unset>}"
  printf 'ARGS='
  printf '<%s>' "$@"
  printf '\n'
} > "${CLAUDE_LAUNCH_TEST_OUT:?}"
EOF
chmod +x "$SANDBOX/claude"

PATH="$SANDBOX:$PATH" \
CLAUDE_LAUNCH_TEST_OUT="$OUT" \
ANTHROPIC_AUTH_TOKEN=auth-value \
CLAUDE_CODE_OAUTH_TOKEN=oauth-value \
CLAUDE_CODE_EFFORT_LEVEL=xhigh \
ANTHROPIC_BASE_URL=https://provider.example/anthropic \
ANTHROPIC_MODEL=provider-model \
ANTHROPIC_DEFAULT_HAIKU_MODEL=provider-haiku \
ANTHROPIC_DEFAULT_SONNET_MODEL=provider-sonnet \
ANTHROPIC_DEFAULT_OPUS_MODEL=provider-opus \
CLAUDE_CODE_SUBAGENT_MODEL=provider-subagent \
CLAUDE_MODEL=provider-claude \
CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=9 \
"$LAUNCHER" --name test-session

for expected in \
  'ANTHROPIC_AUTH_TOKEN=auth-value' \
  'CLAUDE_CODE_OAUTH_TOKEN=oauth-value' \
  'CLAUDE_CODE_EFFORT_LEVEL=xhigh' \
  'ANTHROPIC_BASE_URL=https://provider.example/anthropic' \
  'ANTHROPIC_MODEL=provider-model' \
  'ANTHROPIC_DEFAULT_HAIKU_MODEL=provider-haiku' \
  'ANTHROPIC_DEFAULT_SONNET_MODEL=provider-sonnet' \
  'ANTHROPIC_DEFAULT_OPUS_MODEL=provider-opus' \
  'CLAUDE_CODE_SUBAGENT_MODEL=provider-subagent' \
  'CLAUDE_MODEL=provider-claude' \
  'CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=9'
do
  grep -Fxq "$expected" "$OUT" || fail "environment changed: $expected"
done
grep -Fxq "PM_HANDOFF_TOOL=$(dirname "$LAUNCHER")/pm-handoff.sh" "$OUT" || fail "handoff path missing"
grep -Fxq "PM_HUB_TOOL=$(dirname "$LAUNCHER")/pm-hub.sh" "$OUT" || fail "Hub tool path missing"
grep -Fxq "PM_CLAUDE_LAUNCHER=$LAUNCHER" "$OUT" || fail "neutral launcher path missing"
grep -Fxq 'ARGS=<--permission-mode><bypassPermissions><--name><test-session>' "$OUT" || fail "permission arguments incorrect"

PROJECT="$SANDBOX/project"
HUB="$SANDBOX/hub"
mkdir -p "$PROJECT"
PM_HUB_HOME="$HUB" "$ROOT/.claude/skills/pm-orchestrator/scripts/pm-hub.sh" init >/dev/null
PM_HUB_HOME="$HUB" "$ROOT/.claude/skills/pm-orchestrator/scripts/pm-hub.sh" register "$PROJECT" sample >/dev/null

PATH="$SANDBOX:$PATH" \
CLAUDE_LAUNCH_TEST_OUT="$OUT" \
PM_HUB_HOME="$HUB" \
"$ENTRYPOINT" "$PROJECT" --name cold-start

grep -Fq 'ARGS=<--permission-mode><bypassPermissions><--name><cold-start><' "$OUT" || fail "cold-start prompt was not passed"
grep -Fq 'sample' "$OUT" || fail "cold-start prompt omitted project id"

mkdir -p "$SANDBOX/bin"
ln -s "$ENTRYPOINT" "$SANDBOX/bin/claude-pm"
PATH="$SANDBOX:$PATH" \
CLAUDE_LAUNCH_TEST_OUT="$OUT" \
PM_HUB_HOME="$HUB" \
"$SANDBOX/bin/claude-pm" "$PROJECT" --name symlink-start
grep -Fq 'ARGS=<--permission-mode><bypassPermissions><--name><symlink-start><' "$OUT" || fail "symlinked entrypoint failed"

for resume_flag in --continue -c --resume -r --from-pr; do
  if PATH="$SANDBOX:$PATH" CLAUDE_LAUNCH_TEST_OUT="$OUT" PM_HUB_HOME="$HUB" \
    "$ENTRYPOINT" "$PROJECT" "$resume_flag" old-session >/dev/null 2>&1
  then
    fail "resume flag was accepted: $resume_flag"
  fi
done

echo "PASS: model-neutral Claude launcher"
