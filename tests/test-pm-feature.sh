#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FEATURE_TOOL="$ROOT/.claude/skills/pm-orchestrator/scripts/pm-feature.sh"
HUB_TOOL="$ROOT/.claude/skills/pm-orchestrator/scripts/pm-hub.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -x "$FEATURE_TOOL" ] || fail "pm-feature.sh is missing or not executable"

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/pm-feature-test.XXXXXX")
SANDBOX=$(CDPATH= cd -- "$SANDBOX" && pwd -P)
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
HUB="$SANDBOX/hub"
PROJECT_A="$SANDBOX/project-a"
PROJECT_B="$SANDBOX/project-b"
BRIEF="$SANDBOX/brief.md"
NOTE="$SANDBOX/note.md"
mkdir -p "$PROJECT_A" "$PROJECT_B"
git -C "$PROJECT_A" init -q
git -C "$PROJECT_A" config user.email test@example.com
git -C "$PROJECT_A" config user.name Test
printf 'seed\n' > "$PROJECT_A/seed.txt"
git -C "$PROJECT_A" add seed.txt
git -C "$PROJECT_A" commit -qm seed

PM_HUB_HOME="$HUB" "$HUB_TOOL" init >/dev/null
PM_HUB_HOME="$HUB" "$HUB_TOOL" register "$PROJECT_A" alpha >/dev/null
PM_HUB_HOME="$HUB" "$HUB_TOOL" register "$PROJECT_B" beta >/dev/null

feature() {
  PM_HUB_HOME="$HUB" PM_HUB_TOOL="$HUB_TOOL" "$FEATURE_TOOL" "$@"
}

cat > "$BRIEF" <<'EOF'
# Improve onboarding

- Goal: reduce first-run confusion
- Acceptance: tutorial can be completed without external help
EOF

FEATURE_ID=$(feature new improve-onboarding "$BRIEF" "$PROJECT_A")
printf '%s' "$FEATURE_ID" | grep -Eq '^F-[0-9]{8}-[0-9]{6}-improve-onboarding-[0-9]+$' || fail "feature id is invalid"
[ "$(feature status "$FEATURE_ID" "$PROJECT_A")" = "ready" ] || fail "new feature is not ready"
feature read "$FEATURE_ID" "$PROJECT_A" | grep -Fq 'Improve onboarding' || fail "feature brief missing"
feature list "$PROJECT_A" | grep -Fq "$FEATURE_ID" || fail "feature list omitted feature"
if feature list "$PROJECT_B" | grep -Fq "$FEATURE_ID"; then
  fail "feature leaked across projects"
fi

cat > "$NOTE" <<'EOF'
# Progress

- Agent Team started
- Product and Tech analysis complete
EOF
feature update "$FEATURE_ID" running "$NOTE" "$PROJECT_A" >/dev/null
[ "$(feature status "$FEATURE_ID" "$PROJECT_A")" = "running" ] || fail "feature did not enter running"
feature read "$FEATURE_ID" "$PROJECT_A" | grep -Fq 'Agent Team started' || fail "latest update missing from feature read"
feature dashboard "$PROJECT_A" | grep -Fq "$FEATURE_ID" || fail "project dashboard omitted feature"
feature dashboard "$PROJECT_A" | grep -Fq 'Agent Team started' || fail "project dashboard omitted latest evidence"
feature dashboard --all | grep -Fq 'alpha' || fail "portfolio dashboard omitted project"

feature update "$FEATURE_ID" review "$NOTE" "$PROJECT_A" >/dev/null
printf '%s\n' 'GITHUB_TOKEN=ghp_123456789012345678901234567890123456' > "$NOTE"
if feature update "$FEATURE_ID" done "$NOTE" "$PROJECT_A" >/dev/null 2>&1; then
  fail "secret-bearing feature update was accepted"
fi
cat > "$NOTE" <<'EOF'
# Verified

- Regression passed
EOF

WORKTREE="$SANDBOX/linked-worktree"
git -C "$PROJECT_A" worktree add -q -b test-worktree "$WORKTREE"
[ "$(feature status "$FEATURE_ID" "$WORKTREE")" = "review" ] || fail "linked worktree was not mapped to registered project"
if PM_HUB_HOME="$HUB" "$HUB_TOOL" register "$WORKTREE" duplicate >/dev/null 2>&1; then
  fail "linked worktree was registered as a duplicate project"
fi

(
  feature update "$FEATURE_ID" done "$NOTE" "$PROJECT_A" >/dev/null 2>&1
) &
PID_DONE=$!
(
  feature update "$FEATURE_ID" running "$NOTE" "$WORKTREE" >/dev/null 2>&1
) &
PID_RUNNING=$!
SUCCEEDED=0
if wait "$PID_DONE"; then SUCCEEDED=$((SUCCEEDED + 1)); fi
if wait "$PID_RUNNING"; then SUCCEEDED=$((SUCCEEDED + 1)); fi
[ "$SUCCEEDED" -eq 1 ] || fail "concurrent state transitions were not serialized"

if [ "$(feature status "$FEATURE_ID" "$PROJECT_A")" != done ]; then
  feature update "$FEATURE_ID" review "$NOTE" "$PROJECT_A" >/dev/null
  feature update "$FEATURE_ID" done "$NOTE" "$PROJECT_A" >/dev/null
fi
[ "$(feature status "$FEATURE_ID" "$PROJECT_A")" = "done" ] || fail "feature did not complete"
if feature update "$FEATURE_ID" running "$NOTE" "$PROJECT_A" >/dev/null 2>&1; then
  fail "completed feature was reopened"
fi

cat > "$BRIEF" <<'EOF'
# Stale lock recovery
EOF
LOCK_FEATURE_ID=$(feature new stale-lock "$BRIEF" "$PROJECT_A")
LOCK_DIR="$HUB/projects/alpha/features/$LOCK_FEATURE_ID/.update-lock"
mkdir "$LOCK_DIR"
printf '999999\t1\n' > "$LOCK_DIR/owner"
feature update "$LOCK_FEATURE_ID" running "$NOTE" "$PROJECT_A" >/dev/null ||
  fail "stale feature lock was not recovered"

python3 - "$BRIEF" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_text("x" * 13000)
PY
if feature new too-large "$BRIEF" "$PROJECT_A" >/dev/null 2>&1; then
  fail "oversized feature brief was accepted"
fi

echo "PASS: durable feature ledger"
