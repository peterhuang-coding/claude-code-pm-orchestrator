#!/bin/sh
set -eu

HUB=${PM_HUB_HOME:-/Volumes/SanDisk2TB/claude-pm-hub}
MAX_SUMMARY_BYTES=12000

die() {
  echo "pm-hub: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  pm-hub.sh init
  pm-hub.sh register <project-path> [project-id]
  pm-hub.sh classify [path]
  pm-hub.sh cold-start [path]
  pm-hub.sh wrap-up <project-id> <summary-file>
  pm-hub.sh assign <project-id> <assignment-file>
  pm-hub.sh idea <text> [path]
  pm-hub.sh portfolio
  pm-hub.sh profile [label]
EOF
}

absolute_dir() {
  [ -d "$1" ] || die "directory does not exist: $1"
  (CDPATH= cd -- "$1" && pwd -P)
}

valid_id() {
  case "$1" in
    ""|*[!a-z0-9-]*) return 1 ;;
    *) return 0 ;;
  esac
}

default_id() {
  basename "$1" |
    tr '[:upper:]_' '[:lower:]-' |
    tr -cd 'a-z0-9-' |
    sed 's/--*/-/g; s/^-//; s/-$//'
}

contains_secret() {
  grep -Eiq \
    '(sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|[A-Z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL)[A-Z0-9_]*[[:space:]]*[:=][[:space:]]*[^<[:space:]]+)' \
    "$1"
}

validate_content_file() {
  SOURCE=$1
  LABEL=$2
  [ -f "$SOURCE" ] || die "$LABEL file does not exist: $SOURCE"
  SIZE=$(wc -c < "$SOURCE" | tr -d ' ')
  [ "$SIZE" -le "$MAX_SUMMARY_BYTES" ] || die "$LABEL exceeds $MAX_SUMMARY_BYTES bytes"
  if contains_secret "$SOURCE"; then
    die "$LABEL appears to contain a secret"
  fi
  return 0
}

write_if_missing() {
  TARGET=$1
  shift
  [ -e "$TARGET" ] && return 0
  printf '%s\n' "$@" > "$TARGET"
}

init_hub() {
  mkdir -p "$HUB/config" "$HUB/portfolio" "$HUB/projects"
  : > "$HUB/config/projects.tsv.tmp.$$"
  if [ ! -e "$HUB/config/projects.tsv" ]; then
    mv -f "$HUB/config/projects.tsv.tmp.$$" "$HUB/config/projects.tsv"
  else
    rm -f "$HUB/config/projects.tsv.tmp.$$"
  fi
  write_if_missing "$HUB/config/active-profile" "claude-settings"
  write_if_missing "$HUB/portfolio/ideas.md" "# Portfolio Ideas" ""
  write_if_missing "$HUB/portfolio/feishu-backlog.md" \
    "# Feishu Assistant Backlog" "" \
    "- [ ] Confirm app owner and tenant" \
    "- [ ] Enumerate the minimum document, message, calendar, and knowledge-base scopes" \
    "- [ ] Create the Feishu app and complete user authorization" \
    "- [ ] Add and verify a purpose-built MCP connector" \
    "- [ ] Record approved scopes and verification evidence here"
  write_if_missing "$HUB/README.md" \
    "# Claude PM Hub" "" \
    "Durable multi-project summaries, ideas, assignments, and session records." "" \
    "Secrets do not belong in this directory."
  printf '%s\n' "$HUB"
}

project_line_by_id() {
  ID=$1
  while IFS='	' read -r PROJECT_ID PROJECT_PATH; do
    [ "$PROJECT_ID" = "$ID" ] || continue
    printf '%s\t%s\n' "$PROJECT_ID" "$PROJECT_PATH"
    return 0
  done < "$HUB/config/projects.tsv"
  return 1
}

project_id_for_path() {
  CHECK_PATH=$1
  BEST_ID=
  BEST_PATH=
  while IFS='	' read -r PROJECT_ID PROJECT_PATH; do
    [ -n "$PROJECT_ID" ] || continue
    case "$CHECK_PATH" in
      "$PROJECT_PATH"|"$PROJECT_PATH"/*)
        if [ "${#PROJECT_PATH}" -gt "${#BEST_PATH}" ]; then
          BEST_ID=$PROJECT_ID
          BEST_PATH=$PROJECT_PATH
        fi
        ;;
    esac
  done < "$HUB/config/projects.tsv"
  [ -n "$BEST_ID" ] || return 1
  printf '%s\t%s\n' "$BEST_ID" "$BEST_PATH"
}

ensure_project_files() {
  ID=$1
  PROJECT_PATH=$2
  DIR="$HUB/projects/$ID"
  mkdir -p "$DIR/sessions"
  write_if_missing "$DIR/project.md" \
    "# Project: $ID" "" "- Path: $PROJECT_PATH" "- Registered: $(date '+%Y-%m-%d %H:%M:%S %z')"
  write_if_missing "$DIR/latest.md" \
    "# Latest" "" "- Status: registered" "- Next action: inspect the project"
  write_if_missing "$DIR/ideas.md" "# Ideas" ""
  write_if_missing "$DIR/assignments.md" "# Assignments" ""
}

register_project() {
  init_hub >/dev/null
  PROJECT_PATH=$(absolute_dir "$1")
  ID=${2:-$(default_id "$PROJECT_PATH")}
  valid_id "$ID" || die "project id must contain only lowercase letters, digits, and hyphens"

  if LINE=$(project_line_by_id "$ID" 2>/dev/null); then
    EXISTING_PATH=$(printf '%s\n' "$LINE" | cut -f2-)
    [ "$EXISTING_PATH" = "$PROJECT_PATH" ] || die "project id already points to $EXISTING_PATH"
    ensure_project_files "$ID" "$PROJECT_PATH"
    printf '%s\n' "$ID"
    return 0
  fi

  if LINE=$(project_id_for_path "$PROJECT_PATH" 2>/dev/null); then
    EXISTING_ID=$(printf '%s\n' "$LINE" | cut -f1)
    EXISTING_PATH=$(printf '%s\n' "$LINE" | cut -f2-)
    [ "$EXISTING_PATH" != "$PROJECT_PATH" ] || die "project path is already registered as $EXISTING_ID"
  fi

  printf '%s\t%s\n' "$ID" "$PROJECT_PATH" >> "$HUB/config/projects.tsv"
  ensure_project_files "$ID" "$PROJECT_PATH"
  printf '%s\n' "$ID"
}

classify_path() {
  init_hub >/dev/null
  CHECK_PATH=$(absolute_dir "${1:-$PWD}")
  HUB_PATH=$(absolute_dir "$HUB")
  case "$CHECK_PATH" in
    "$HUB_PATH"|"$HUB_PATH"/*)
      printf 'hub\t%s\n' "$HUB_PATH"
      return 0
      ;;
  esac
  if LINE=$(project_id_for_path "$CHECK_PATH" 2>/dev/null); then
    printf 'project\t%s\n' "$LINE"
  else
    printf 'unknown\t%s\n' "$CHECK_PATH"
  fi
}

bounded_file() {
  FILE=$1
  LIMIT=$2
  [ -f "$FILE" ] || return 0
  dd if="$FILE" bs=1 count="$LIMIT" 2>/dev/null
}

cold_start() {
  CHECK_PATH=${1:-$PWD}
  CLASSIFICATION=$(classify_path "$CHECK_PATH")
  KIND=$(printf '%s\n' "$CLASSIFICATION" | cut -f1)
  ACTIVE_PROFILE=$(cat "$HUB/config/active-profile" 2>/dev/null || printf 'claude-settings')

  case "$KIND" in
    project)
      ID=$(printf '%s\n' "$CLASSIFICATION" | cut -f2)
      PROJECT_PATH=$(printf '%s\n' "$CLASSIFICATION" | cut -f3-)
      printf '你正在进行项目冷启动。使用 pm-orchestrator skill，但先恢复磁盘事实，不恢复旧聊天。\n'
      printf '项目 ID: %s\n项目路径: %s\n模型配置来源: %s（启动器不覆盖模型）\n\n' "$ID" "$PROJECT_PATH" "$ACTIVE_PROFILE"
      printf '## 上次项目摘要\n'
      bounded_file "$HUB/projects/$ID/latest.md" 6000
      printf '\n\n## 待分配任务\n'
      bounded_file "$HUB/projects/$ID/assignments.md" 3000
      if COMMON_DIR=$(git -C "$PROJECT_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
        HANDOFF_ROOT="$COMMON_DIR/pm-handoffs"
        if [ -d "$HANDOFF_ROOT" ]; then
          LATEST_HANDOFF=
          if [ -f "$HANDOFF_ROOT/LATEST" ]; then
            LATEST_TASK=$(sed -n '1p' "$HANDOFF_ROOT/LATEST")
            case "$LATEST_TASK" in
              ""|.|..|*/*) LATEST_TASK= ;;
            esac
            if [ -n "$LATEST_TASK" ] && [ -f "$HANDOFF_ROOT/$LATEST_TASK/leader.md" ]; then
              LATEST_HANDOFF="$HANDOFF_ROOT/$LATEST_TASK/leader.md"
            fi
          fi
          if [ -z "$LATEST_HANDOFF" ]; then
            LATEST_HANDOFF=$(find "$HANDOFF_ROOT" -mindepth 2 -maxdepth 2 -type f -name leader.md -print 2>/dev/null | sort -r | sed -n '1p')
          fi
          if [ -n "$LATEST_HANDOFF" ]; then
            printf '\n\n## 最新 PM Handoff\n'
            bounded_file "$LATEST_HANDOFF" 3000
          fi
        fi
      fi
      printf '\n\n## 当前 Git 状态\n'
      if git -C "$PROJECT_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$PROJECT_PATH" status --short --branch | sed -n '1,80p'
      else
        printf '非 Git 项目\n'
      fi
      printf '\n先用一屏内容向用户汇报：上次做到哪、当前状态、阻塞、下一步。等待用户一句话任务；完成后必须执行 /wrap-up。\n'
      ;;
    hub)
      printf '你正在进行老板总控冷启动。使用 pm-orchestrator skill 和 /portfolio 汇总所有项目。\n'
      printf 'Hub: %s\n模型配置来源: %s（启动器不覆盖模型）\n\n' "$HUB" "$ACTIVE_PROFILE"
      portfolio
      printf '\n先汇报各项目状态、阻塞、下一步和 Portfolio Ideas。可以写 assignments，但跨项目执行必须在对应项目上下文中进行。\n'
      ;;
    unknown)
      UNKNOWN_PATH=$(printf '%s\n' "$CLASSIFICATION" | cut -f2-)
      printf '当前目录尚未注册到 Claude PM Hub: %s\n' "$UNKNOWN_PATH"
      printf '不要自动写入。请提示用户运行 /project-register，并说明注册后可获得冷启动、复盘和 Portfolio 汇总。\n'
      ;;
    *) die "unknown classification: $KIND" ;;
  esac
}

wrap_up() {
  init_hub >/dev/null
  ID=$1
  SOURCE=$2
  project_line_by_id "$ID" >/dev/null 2>&1 || die "unknown project id: $ID"
  validate_content_file "$SOURCE" "summary"

  DIR="$HUB/projects/$ID"
  STAMP=$(date '+%Y%m%d-%H%M%S')
  SESSION="$DIR/sessions/$STAMP-$$.md"
  cp "$SOURCE" "$SESSION"
  cp "$SOURCE" "$DIR/latest.md.tmp.$$"
  mv -f "$DIR/latest.md.tmp.$$" "$DIR/latest.md"
  printf '%s\n' "$SESSION"
}

write_assignment() {
  init_hub >/dev/null
  ID=$1
  SOURCE=$2
  project_line_by_id "$ID" >/dev/null 2>&1 || die "unknown project id: $ID"
  validate_content_file "$SOURCE" "assignment"

  TARGET="$HUB/projects/$ID/assignments.md"
  cp "$SOURCE" "$TARGET.tmp.$$"
  mv -f "$TARGET.tmp.$$" "$TARGET"
  printf '%s\n' "$TARGET"
}

record_idea() {
  init_hub >/dev/null
  TEXT=$1
  [ -n "$TEXT" ] || die "idea text is required"
  [ "${#TEXT}" -le 1000 ] || die "idea exceeds 1000 characters"
  TEMP="$HUB/.idea.$$"
  printf '%s\n' "$TEXT" > "$TEMP"
  if contains_secret "$TEMP"; then
    rm -f "$TEMP"
    die "idea appears to contain a secret"
  fi
  rm -f "$TEMP"

  CLASSIFICATION=$(classify_path "${2:-$PWD}")
  KIND=$(printf '%s\n' "$CLASSIFICATION" | cut -f1)
  case "$KIND" in
    project)
      ID=$(printf '%s\n' "$CLASSIFICATION" | cut -f2)
      TARGET="$HUB/projects/$ID/ideas.md"
      ;;
    hub) TARGET="$HUB/portfolio/ideas.md" ;;
    *) die "register the current directory before recording a project idea" ;;
  esac
  printf -- '- %s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$TEXT" >> "$TARGET"
  printf '%s\n' "$TARGET"
}

portfolio() {
  init_hub >/dev/null
  printf '# Portfolio Snapshot\n\n'
  while IFS='	' read -r ID PROJECT_PATH; do
    [ -n "$ID" ] || continue
    printf '## %s\n\n- Path: %s\n' "$ID" "$PROJECT_PATH"
    if [ -d "$PROJECT_PATH/.git" ] || git -C "$PROJECT_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      BRANCH=$(git -C "$PROJECT_PATH" branch --show-current 2>/dev/null || true)
      DIRTY=$(git -C "$PROJECT_PATH" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
      printf -- '- Git: branch=%s, changed=%s\n\n' "${BRANCH:-detached}" "$DIRTY"
    else
      printf -- '- Git: not available\n\n'
    fi
    bounded_file "$HUB/projects/$ID/latest.md" 5000
    printf '\n\n### Assignments\n\n'
    bounded_file "$HUB/projects/$ID/assignments.md" 2500
    printf '\n\n### Ideas\n\n'
    bounded_file "$HUB/projects/$ID/ideas.md" 2500
    printf '\n\n'
  done < "$HUB/config/projects.tsv"
  printf '## Portfolio Ideas\n\n'
  bounded_file "$HUB/portfolio/ideas.md" 4000
  printf '\n'
}

profile() {
  init_hub >/dev/null
  if [ "$#" -gt 0 ]; then
    [ -n "$1" ] || die "profile label cannot be empty"
    [ "${#1}" -le 120 ] || die "profile label is too long"
    TEMP="$HUB/config/active-profile.tmp.$$"
    printf '%s\n' "$1" > "$TEMP"
    if contains_secret "$TEMP"; then
      rm -f "$TEMP"
      die "profile label appears to contain a secret"
    fi
    mv -f "$TEMP" "$HUB/config/active-profile"
  fi
  cat "$HUB/config/active-profile"
}

COMMAND=${1:-}
case "$COMMAND" in
  init) init_hub ;;
  register)
    [ "$#" -ge 2 ] || die "register requires a project path"
    register_project "$2" "${3:-}"
    ;;
  classify) classify_path "${2:-$PWD}" ;;
  cold-start) cold_start "${2:-$PWD}" ;;
  wrap-up)
    [ "$#" -eq 3 ] || die "wrap-up requires project id and summary file"
    wrap_up "$2" "$3"
    ;;
  assign)
    [ "$#" -eq 3 ] || die "assign requires project id and assignment file"
    write_assignment "$2" "$3"
    ;;
  idea)
    [ "$#" -ge 2 ] || die "idea text is required"
    record_idea "$2" "${3:-$PWD}"
    ;;
  portfolio) portfolio ;;
  profile)
    if [ "$#" -gt 1 ]; then
      profile "$2"
    else
      profile
    fi
    ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
