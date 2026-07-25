#!/bin/sh
set -eu

HUB=${PM_HUB_HOME:-/Volumes/SanDisk2TB/claude-pm-hub}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
HUB_TOOL=${PM_HUB_TOOL:-"$SCRIPT_DIR/pm-hub.sh"}
MAX_BYTES=12000
MAX_DASHBOARD_BYTES=12000

die() {
  echo "pm-feature: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  pm-feature.sh new <slug> <brief-file> [project-path]
  pm-feature.sh status <feature-id> [project-path]
  pm-feature.sh read <feature-id> [project-path]
  pm-feature.sh list [project-path]
  pm-feature.sh update <feature-id> <state> <note-file> [project-path]
  pm-feature.sh dashboard [project-path|--all]
EOF
}

contains_secret() {
  grep -Eiq \
    '(sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|[A-Z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL)[A-Z0-9_]*[[:space:]]*[:=][[:space:]]*[^<[:space:]]+)' \
    "$1"
}

validate_file() {
  SOURCE=$1
  LABEL=$2
  [ -f "$SOURCE" ] || die "$LABEL file does not exist: $SOURCE"
  SIZE=$(wc -c < "$SOURCE" | tr -d ' ')
  [ "$SIZE" -le "$MAX_BYTES" ] || die "$LABEL exceeds $MAX_BYTES bytes"
  contains_secret "$SOURCE" && die "$LABEL appears to contain a secret"
  return 0
}

project_for_path() {
  CLASSIFICATION=$("$HUB_TOOL" classify "${1:-$PWD}")
  KIND=$(printf '%s\n' "$CLASSIFICATION" | cut -f1)
  [ "$KIND" = project ] || die "path is not a registered project: ${1:-$PWD}"
  PROJECT_ID=$(printf '%s\n' "$CLASSIFICATION" | cut -f2)
  PROJECT_PATH=$(printf '%s\n' "$CLASSIFICATION" | cut -f3-)
  FEATURE_ROOT="$HUB/projects/$PROJECT_ID/features"
  mkdir -p "$FEATURE_ROOT"
}

feature_dir() {
  case "$1" in
    ""|*[!A-Za-z0-9-]*) die "invalid feature id" ;;
  esac
  FEATURE_DIR="$FEATURE_ROOT/$1"
  [ -d "$FEATURE_DIR" ] || die "unknown feature: $1"
}

valid_state() {
  case "$1" in
    backlog|ready|running|needs-input|review|blocked|paused|done) return 0 ;;
    *) return 1 ;;
  esac
}

transition_allowed() {
  case "$1:$2" in
    backlog:ready|backlog:paused|ready:running|ready:blocked|ready:paused|running:needs-input|running:review|running:blocked|running:paused|needs-input:running|needs-input:blocked|needs-input:paused|review:running|review:done|review:blocked|blocked:ready|blocked:running|blocked:paused|paused:ready|paused:running) return 0 ;;
    *) return 1 ;;
  esac
}

timestamp() {
  date '+%Y-%m-%d %H:%M:%S %z'
}

new_feature() {
  SLUG=$1
  BRIEF=$2
  PROJECT=${3:-$PWD}
  case "$SLUG" in
    ""|*[!a-z0-9-]*|-*|*-) die "slug must use lowercase letters, digits, and internal hyphens" ;;
  esac
  validate_file "$BRIEF" "brief"
  project_for_path "$PROJECT"
  FEATURE_ID="F-$(date '+%Y%m%d-%H%M%S')-$SLUG-$$"
  FEATURE_DIR="$FEATURE_ROOT/$FEATURE_ID"
  mkdir -p "$FEATURE_DIR/updates"
  cp "$BRIEF" "$FEATURE_DIR/feature.md"
  printf 'ready\n' > "$FEATURE_DIR/status"
  timestamp > "$FEATURE_DIR/created-at"
  cp "$FEATURE_DIR/created-at" "$FEATURE_DIR/updated-at"
  printf '%s\n' "$FEATURE_ID"
}

status_feature() {
  project_for_path "${2:-$PWD}"
  feature_dir "$1"
  cat "$FEATURE_DIR/status"
}

read_feature() {
  project_for_path "${2:-$PWD}"
  feature_dir "$1"
  cat "$FEATURE_DIR/feature.md"
  printf '\nStatus: %s\nUpdated: %s\n' \
    "$(cat "$FEATURE_DIR/status")" "$(cat "$FEATURE_DIR/updated-at")"
  LATEST_UPDATE=$(find "$FEATURE_DIR/updates" -type f -name '*.md' -print 2>/dev/null | sort -r | sed -n '1p')
  if [ -n "$LATEST_UPDATE" ]; then
    printf '\n## Latest Update\n\n'
    dd if="$LATEST_UPDATE" bs=1 count="$MAX_BYTES" 2>/dev/null
    printf '\n'
  fi
}

list_features() {
  project_for_path "${1:-$PWD}"
  [ -d "$FEATURE_ROOT" ] || return 0
  for DIR in "$FEATURE_ROOT"/F-*; do
    [ -d "$DIR" ] || continue
    printf '%s\t%s\t%s\n' \
      "$(basename "$DIR")" "$(cat "$DIR/status")" "$(cat "$DIR/updated-at")"
  done
}

update_feature() {
  ID=$1
  NEXT=$2
  NOTE=$3
  PROJECT=${4:-$PWD}
  valid_state "$NEXT" || die "invalid state: $NEXT"
  validate_file "$NOTE" "update"
  project_for_path "$PROJECT"
  feature_dir "$ID"
  LOCK_DIR="$FEATURE_DIR/.update-lock"
  ATTEMPT=0
  until mkdir "$LOCK_DIR" 2>/dev/null; do
    if [ -f "$LOCK_DIR/owner" ]; then
      OWNER_PID=$(cut -f1 "$LOCK_DIR/owner" 2>/dev/null || true)
      OWNER_TIME=$(cut -f2 "$LOCK_DIR/owner" 2>/dev/null || true)
      NOW=$(date '+%s')
      STALE=0
      case "$OWNER_PID:$OWNER_TIME" in
        *[!0-9:]*|:*) STALE=1 ;;
        *)
          [ $((NOW - OWNER_TIME)) -le 300 ] || STALE=1
          kill -0 "$OWNER_PID" 2>/dev/null || STALE=1
          ;;
      esac
      if [ "$STALE" -eq 1 ]; then
        rm -f "$LOCK_DIR/owner"
        rmdir "$LOCK_DIR" 2>/dev/null || true
        continue
      fi
    fi
    ATTEMPT=$((ATTEMPT + 1))
    [ "$ATTEMPT" -lt 200 ] || die "timed out waiting for feature lock"
    sleep 0.05
  done
  printf '%s\t%s\n' "$$" "$(date '+%s')" > "$LOCK_DIR/owner"
  trap 'rm -f "$LOCK_DIR/owner"; rmdir "$LOCK_DIR" 2>/dev/null || true' 0 HUP INT TERM
  CURRENT=$(cat "$FEATURE_DIR/status")
  [ "$CURRENT" != done ] || die "completed features are immutable"
  [ "$CURRENT" = "$NEXT" ] || transition_allowed "$CURRENT" "$NEXT" ||
    die "invalid transition: $CURRENT -> $NEXT"
  STAMP=$(date '+%Y%m%d-%H%M%S')
  cp "$NOTE" "$FEATURE_DIR/updates/$STAMP-$$.md"
  printf '%s\n' "$NEXT" > "$FEATURE_DIR/status.tmp.$$"
  mv -f "$FEATURE_DIR/status.tmp.$$" "$FEATURE_DIR/status"
  timestamp > "$FEATURE_DIR/updated-at.tmp.$$"
  mv -f "$FEATURE_DIR/updated-at.tmp.$$" "$FEATURE_DIR/updated-at"
  rm -f "$LOCK_DIR/owner"
  rmdir "$LOCK_DIR"
  trap - 0 HUP INT TERM
  printf '%s\n' "$FEATURE_DIR"
}

dashboard_project() {
  project_for_path "$1"
  printf '## %s\n\n' "$PROJECT_ID"
  printf -- '- Path: %s\n' "$PROJECT_PATH"
  FOUND=0
  for STATE in needs-input review blocked running ready paused backlog done; do
    for DIR in "$FEATURE_ROOT"/F-*; do
      [ -d "$DIR" ] || continue
      [ "$(cat "$DIR/status")" = "$STATE" ] || continue
      printf -- '- [%s] %s | %s\n' "$STATE" "$(basename "$DIR")" "$(cat "$DIR/updated-at")"
      LATEST_UPDATE=$(find "$DIR/updates" -type f -name '*.md' -print 2>/dev/null | sort -r | sed -n '1p')
      if [ -n "$LATEST_UPDATE" ]; then
        printf '  Latest: '
        dd if="$LATEST_UPDATE" bs=1 count=800 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g'
        printf '\n'
      fi
      FOUND=1
    done
  done
  [ "$FOUND" -eq 1 ] || printf -- '- No tracked features\n'
}

dashboard_all() {
  "$HUB_TOOL" init >/dev/null
  while IFS='	' read -r ID PATH_VALUE; do
    [ -n "$ID" ] || continue
    dashboard_project "$PATH_VALUE"
    printf '\n'
  done < "$HUB/config/projects.tsv"
}

COMMAND=${1:-}
case "$COMMAND" in
  new)
    [ "$#" -ge 3 ] || die "new requires slug and brief file"
    new_feature "$2" "$3" "${4:-$PWD}"
    ;;
  status)
    [ "$#" -ge 2 ] || die "status requires a feature id"
    status_feature "$2" "${3:-$PWD}"
    ;;
  read)
    [ "$#" -ge 2 ] || die "read requires a feature id"
    read_feature "$2" "${3:-$PWD}"
    ;;
  list) list_features "${2:-$PWD}" ;;
  update)
    [ "$#" -ge 4 ] || die "update requires feature id, state, and note file"
    update_feature "$2" "$3" "$4" "${5:-$PWD}"
    ;;
  dashboard)
    if [ "${2:-}" = "--all" ]; then
      dashboard_all | dd bs=1 count="$MAX_DASHBOARD_BYTES" 2>/dev/null
    else
      dashboard_project "${2:-$PWD}" | dd bs=1 count="$MAX_DASHBOARD_BYTES" 2>/dev/null
    fi
    ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
