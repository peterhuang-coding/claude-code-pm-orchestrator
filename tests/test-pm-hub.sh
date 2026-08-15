#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TOOL="$ROOT/.claude/skills/pm-orchestrator/scripts/pm-hub.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -x "$TOOL" ] || fail "pm-hub.sh is missing or not executable"

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/pm-hub-test.XXXXXX")
SANDBOX=$(CDPATH= cd -- "$SANDBOX" && pwd -P)
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
HUB="$SANDBOX/hub"
PROJECT_A="$SANDBOX/project-a"
PROJECT_B="$SANDBOX/project-b"
mkdir -p "$PROJECT_A" "$PROJECT_B"
HUB=$(mkdir -p "$HUB" && CDPATH= cd -- "$HUB" && pwd -P)
PROJECT_A=$(CDPATH= cd -- "$PROJECT_A" && pwd -P)
PROJECT_B=$(CDPATH= cd -- "$PROJECT_B" && pwd -P)
git -C "$PROJECT_A" init -q
git -C "$PROJECT_B" init -q

hub() {
  PM_HUB_HOME="$HUB" "$TOOL" "$@"
}

hub init >/dev/null
[ -f "$HUB/config/projects.tsv" ] || fail "registry missing"
[ -f "$HUB/portfolio/ideas.md" ] || fail "portfolio ideas missing"

# Reopening an initialized Hub is a read-only operation. This keeps cold start
# available when macOS temporarily denies removable-volume writes.
chmod 0555 "$HUB/config"
hub init >/dev/null || fail "initialized Hub requires config write access"
chmod 0755 "$HUB/config"

hub register "$PROJECT_A" alpha >/dev/null
hub register "$PROJECT_B" beta >/dev/null
[ "$(hub classify "$PROJECT_A")" = "project	alpha	$PROJECT_A" ] || fail "project classification incorrect"
[ "$(hub classify "$HUB")" = "hub	$HUB" ] || fail "hub classification incorrect"
[ "$(hub classify "$SANDBOX")" = "unknown	$SANDBOX" ] || fail "unknown classification incorrect"

COLD=$(hub cold-start "$PROJECT_A")
printf '%s' "$COLD" | grep -Fq 'alpha' || fail "cold start omitted project"
printf '%s' "$COLD" | grep -Fq '项目冷启动' || fail "cold start omitted role"
mkdir -p "$PROJECT_A/.git/pm-handoffs/zzz-stale-task" "$PROJECT_A/.git/pm-handoffs/aaa-current-task"
printf '%s\n' 'STALE_HANDOFF_SENTINEL' > "$PROJECT_A/.git/pm-handoffs/zzz-stale-task/leader.md"
printf '%s\n' 'ACTIVE_HANDOFF_SENTINEL' > "$PROJECT_A/.git/pm-handoffs/aaa-current-task/leader.md"
printf '%s\n' 'aaa-current-task' > "$PROJECT_A/.git/pm-handoffs/LATEST"
COLD=$(hub cold-start "$PROJECT_A")
printf '%s' "$COLD" | grep -Fq 'ACTIVE_HANDOFF_SENTINEL' || fail "cold start omitted latest handoff"
if printf '%s' "$COLD" | grep -Fq 'STALE_HANDOFF_SENTINEL'; then
  fail "cold start selected stale handoff"
fi

SUMMARY="$SANDBOX/summary.md"
cat > "$SUMMARY" <<'EOF'
# 本轮复盘

- 完成：实现注册测试
- 验证：shell test passed
- 下一步：实现冷启动
EOF
SESSION=$(hub wrap-up alpha "$SUMMARY")
[ -f "$SESSION" ] || fail "session record missing"
grep -Fq '实现注册测试' "$HUB/projects/alpha/latest.md" || fail "latest summary not updated"

hub idea "为 alpha 增加发布检查" "$PROJECT_A" >/dev/null
grep -Fq '为 alpha 增加发布检查' "$HUB/projects/alpha/ideas.md" || fail "project idea missing"
hub idea "研究飞书助手权限" "$HUB" >/dev/null
grep -Fq '研究飞书助手权限' "$HUB/portfolio/ideas.md" || fail "portfolio idea missing"
printf '%s\n' '- PROJECT_IDEA_SENTINEL' >> "$HUB/projects/alpha/ideas.md"

ASSIGNMENT="$SANDBOX/assignment.md"
printf '%s\n' '# Assignment' '' '- ASSIGNMENT_SENTINEL' > "$ASSIGNMENT"
hub assign alpha "$ASSIGNMENT" >/dev/null
grep -Fq 'ASSIGNMENT_SENTINEL' "$HUB/projects/alpha/assignments.md" || fail "assignment missing"

PORTFOLIO=$(hub portfolio)
printf '%s' "$PORTFOLIO" | grep -Fq 'alpha' || fail "portfolio omitted alpha"
printf '%s' "$PORTFOLIO" | grep -Fq 'beta' || fail "portfolio omitted beta"
printf '%s' "$PORTFOLIO" | grep -Fq '实现注册测试' || fail "portfolio omitted latest summary"
printf '%s' "$PORTFOLIO" | grep -Fq 'PROJECT_IDEA_SENTINEL' || fail "portfolio omitted project ideas"
printf '%s' "$PORTFOLIO" | grep -Fq 'ASSIGNMENT_SENTINEL' || fail "portfolio omitted assignments"

printf '%s\n' 'ANTHROPIC_API_KEY=sk-secret-value' > "$SUMMARY"
if hub wrap-up alpha "$SUMMARY" >/dev/null 2>&1; then
  fail "secret-bearing wrap-up was accepted"
fi
printf '%s\n' 'GITHUB_TOKEN=ghp_123456789012345678901234567890123456' > "$SUMMARY"
if hub wrap-up alpha "$SUMMARY" >/dev/null 2>&1; then
  fail "GitHub token was accepted"
fi
if hub profile 'sk-123456789012345678901234' >/dev/null 2>&1; then
  fail "secret-bearing profile was accepted"
fi
printf '%s\n' 'GITHUB_TOKEN=ghp_123456789012345678901234567890123456' > "$ASSIGNMENT"
if hub assign alpha "$ASSIGNMENT" >/dev/null 2>&1; then
  fail "secret-bearing assignment was accepted"
fi

python3 - "$SUMMARY" <<'PY'
import sys
from pathlib import Path
Path(sys.argv[1]).write_text("# Large\n" + ("x" * 13000), encoding="utf-8")
PY
if hub wrap-up alpha "$SUMMARY" >/dev/null 2>&1; then
  fail "oversized wrap-up was accepted"
fi

echo "PASS: personal R&D hub"
