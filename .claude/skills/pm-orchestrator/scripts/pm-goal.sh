#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HANDOFF_TOOL=${PM_HANDOFF_TOOL:-"$SCRIPT_DIR/pm-handoff.sh"}
MAX_CHARS=${PM_GOAL_MAX_CHARS:-12000}

die() {
  echo "pm-goal: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  pm-goal.sh new <slug>       # reads initial request from stdin
  pm-goal.sh brief <goal-id>  # reads goal brief from stdin
  pm-goal.sh approve <goal-id> # reads approval note from stdin
  pm-goal.sh start <goal-id>
  pm-goal.sh status [goal-id]
  pm-goal.sh read [goal-id]
  pm-goal.sh stop <goal-id>
  pm-goal.sh block <goal-id>   # reads blocking note from stdin
  pm-goal.sh complete <goal-id>
  pm-goal.sh path [goal-id]
EOF
  exit 2
}

validate_id() {
  case "${1:-}" in
    ""|*[!A-Za-z0-9._-]*) die "invalid Goal ID: ${1:-<empty>}" ;;
  esac
}

root_path() {
  ROOT=$("$HANDOFF_TOOL" root)
  printf '%s\n' "$ROOT"
}

resolve_goal() {
  REQUESTED=${1:-}
  ROOT=$(root_path)
  if [ -n "$REQUESTED" ]; then
    validate_id "$REQUESTED"
    [ -d "$ROOT/$REQUESTED" ] || die "unknown Goal: $REQUESTED"
    GOAL_ID=$REQUESTED
    return
  fi

  [ -s "$ROOT/LATEST" ] || die "no Goal ID provided and no latest task exists"
  GOAL_ID=$(cat "$ROOT/LATEST")
  validate_id "$GOAL_ID"
  [ -f "$ROOT/$GOAL_ID/.goal-status" ] || die "latest task is not a Goal; pass an explicit Goal ID"
}

goal_dir() {
  printf '%s/%s\n' "$ROOT" "$GOAL_ID"
}

read_input() {
  TMP=$(mktemp "${TMPDIR:-/tmp}/pm-goal-input.XXXXXX")
  trap 'rm -f "$TMP"' EXIT HUP INT TERM
  cat > "$TMP"
  [ -s "$TMP" ] || die "refusing empty input"
  if ! grep -q '[^[:space:]]' "$TMP"; then
    die "refusing whitespace-only input"
  fi
  CHARS=$(wc -m < "$TMP" | tr -d '[:space:]')
  [ "$CHARS" -le "$MAX_CHARS" ] || die "input has $CHARS characters; maximum is $MAX_CHARS"
  if grep -Eiq '(sk-[A-Za-z0-9_-]{16,}|(api[_-]?key|auth[_-]?token)[[:space:]]*[:=][[:space:]]*[^<[:space:]]+)' "$TMP"; then
    die "input appears to contain a secret"
  fi
}

write_atomic() {
  TARGET=$1
  SOURCE=$2
  TMP_TARGET="$TARGET.tmp.$$"
  cp "$SOURCE" "$TMP_TARGET"
  mv -f "$TMP_TARGET" "$TARGET"
}

read_status() {
  STATUS=$(cat "$(goal_dir)/.goal-status")
}

set_status() {
  printf '%s\n' "$1" > "$(goal_dir)/.goal-status.tmp.$$"
  mv -f "$(goal_dir)/.goal-status.tmp.$$" "$(goal_dir)/.goal-status"
  if [ -f "$(goal_dir)/goal.md" ]; then
    sed "s/^- Status: .*/- Status: $1/" "$(goal_dir)/goal.md" > "$(goal_dir)/goal.md.tmp.$$"
    mv -f "$(goal_dir)/goal.md.tmp.$$" "$(goal_dir)/goal.md"
  fi
}

new_goal() {
  read_input
  REQUEST=$TMP
  TASK_ID=$("$HANDOFF_TOOL" new "$1")
  ROOT=$(root_path)
  GOAL_ID=$TASK_ID
  DIR=$(goal_dir)
  printf '%s\n' discovery > "$DIR/.goal-status"
  write_atomic "$DIR/.goal-request" "$REQUEST"
  printf '%s\n' "$GOAL_ID"
  trap - EXIT HUP INT TERM
  rm -f "$TMP"
}

write_brief() {
  resolve_goal "$1"
  read_status
  [ "$STATUS" = discovery ] || die "brief can only be written from discovery; current status=$STATUS"
  read_input
  DIR=$(goal_dir)
  TARGET="$DIR/goal.md"
  TMP_TARGET="$TARGET.tmp.$$"
  {
    printf '%s\n' "# Goal Brief"
    printf '%s\n' "- Goal ID: $GOAL_ID"
    printf '%s\n' "- Status: awaiting-approval"
    printf '%s\n' "- Initial request: $DIR/.goal-request"
    printf '%s\n\n' "- Public research only: yes"
    cat "$TMP"
  } > "$TMP_TARGET"
  mv -f "$TMP_TARGET" "$TARGET"
  set_status awaiting-approval
  printf '%s\n' "$TARGET"
  trap - EXIT HUP INT TERM
  rm -f "$TMP"
}

approve_goal() {
  resolve_goal "$1"
  read_status
  [ "$STATUS" = awaiting-approval ] || die "Goal can only be approved from awaiting-approval; current status=$STATUS"
  read_input
  DIR=$(goal_dir)
  write_atomic "$DIR/.approval" "$TMP"
  date -u '+%Y-%m-%dT%H:%M:%SZ' > "$DIR/.approved-at.tmp.$$"
  mv -f "$DIR/.approved-at.tmp.$$" "$DIR/.approved-at"
  printf '%s\n' user > "$DIR/.approved-by"
  set_status approved
  printf '%s\n' "$GOAL_ID"
  trap - EXIT HUP INT TERM
  rm -f "$TMP"
}

start_goal() {
  resolve_goal "$1"
  read_status
  [ "$STATUS" = approved ] || die "Goal can only start from approved; current status=$STATUS"
  set_status executing
  printf '%s\n' "$GOAL_ID"
}

status_goal() {
  resolve_goal "${1:-}"
  read_status
  printf 'goal_id=%s status=%s\n' "$GOAL_ID" "$STATUS"
  printf 'goal_path=%s\n' "$(goal_dir)/goal.md"
  printf 'handoff_path=%s\n' "$(goal_dir)/leader.md"
  if [ -f "$(goal_dir)/.approved-at" ]; then
    printf 'approved_at=%s\n' "$(cat "$(goal_dir)/.approved-at")"
  fi
}

read_goal() {
  resolve_goal "${1:-}"
  [ -s "$(goal_dir)/goal.md" ] || die "Goal brief is missing or empty"
  cat "$(goal_dir)/goal.md"
}

stop_goal() {
  resolve_goal "$1"
  read_status
  case "$STATUS" in
    completed|blocked|stopped) die "Goal cannot be stopped from status=$STATUS" ;;
  esac
  set_status stopped
  printf '%s\n' "$GOAL_ID"
}

block_goal() {
  resolve_goal "$1"
  read_status
  [ "$STATUS" = executing ] || die "Goal can only be blocked from executing; current status=$STATUS"
  read_input
  write_atomic "$(goal_dir)/.blocked-note" "$TMP"
  set_status blocked
  printf '%s\n' "$GOAL_ID"
  trap - EXIT HUP INT TERM
  rm -f "$TMP"
}

complete_goal() {
  resolve_goal "$1"
  read_status
  [ "$STATUS" = executing ] || die "Goal can only complete from executing; current status=$STATUS"
  set_status completed
  printf '%s\n' "$GOAL_ID"
}

COMMAND=${1:-}
case "$COMMAND" in
  new)
    [ "$#" -eq 2 ] || usage
    new_goal "$2"
    ;;
  brief)
    [ "$#" -eq 2 ] || usage
    write_brief "$2"
    ;;
  approve)
    [ "$#" -eq 2 ] || usage
    approve_goal "$2"
    ;;
  start)
    [ "$#" -eq 2 ] || usage
    start_goal "$2"
    ;;
  status)
    [ "$#" -le 2 ] || usage
    status_goal "${2:-}"
    ;;
  read)
    [ "$#" -le 2 ] || usage
    read_goal "${2:-}"
    ;;
  stop)
    [ "$#" -eq 2 ] || usage
    stop_goal "$2"
    ;;
  block)
    [ "$#" -eq 2 ] || usage
    block_goal "$2"
    ;;
  complete)
    [ "$#" -eq 2 ] || usage
    complete_goal "$2"
    ;;
  path)
    [ "$#" -le 2 ] || usage
    resolve_goal "${2:-}"
    printf '%s\n' "$(goal_dir)/goal.md"
    ;;
  *) usage ;;
esac
