#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
GOAL_SCRIPT="$SCRIPT_DIR/../.claude/skills/pm-orchestrator/scripts/pm-goal.sh"
LOOP_SCRIPT="$SCRIPT_DIR/../.claude/skills/pm-orchestrator/scripts/pm-loop.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/pm-loop-test.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM

create_repo() {
  REPO=$1
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email loop-test@example.invalid
  git -C "$REPO" config user.name loop-test
  printf '%s\n' 'loop test' > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit -qm initial
}

goal_in_repo() {
  REPO=$1
  HANDOFF_ROOT=$2
  GOAL_ID=$(printf '%s\n' 'Run approved loop test' | (cd "$REPO" && PM_HANDOFF_ROOT="$HANDOFF_ROOT" "$GOAL_SCRIPT" new loop-test))
  printf '%s\n' '## Approved goal' | (cd "$REPO" && PM_HANDOFF_ROOT="$HANDOFF_ROOT" "$GOAL_SCRIPT" brief "$GOAL_ID") >/dev/null
  printf '%s\n' 'Approved for test.' | (cd "$REPO" && PM_HANDOFF_ROOT="$HANDOFF_ROOT" "$GOAL_SCRIPT" approve "$GOAL_ID") >/dev/null
  printf '%s\n' "$GOAL_ID"
}

[ -x "$LOOP_SCRIPT" ] || { echo "RED: pm-loop.sh is not implemented"; exit 1; }

REPO="$SANDBOX/repo"
HANDOFF_ROOT="$SANDBOX/handoffs"
create_repo "$REPO"
GOAL_ID=$(goal_in_repo "$REPO" "$HANDOFF_ROOT")

if (cd "$REPO" && PM_HANDOFF_ROOT="$HANDOFF_ROOT" PM_LOOP_LOCK="$SANDBOX/lock-a" "$LOOP_SCRIPT" --goal-id "$GOAL_ID" --until '2000-01-01T00:00') > "$SANDBOX/deadline.out" 2> "$SANDBOX/deadline.err"; then
  :
else
  fail "past deadline was not a clean stop"
fi
grep -Fq 'deadline reached' "$SANDBOX/deadline.out" || fail "deadline stop was not reported"

UNAPPROVED_REPO="$SANDBOX/unapproved"
create_repo "$UNAPPROVED_REPO"
UNAPPROVED=$(printf '%s\n' 'Needs approval' | (cd "$UNAPPROVED_REPO" && PM_HANDOFF_ROOT="$SANDBOX/unapproved-handoffs" "$GOAL_SCRIPT" new unapproved))
if (cd "$UNAPPROVED_REPO" && PM_HANDOFF_ROOT="$SANDBOX/unapproved-handoffs" PM_LOOP_LOCK="$SANDBOX/lock-b" "$LOOP_SCRIPT" --goal-id "$UNAPPROVED" --until '2099-01-01T00:00') > "$SANDBOX/unapproved.out" 2> "$SANDBOX/unapproved.err"; then
  fail "unapproved Goal started"
fi
grep -Fq 'approved' "$SANDBOX/unapproved.err" || { cat "$SANDBOX/unapproved.err" >&2; fail "unapproved refusal was unclear"; }

printf '%s\n' 'dirty' > "$REPO/dirty.txt"
if (cd "$REPO" && PM_HANDOFF_ROOT="$HANDOFF_ROOT" PM_LOOP_LOCK="$SANDBOX/lock-c" "$LOOP_SCRIPT" --goal-id "$GOAL_ID" --until '2099-01-01T00:00') > "$SANDBOX/dirty.out" 2> "$SANDBOX/dirty.err"; then
  fail "dirty worktree started without opt-in"
fi
grep -Fq 'dirty' "$SANDBOX/dirty.err" || fail "dirty refusal was unclear"

ROUND_REPO="$SANDBOX/round"
ROUND_HANDOFFS="$SANDBOX/round-handoffs"
create_repo "$ROUND_REPO"
ROUND_GOAL=$(goal_in_repo "$ROUND_REPO" "$ROUND_HANDOFFS")
FAKE_LAUNCHER="$SANDBOX/fake-launcher.sh"
printf '%s\n' '#!/bin/sh' 'printf yes > "$PM_LOOP_TEST_CALLED"' 'printf "%s\n" DONE' > "$FAKE_LAUNCHER"
chmod +x "$FAKE_LAUNCHER"
(cd "$ROUND_REPO" && PM_HANDOFF_ROOT="$ROUND_HANDOFFS" PM_LOOP_LOCK="$SANDBOX/lock-d" PM_CLAUDE_LAUNCHER="$FAKE_LAUNCHER" PM_LOOP_TEST_CALLED="$SANDBOX/launcher-called" "$LOOP_SCRIPT" --goal-id "$ROUND_GOAL" --until '2099-01-01T00:00' --max-rounds 1 --sleep-seconds 1) > "$SANDBOX/round.out" 2> "$SANDBOX/round.err" || fail "fake DONE round did not finish cleanly"
[ -s "$SANDBOX/launcher-called" ] || fail "loop did not invoke launcher"
[ "$(git -C "$ROUND_REPO" branch --show-current)" = "pm-loop/$ROUND_GOAL" ] || fail "loop branch was not created"

echo "PASS: unattended PM loop safety"
