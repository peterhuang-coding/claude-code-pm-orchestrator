#!/bin/sh
set -eu

MAX_CHARS=${PM_HANDOFF_MAX_CHARS:-4000}

die() {
  echo "pm-handoff: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  pm-handoff.sh root
  pm-handoff.sh new <task-slug>
  pm-handoff.sh list
  pm-handoff.sh write <task-id> <leader|agent-role>  # reads stdin
  pm-handoff.sh read [task-id] [leader|agent-role]
  pm-handoff.sh path [task-id] [leader|agent-role]
  pm-handoff.sh complete <task-id>
EOF
  exit 2
}

validate_id() {
  case "${1:-}" in
    ""|*[!A-Za-z0-9._-]*) die "invalid identifier: ${1:-<empty>}" ;;
  esac
}

handoff_root() {
  if [ -n "${PM_HANDOFF_ROOT:-}" ]; then
    case "$PM_HANDOFF_ROOT" in
      /*) printf '%s\n' "$PM_HANDOFF_ROOT" ;;
      *) printf '%s\n' "$PWD/$PM_HANDOFF_ROOT" ;;
    esac
    return
  fi

  if COMMON_DIR=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    printf '%s/pm-handoffs\n' "$COMMON_DIR"
  else
    printf '%s/.claude/pm-handoffs\n' "$PWD"
  fi
}

ROOT=$(handoff_root)
mkdir -p "$ROOT"

active_count() {
  ACTIVE_COUNT=0
  ACTIVE_TASK=""
  for MARKER in "$ROOT"/*/.active; do
    [ -f "$MARKER" ] || continue
    ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
    ACTIVE_TASK=$(basename "$(dirname "$MARKER")")
  done
}

resolve_task() {
  REQUESTED=${1:-}
  if [ -n "$REQUESTED" ]; then
    validate_id "$REQUESTED"
    [ -d "$ROOT/$REQUESTED" ] || die "unknown task: $REQUESTED"
    RESOLVED_TASK=$REQUESTED
    return
  fi

  active_count
  case "$ACTIVE_COUNT" in
    0) die "no active PM handoff tasks" ;;
    1) RESOLVED_TASK=$ACTIVE_TASK ;;
    *)
      echo "Multiple active PM handoff tasks; pass an explicit task ID:" >&2
      list_tasks >&2
      exit 2
      ;;
  esac
}

target_path() {
  TASK=$1
  ROLE=${2:-leader}
  validate_id "$ROLE"
  if [ "$ROLE" = "leader" ]; then
    TARGET="$ROOT/$TASK/leader.md"
  else
    TARGET="$ROOT/$TASK/agents/$ROLE.md"
  fi
}

list_tasks() {
  FOUND=0
  for MARKER in "$ROOT"/*/.active; do
    [ -f "$MARKER" ] || continue
    FOUND=1
    TASK=$(basename "$(dirname "$MARKER")")
    printf '%s\n' "$TASK"
  done
  [ "$FOUND" -eq 1 ] || echo "No active PM handoff tasks."
}

new_task() {
  RAW_SLUG=${1:-task}
  SLUG=$(printf '%s' "$RAW_SLUG" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9._-')
  [ -n "$SLUG" ] || SLUG=task
  STAMP=$(date '+%Y%m%d-%H%M%S')
  BASE_ID="$STAMP-$SLUG-$$"
  TASK_ID=$BASE_ID
  SUFFIX=0
  while [ -e "$ROOT/$TASK_ID" ]; do
    SUFFIX=$((SUFFIX + 1))
    TASK_ID="$BASE_ID-$SUFFIX"
  done

  mkdir -p "$ROOT/$TASK_ID/agents"
  date -u '+%Y-%m-%dT%H:%M:%SZ' > "$ROOT/$TASK_ID/.active"
  LATEST_TMP="$ROOT/.LATEST.$$"
  printf '%s\n' "$TASK_ID" > "$LATEST_TMP"
  mv -f "$LATEST_TMP" "$ROOT/LATEST"
  printf '%s\n' "$TASK_ID"
}

write_report() {
  TASK=$1
  ROLE=$2
  resolve_task "$TASK"
  target_path "$RESOLVED_TASK" "$ROLE"
  mkdir -p "$(dirname "$TARGET")"
  TMP="$TARGET.tmp.$$"
  trap 'rm -f "$TMP"' EXIT HUP INT TERM
  cat > "$TMP"

  [ -s "$TMP" ] || die "refusing to write an empty handoff"
  CHARS=$(wc -m < "$TMP" | tr -d '[:space:]')
  [ "$CHARS" -le "$MAX_CHARS" ] || die "handoff has $CHARS characters; maximum is $MAX_CHARS"

  if grep -Eiq '(sk-[A-Za-z0-9_-]{16,}|(api[_-]?key|auth[_-]?token)[[:space:]]*[:=][[:space:]]*[^<[:space:]]+)' "$TMP"; then
    die "handoff appears to contain a secret"
  fi

  mv -f "$TMP" "$TARGET"
  trap - EXIT HUP INT TERM
  printf '%s\n' "$TARGET"
}

read_report() {
  resolve_task "${1:-}"
  target_path "$RESOLVED_TASK" "${2:-leader}"
  [ -s "$TARGET" ] || die "handoff is missing or empty: $TARGET"
  cat "$TARGET"
}

show_path() {
  resolve_task "${1:-}"
  target_path "$RESOLVED_TASK" "${2:-leader}"
  printf '%s\n' "$TARGET"
}

complete_task() {
  TASK=$1
  resolve_task "$TASK"
  LEADER="$ROOT/$RESOLVED_TASK/leader.md"
  [ -s "$LEADER" ] || die "cannot complete without a non-empty leader handoff"
  date -u '+%Y-%m-%dT%H:%M:%SZ' > "$ROOT/$RESOLVED_TASK/.complete"
  rm -f "$ROOT/$RESOLVED_TASK/.active"
  printf '%s\n' "$RESOLVED_TASK"
}

COMMAND=${1:-}
case "$COMMAND" in
  root)
    [ "$#" -eq 1 ] || usage
    printf '%s\n' "$ROOT"
    ;;
  new)
    [ "$#" -eq 2 ] || usage
    new_task "$2"
    ;;
  list)
    [ "$#" -eq 1 ] || usage
    list_tasks
    ;;
  write)
    [ "$#" -eq 3 ] || usage
    validate_id "$2"
    validate_id "$3"
    write_report "$2" "$3"
    ;;
  read)
    [ "$#" -le 3 ] || usage
    read_report "${2:-}" "${3:-leader}"
    ;;
  path)
    [ "$#" -le 3 ] || usage
    show_path "${2:-}" "${3:-leader}"
    ;;
  complete)
    [ "$#" -eq 2 ] || usage
    validate_id "$2"
    complete_task "$2"
    ;;
  *) usage ;;
esac
