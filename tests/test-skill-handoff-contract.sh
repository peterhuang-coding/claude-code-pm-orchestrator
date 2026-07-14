#!/bin/sh
set -eu

ROOT=${1:-.}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_pattern() {
  PATTERN=$1
  FILE=$2
  grep -Eq "$PATTERN" "$ROOT/$FILE" || fail "$FILE is missing pattern: $PATTERN"
}

require_pattern '强制 checkpoint' '.claude/commands/leader-task.md'
require_pattern 'pm-handoff\.sh' '.claude/commands/leader-task.md'
require_pattern 'TASK_ID' '.claude/commands/leader-task.md'
require_pattern 'complete "?\$TASK_ID"?' '.claude/commands/leader-task.md'
require_pattern 'HANDOFF_TOOL=.*pm-handoff\.sh' '.claude/commands/leader-resume.md'
require_pattern '\$HANDOFF_TOOL list' '.claude/commands/leader-resume.md'
require_pattern 'git worktree list' '.claude/commands/leader-resume.md'
require_pattern 'TASK_ID' '.claude/commands/leader-resume.md'
require_pattern '恢复流程' '.claude/skills/pm-orchestrator/SKILL.md'
require_pattern '上下文预算' '.claude/skills/pm-orchestrator/SKILL.md'
require_pattern 'git-common-dir' '.claude/skills/pm-orchestrator/SKILL.md'
require_pattern 'launch-claude-glm\.sh' '.claude/commands/pm-worktrees.md'
require_pattern 'Task ID' '.claude/templates/leader-handoff.md'

[ -x "$ROOT/.claude/skills/pm-orchestrator/scripts/pm-handoff.sh" ] || fail "pm-handoff.sh is not executable"
[ -x "$ROOT/.claude/skills/pm-orchestrator/scripts/launch-claude-glm.sh" ] || fail "launch-claude-glm.sh is not executable"

FOUND=0
for AGENT in "$ROOT"/.claude/agents/*.md; do
  FOUND=1
  grep -Fq 'TASK_ID' "$AGENT" || fail "$AGENT does not require TASK_ID"
  grep -Fq 'pm-handoff.sh write "$TASK_ID"' "$AGENT" || fail "$AGENT does not persist its handoff"
done
[ "$FOUND" -eq 1 ] || fail "no Agent definitions found"

echo "PASS: PM skill handoff contract"
