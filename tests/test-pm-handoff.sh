#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$SCRIPT_DIR/../.claude/skills/pm-orchestrator/scripts/pm-handoff.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "expected '$1' to equal '$2'"
}

[ -x "$SCRIPT" ] || fail "pm-handoff.sh is missing or not executable"

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/pm-handoff-test.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM

REPO="$SANDBOX/repo"
WORKTREE="$SANDBOX/worktree"
OTHER_REPO="$SANDBOX/other-repo"

git init -q "$REPO"
git -C "$REPO" config user.email "pm-handoff-test@example.invalid"
git -C "$REPO" config user.name "PM Handoff Test"
printf '%s\n' "handoff test" > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm "test fixture"
git -C "$REPO" worktree add -q -b task/handoff-test "$WORKTREE"

ROOT_MAIN=$(cd "$REPO" && "$SCRIPT" root)
ROOT_WORKTREE=$(cd "$WORKTREE" && "$SCRIPT" root)
assert_eq "$ROOT_MAIN" "$ROOT_WORKTREE"

git init -q "$OTHER_REPO"
ROOT_OTHER=$(cd "$OTHER_REPO" && "$SCRIPT" root)
[ "$ROOT_MAIN" != "$ROOT_OTHER" ] || fail "different repositories shared one handoff root"

TASK_ONE=$(cd "$REPO" && "$SCRIPT" new gameplay-review)
TASK_TWO=$(cd "$WORKTREE" && "$SCRIPT" new gameplay-review)
[ "$TASK_ONE" != "$TASK_TWO" ] || fail "rapid task creation produced duplicate IDs"

printf '%s\n' "leader checkpoint one" | (cd "$REPO" && "$SCRIPT" write "$TASK_ONE" leader)
printf '%s\n' "leader checkpoint two" | (cd "$WORKTREE" && "$SCRIPT" write "$TASK_TWO" leader)
REPORT=$(cd "$WORKTREE" && "$SCRIPT" read "$TASK_ONE" leader)
assert_eq "$REPORT" "leader checkpoint one"

if (cd "$REPO" && "$SCRIPT" read >/dev/null 2>&1); then
  fail "ambiguous recovery selected one of multiple active tasks"
fi

printf '%s\n' "agent checkpoint" | (cd "$WORKTREE" && "$SCRIPT" write "$TASK_ONE" dev-ui)
AGENT_REPORT=$(cd "$REPO" && "$SCRIPT" read "$TASK_ONE" dev-ui)
assert_eq "$AGENT_REPORT" "agent checkpoint"

if printf '%s\n' "ANTHROPIC_API_KEY=secret-value" | (cd "$REPO" && "$SCRIPT" write "$TASK_ONE" risk) >/dev/null 2>&1; then
  fail "secret-looking content was accepted"
fi

if awk 'BEGIN { for (i = 0; i < 4001; i++) printf "a" }' | (cd "$REPO" && "$SCRIPT" write "$TASK_ONE" test) >/dev/null 2>&1; then
  fail "oversized content was accepted"
fi

cd "$REPO" && "$SCRIPT" complete "$TASK_TWO" >/dev/null
AUTO_REPORT=$(cd "$WORKTREE" && "$SCRIPT" read)
assert_eq "$AUTO_REPORT" "leader checkpoint one"

PATH_OUTPUT=$(cd "$REPO" && "$SCRIPT" path "$TASK_ONE" leader)
[ -s "$PATH_OUTPUT" ] || fail "leader handoff path is missing or empty"

cd "$WORKTREE" && "$SCRIPT" complete "$TASK_ONE" >/dev/null
ACTIVE=$(cd "$REPO" && "$SCRIPT" list)
assert_eq "$ACTIVE" "No active PM handoff tasks."

echo "PASS: pm-handoff integration"
