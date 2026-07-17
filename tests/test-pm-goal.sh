#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
GOAL_SCRIPT="$SCRIPT_DIR/../.claude/skills/pm-orchestrator/scripts/pm-goal.sh"
HANDOFF_SCRIPT="$SCRIPT_DIR/../.claude/skills/pm-orchestrator/scripts/pm-handoff.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/pm-goal-test.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
REPO="$SANDBOX/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email goal-test@example.invalid
git -C "$REPO" config user.name goal-test
printf '%s\n' 'goal test' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm initial

run_goal() {
  (cd "$REPO" && PM_HANDOFF_ROOT="$SANDBOX/handoffs" "$GOAL_SCRIPT" "$@")
}

GOAL_ID=$(printf '%s\n' 'Build a focused playable brewery loop' | run_goal new brewery-loop)
run_goal status "$GOAL_ID" | grep -Fq 'status=discovery' || fail "new Goal was not in discovery"

! printf '%s\n' '' | run_goal brief "$GOAL_ID" >/dev/null 2>&1 || fail "empty brief was accepted"
printf '%s\n' '# Goal brief' | run_goal brief "$GOAL_ID" >/dev/null
run_goal status "$GOAL_ID" | grep -Fq 'status=awaiting-approval' || fail "brief did not await approval"

(cd "$REPO" && PM_HANDOFF_ROOT="$SANDBOX/handoffs" "$HANDOFF_SCRIPT" new legacy-task >/dev/null)

! run_goal approve </dev/null >/dev/null 2>&1 || fail "approval without a note was accepted"
printf '%s\n' 'Approved for implementation after product review.' | run_goal approve >/dev/null
run_goal status | grep -Fq "goal_id=$GOAL_ID status=approved" || fail "latest Goal was not approved without an ID"
run_goal status "$GOAL_ID" | grep -Fq 'status=approved' || fail "Goal was not approved"
! printf '%s\n' 'second approval' | run_goal approve "$GOAL_ID" >/dev/null 2>&1 || fail "second approval was accepted"

run_goal read "$GOAL_ID" | grep -Fq '# Goal brief' || fail "Goal brief could not be read"
! printf '%s\n' 'sk-12345678901234567890' | run_goal brief "$GOAL_ID" >/dev/null 2>&1 || fail "secret-looking brief was accepted"
run_goal start "$GOAL_ID" >/dev/null
run_goal status "$GOAL_ID" | grep -Fq 'status=executing' || fail "Goal was not started"
run_goal read "$GOAL_ID" | grep -Fq -- '- Status: executing' || fail "Goal brief status was stale"
run_goal stop "$GOAL_ID" >/dev/null
run_goal status "$GOAL_ID" | grep -Fq 'status=stopped' || fail "Goal was not stopped"
! run_goal approve "$GOAL_ID" >/dev/null 2>&1 || fail "stopped Goal was approved"

echo "PASS: PM goal state machine"
