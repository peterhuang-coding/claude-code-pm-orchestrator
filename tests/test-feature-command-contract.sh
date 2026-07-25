#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FEATURE="$ROOT/.claude/commands/feature.md"
TODAY="$ROOT/.claude/commands/today.md"
SKILL="$ROOT/.claude/skills/pm-orchestrator/SKILL.md"
README="$ROOT/README.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -f "$FEATURE" ] || fail "/feature command is missing"
[ -f "$TODAY" ] || fail "/today command is missing"

grep -Fq 'pm-feature.sh' "$FEATURE" || fail "/feature does not use the durable ledger"
grep -Fq '最多 5' "$FEATURE" || fail "/feature lacks the Agent Team size cap"
grep -Fq 'worktree' "$FEATURE" || fail "/feature lacks parallel edit isolation"
grep -Fq 'Agent View' "$FEATURE" || fail "/feature lacks background tracking guidance"
grep -Fq '不再重复确认' "$FEATURE" || fail "/feature does not act as bounded approval"
grep -Fq 'needs-input' "$TODAY" || fail "/today does not prioritize decisions"
grep -Fq '最多 3' "$TODAY" || fail "/today is not bounded for a one-hour review"
grep -Fq 'Feature 台账是长期事实源' "$SKILL" || fail "Skill does not define durable source of truth"
grep -Fq 'claude-yolo board' "$README" || fail "README omits Agent View entrypoint"
grep -Fq '/feature' "$README" || fail "README omits feature workflow"

echo "PASS: Feature tracking command contract"
