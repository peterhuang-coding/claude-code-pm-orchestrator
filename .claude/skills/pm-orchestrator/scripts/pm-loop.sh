#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HANDOFF_TOOL=${PM_HANDOFF_TOOL:-"$SCRIPT_DIR/pm-handoff.sh"}
GOAL_TOOL=${PM_GOAL_TOOL:-"$SCRIPT_DIR/pm-goal.sh"}
LAUNCHER=${PM_CLAUDE_LAUNCHER:-"$SCRIPT_DIR/launch-claude-glm.sh"}
UNTIL=
GOAL_ID=
MAX_ROUNDS=${PM_LOOP_MAX_ROUNDS:-1000}
SLEEP_SECONDS=${PM_LOOP_SLEEP_SECONDS:-10}
ALLOW_DIRTY=0
MAX_LOG_BYTES=${PM_LOOP_MAX_LOG_BYTES:-12000}

die() {
  echo "pm-loop: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  pm-loop.sh --until <ISO-8601 time> [--goal-id <Goal ID>] [--max-rounds N]
             [--sleep-seconds N] [--allow-dirty]
EOF
  exit 2
}

resolve_tool() {
  NAME=$1
  ENV_VALUE=$2
  GLOBAL_PATH=$3
  if [ -x ".claude/skills/pm-orchestrator/scripts/$NAME" ]; then
    printf '%s\n' ".claude/skills/pm-orchestrator/scripts/$NAME"
  elif [ -n "$ENV_VALUE" ] && [ -x "$ENV_VALUE" ]; then
    printf '%s\n' "$ENV_VALUE"
  elif [ -x "$HOME/.claude/skills/pm-orchestrator/scripts/$NAME" ]; then
    printf '%s\n' "$HOME/.claude/skills/pm-orchestrator/scripts/$NAME"
  elif [ -x "$GLOBAL_PATH" ]; then
    printf '%s\n' "$GLOBAL_PATH"
  else
    die "cannot resolve $NAME; run the global installer"
  fi
}

parse_deadline() {
  VALUE=$1
  case "$VALUE" in
    *T??:??) VALUE="$VALUE:00" ;;
  esac

  if PARSED=$(date -j -f '%Y-%m-%dT%H:%M:%S' "$VALUE" '+%s' 2>/dev/null); then
    printf '%s\n' "$PARSED"
    return
  fi

  OFFSET_VALUE=$(printf '%s' "$VALUE" | sed -E 's/([+-][0-9][0-9]):([0-9][0-9])$/\1\2/')
  if PARSED=$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "$OFFSET_VALUE" '+%s' 2>/dev/null); then
    printf '%s\n' "$PARSED"
    return
  fi

  if PARSED=$(date -d "$VALUE" '+%s' 2>/dev/null); then
    printf '%s\n' "$PARSED"
    return
  fi
  die "invalid deadline: $1"
}

positive_int() {
  case "$2" in
    ''|*[!0-9]*) die "$1 must be a non-negative integer" ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --until)
      [ "$#" -ge 2 ] || usage
      UNTIL=$2
      shift 2
      ;;
    --goal-id)
      [ "$#" -ge 2 ] || usage
      GOAL_ID=$2
      shift 2
      ;;
    --max-rounds)
      [ "$#" -ge 2 ] || usage
      MAX_ROUNDS=$2
      shift 2
      ;;
    --sleep-seconds)
      [ "$#" -ge 2 ] || usage
      SLEEP_SECONDS=$2
      shift 2
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    *)
      usage
      ;;
  esac
done

[ -n "$UNTIL" ] || die "--until is required"
positive_int '--max-rounds' "$MAX_ROUNDS"
positive_int '--sleep-seconds' "$SLEEP_SECONDS"
[ "$MAX_ROUNDS" -gt 0 ] || die '--max-rounds must be greater than zero'

HANDOFF_TOOL=$(resolve_tool pm-handoff.sh "${PM_HANDOFF_TOOL:-}" "$SCRIPT_DIR/pm-handoff.sh")
GOAL_TOOL=$(resolve_tool pm-goal.sh "${PM_GOAL_TOOL:-}" "$SCRIPT_DIR/pm-goal.sh")
LAUNCHER=$(resolve_tool launch-claude-glm.sh "${PM_CLAUDE_LAUNCHER:-}" "$SCRIPT_DIR/launch-claude-glm.sh")
export PM_HANDOFF_TOOL PM_GOAL_TOOL PM_CLAUDE_LAUNCHER

DEADLINE_EPOCH=$(parse_deadline "$UNTIL")
NOW_EPOCH=$(date '+%s')
[ "$DEADLINE_EPOCH" -gt "$NOW_EPOCH" ] || {
  printf 'deadline reached: %s\n' "$UNTIL"
  exit 0
}

ROOT=$($HANDOFF_TOOL root)
[ -n "$GOAL_ID" ] || die '--goal-id is required for unattended execution'
GOAL_STATUS=$($GOAL_TOOL status "$GOAL_ID") || die "cannot read Goal $GOAL_ID"
STATUS=$(printf '%s\n' "$GOAL_STATUS" | sed -n 's/^goal_id=[^ ]* status=\([^ ]*\)$/\1/p')
[ "$STATUS" = approved ] || die "Goal $GOAL_ID must be approved before loop start; current status=$STATUS"
GOAL_BRIEF=$($GOAL_TOOL read "$GOAL_ID")
[ -n "$GOAL_BRIEF" ] || die "Goal $GOAL_ID brief is empty"

TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null) || die 'current directory is not a Git repository'
COMMON_DIR=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || die 'cannot resolve Git common directory'
START_BRANCH=$(git branch --show-current)
[ -n "$START_BRANCH" ] || die 'detached HEAD is not supported for unattended loop'
if [ "$ALLOW_DIRTY" -ne 1 ] && [ -n "$(git status --porcelain)" ]; then
  die 'worktree is dirty; commit changes or pass --allow-dirty explicitly'
fi

LOCK=${PM_LOOP_LOCK:-"$COMMON_DIR/pm-loop.lock"}
mkdir -p "$(dirname "$LOCK")"
if ! mkdir "$LOCK" 2>/dev/null; then
  die "another PM loop owns this repository: $LOCK"
fi

cleanup() {
  rm -rf "$LOCK"
}
trap cleanup EXIT HUP INT TERM
printf '%s\n' "$$" > "$LOCK/pid"
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$LOCK/started-at"

BRANCH="pm-loop/$GOAL_ID"
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  die "loop branch already exists: $BRANCH"
fi
git switch -c "$BRANCH" >/dev/null
$GOAL_TOOL start "$GOAL_ID" >/dev/null

TASK_DIR="$ROOT/$GOAL_ID"
ROUNDS_DIR="$TASK_DIR/rounds"
mkdir -p "$ROUNDS_DIR"
ROUND=0
TRANSPORT_FAILURES=0
VALIDATION_FAILURES=0

write_round_handoff() {
  SUMMARY=$1
  printf '%s\n' "$SUMMARY" > "$ROUNDS_DIR/round-$ROUND.md"
  printf '%s\n' "$SUMMARY" | $HANDOFF_TOOL write "$GOAL_ID" "loop-$ROUND" >/dev/null
  if [ ! -s "$TASK_DIR/leader.md" ]; then
    printf '%s\n' "$SUMMARY" | $HANDOFF_TOOL write "$GOAL_ID" leader >/dev/null
  fi
}

while :; do
  NOW_EPOCH=$(date '+%s')
  if [ "$NOW_EPOCH" -ge "$DEADLINE_EPOCH" ]; then
    printf 'deadline reached: %s\n' "$UNTIL"
    exit 0
  fi
  if [ "$ROUND" -ge "$MAX_ROUNDS" ]; then
    printf 'max rounds reached: %s\n' "$MAX_ROUNDS"
    exit 0
  fi

  ROUND=$((ROUND + 1))
  PROMPT_FILE="$ROUNDS_DIR/round-$ROUND.prompt"
  RAW_OUTPUT="$ROUNDS_DIR/round-$ROUND.raw"
  OUTPUT="$ROUNDS_DIR/round-$ROUND.log"
  cat > "$PROMPT_FILE" <<EOF
You are running round $ROUND of an unattended PM development loop.
Project root: $TOPLEVEL
Goal ID: $GOAL_ID
Loop branch: $BRANCH
Deadline: $UNTIL

Approved Goal brief:
$GOAL_BRIEF

Rules:
- Work only inside this repository and the approved Goal scope.
- Choose the highest-value unfinished improvement supported by the brief.
- Inspect only needed files.
- Write or update a focused test before behavior changes when practical.
- Run the strongest available validation after changes.
- Do not touch secrets, production deployment, unrelated repositories, or delete user changes.
- Commit only verified changes on the current loop branch.
- Write the compact leader/agent handoff with changed paths, commit, tests, risks, and exactly one next action.
- End your response with exactly one line: CONTINUE, DONE, or BLOCKED.

Return a concise round summary. Do not include full files or long logs.
EOF

  set +e
  "$LAUNCHER" --print --no-session-persistence -p "$(cat "$PROMPT_FILE")" > "$RAW_OUTPUT" 2>&1
  CLAUDE_RC=$?
  set -e
  tail -c "$MAX_LOG_BYTES" "$RAW_OUTPUT" | sed -E 's/sk-[A-Za-z0-9_-]{16,}/[REDACTED]/g' > "$OUTPUT"
  rm -f "$RAW_OUTPUT" "$PROMPT_FILE"
  MARKER=$(grep -E '^(CONTINUE|DONE|BLOCKED)$' "$OUTPUT" | tail -n 1 || true)
  COMMIT=$(git rev-parse --short HEAD 2>/dev/null || printf 'none')
  SUMMARY=$(printf 'Goal ID: %s\nRound: %s\nMarker: %s\nClaude exit: %s\nBranch: %s\nCommit: %s\nLog: %s\n' "$GOAL_ID" "$ROUND" "${MARKER:-MISSING}" "$CLAUDE_RC" "$BRANCH" "$COMMIT" "$OUTPUT")
  write_round_handoff "$SUMMARY"

  if [ "$CLAUDE_RC" -ne 0 ]; then
    TRANSPORT_FAILURES=$((TRANSPORT_FAILURES + 1))
    if [ "$TRANSPORT_FAILURES" -ge 3 ]; then
      printf '%s\n' 'three consecutive Claude transport failures' | "$GOAL_TOOL" block "$GOAL_ID" >/dev/null
      die 'three consecutive Claude transport failures'
    fi
    sleep "$SLEEP_SECONDS"
    continue
  fi
  TRANSPORT_FAILURES=0

  case "$MARKER" in
    DONE)
      "$GOAL_TOOL" complete "$GOAL_ID" >/dev/null
      printf 'goal completed: %s\n' "$GOAL_ID"
      exit 0
      ;;
    BLOCKED)
      printf '%s\n' "$SUMMARY" | "$GOAL_TOOL" block "$GOAL_ID" >/dev/null
      die "Claude reported BLOCKED; see $OUTPUT"
      ;;
    CONTINUE)
      VALIDATION_FAILURES=0
      ;;
    *)
      VALIDATION_FAILURES=$((VALIDATION_FAILURES + 1))
      if [ "$VALIDATION_FAILURES" -ge 3 ]; then
        printf '%s\n' 'three rounds returned no valid terminal marker' | "$GOAL_TOOL" block "$GOAL_ID" >/dev/null
        die 'three rounds returned no valid terminal marker'
      fi
      ;;
  esac
  sleep "$SLEEP_SECONDS"
done
