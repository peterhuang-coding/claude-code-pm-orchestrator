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
require_pattern 'PM_HANDOFF_TOOL' '.claude/commands/leader-resume.md'
require_pattern '\$HOME/\.claude/skills/pm-orchestrator/scripts/pm-handoff\.sh' '.claude/commands/leader-resume.md'
require_pattern '\$HANDOFF_TOOL list' '.claude/commands/leader-resume.md'
require_pattern 'git worktree list' '.claude/commands/leader-resume.md'
require_pattern 'TASK_ID' '.claude/commands/leader-resume.md'
require_pattern 'rg --files' '.claude/commands/leader-resume.md'
require_pattern 'new legacy-resume' '.claude/commands/leader-resume.md'
require_pattern '旧交接' '.claude/commands/leader-resume.md'
require_pattern '恢复流程' '.claude/skills/pm-orchestrator/SKILL.md'
require_pattern '上下文预算' '.claude/skills/pm-orchestrator/SKILL.md'
require_pattern 'git-common-dir' '.claude/skills/pm-orchestrator/SKILL.md'
require_pattern 'launch-claude-glm\.sh' '.claude/commands/pm-worktrees.md'
require_pattern 'Task ID' '.claude/templates/leader-handoff.md'

[ -x "$ROOT/.claude/skills/pm-orchestrator/scripts/pm-handoff.sh" ] || fail "pm-handoff.sh is not executable"
[ -x "$ROOT/.claude/skills/pm-orchestrator/scripts/launch-claude-glm.sh" ] || fail "launch-claude-glm.sh is not executable"
[ -x "$ROOT/.claude/skills/pm-orchestrator/scripts/install-global.sh" ] || fail "install-global.sh is not executable"

FOUND=0
for AGENT in "$ROOT"/.claude/agents/*.md; do
  FOUND=1
  grep -Fq 'TASK_ID' "$AGENT" || fail "$AGENT does not require TASK_ID"
  grep -Fq 'PM_HANDOFF_TOOL' "$AGENT" || fail "$AGENT does not support global tool resolution"
  grep -Fq '"$HANDOFF_TOOL" write "$TASK_ID"' "$AGENT" || fail "$AGENT does not persist its handoff"
done
[ "$FOUND" -eq 1 ] || fail "no Agent definitions found"

echo "PASS: PM skill handoff contract"
