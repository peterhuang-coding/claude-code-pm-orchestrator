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
require_pattern 'launch-claude\.sh' '.claude/commands/pm-worktrees.md'
require_pattern 'pm-hub\.sh' '.claude/commands/do.md'
require_pattern '/wrap-up' '.claude/commands/do.md'
require_pattern 'Agent Team' '.claude/commands/do.md'
require_pattern '生产|付费|密钥|不可逆' '.claude/commands/do.md'
require_pattern 'pm-hub\.sh' '.claude/commands/wrap-up.md'
require_pattern 'pm-hub\.sh' '.claude/commands/portfolio.md'
require_pattern 'assign <project-id>' '.claude/commands/portfolio.md'
require_pattern 'pm-hub\.sh' '.claude/commands/idea.md'
require_pattern 'pm-hub\.sh' '.claude/commands/project-register.md'
require_pattern '一句话' '.claude/skills/pm-orchestrator/SKILL.md'
require_pattern 'Agent Teams' '.claude/skills/pm-orchestrator/SKILL.md'
require_pattern 'claude-pm-hub' '.claude/skills/pm-orchestrator/SKILL.md'
require_pattern 'Task ID' '.claude/templates/leader-handoff.md'
require_pattern 'awaiting-approval' '.claude/commands/goal.md'
require_pattern 'pm-goal\.sh' '.claude/commands/goal.md'
require_pattern '公开' '.claude/commands/goal.md'
require_pattern 'approved' '.claude/skills/pm-orchestrator/SKILL.md'
require_pattern 'pm-loop\.sh' '.claude/skills/pm-orchestrator/SKILL.md'
require_pattern '对标' '.claude/skills/pm-orchestrator/SKILL.md'

[ -x "$ROOT/.claude/skills/pm-orchestrator/scripts/pm-handoff.sh" ] || fail "pm-handoff.sh is not executable"
[ -x "$ROOT/.claude/skills/pm-orchestrator/scripts/launch-claude.sh" ] || fail "launch-claude.sh is not executable"
[ -x "$ROOT/.claude/skills/pm-orchestrator/scripts/claude-pm" ] || fail "claude-pm is not executable"
[ -x "$ROOT/.claude/skills/pm-orchestrator/scripts/claude-yolo" ] || fail "claude-yolo is not executable"
[ -x "$ROOT/.claude/skills/pm-orchestrator/scripts/pm-hub.sh" ] || fail "pm-hub.sh is not executable"
[ -x "$ROOT/.claude/skills/pm-orchestrator/scripts/install-global.sh" ] || fail "install-global.sh is not executable"
[ -x "$ROOT/.claude/skills/pm-orchestrator/scripts/pm-goal.sh" ] || fail "pm-goal.sh is not executable"
[ -x "$ROOT/.claude/skills/pm-orchestrator/scripts/pm-loop.sh" ] || fail "pm-loop.sh is not executable"

FOUND=0
for AGENT in "$ROOT"/.claude/agents/*.md; do
  FOUND=1
  grep -Fq 'TASK_ID' "$AGENT" || fail "$AGENT does not require TASK_ID"
  grep -Fq 'PM_HANDOFF_TOOL' "$AGENT" || fail "$AGENT does not support global tool resolution"
  grep -Fq '"$HANDOFF_TOOL" write "$TASK_ID"' "$AGENT" || fail "$AGENT does not persist its handoff"
done
[ "$FOUND" -eq 1 ] || fail "no Agent definitions found"

echo "PASS: PM skill handoff contract"
