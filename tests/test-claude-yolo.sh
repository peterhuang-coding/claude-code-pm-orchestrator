#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
YOLO="$ROOT/.claude/skills/pm-orchestrator/scripts/claude-yolo"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -x "$YOLO" ] || fail "claude-yolo is missing or not executable"

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/claude-yolo-test.XXXXXX")
SANDBOX=$(CDPATH= cd -- "$SANDBOX" && pwd -P)
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
HOME_DIR="$SANDBOX/home"
HUB="$SANDBOX/hub"
PROJECT="$SANDBOX/project"
UNKNOWN="$SANDBOX/unknown"
BIN="$SANDBOX/bin"
OUT="$SANDBOX/claude.out"
CAPABILITIES_OUT="$SANDBOX/capabilities.out"
PROVIDER_OUT="$SANDBOX/provider.out"
mkdir -p "$HOME_DIR" "$PROJECT" "$UNKNOWN" "$BIN"
export PM_GLOBAL_BIN="$BIN"
export PM_MINIMAX_API_KEY=fixed-minimax-key

cat > "$BIN/claude" <<'EOF'
#!/bin/sh
set -eu
{
  printf 'PWD=%s\n' "$PWD"
  printf 'PM_FEISHU_BOSS=%s\n' "${PM_FEISHU_BOSS-<unset>}"
  printf 'PM_FEISHU_BOSS_LAUNCH_TOKEN=%s\n' "${PM_FEISHU_BOSS_LAUNCH_TOKEN-<unset>}"
  printf 'ARGS='
  printf '<%s>' "$@"
  printf '\n'
} > "${CLAUDE_YOLO_TEST_OUT:?}"
EOF
chmod +x "$BIN/claude"

cat > "$BIN/minimax-capabilities" <<'EOF'
#!/bin/sh
printf '<%s>\n' "$*" >>"${CLAUDE_YOLO_CAPABILITIES_OUT:?}"
EOF
chmod +x "$BIN/minimax-capabilities"
export PM_MINIMAX_CAPABILITIES_TOOL="$BIN/minimax-capabilities"
export CLAUDE_YOLO_CAPABILITIES_OUT="$CAPABILITIES_OUT"

cat > "$BIN/pm-provider" <<'EOF'
#!/bin/sh
printf '<%s>\n' "$*" >>"${CLAUDE_YOLO_PROVIDER_OUT:?}"
case "${1:-}" in
  status) printf '%s\n' '{"active":false}' ;;
esac
EOF
chmod +x "$BIN/pm-provider"
export PM_PROVIDER_TOOL="$BIN/pm-provider"
export CLAUDE_YOLO_PROVIDER_OUT="$PROVIDER_OUT"

(
  cd "$UNKNOWN"
  HOME="$HOME_DIR" \
  PATH="$BIN:$PATH" \
  PM_HUB_HOME="$HUB" \
  PM_FEISHU_BOSS=1 \
  CLAUDE_YOLO_TEST_OUT="$OUT" \
  "$YOLO" --name unknown-start
)

[ -x "$HOME_DIR/.claude/bin/claude-pm" ] || fail "Skills were not synchronized before launch"
grep -Fxq '<status>' "$CAPABILITIES_OUT" ||
  fail "MiniMax capabilities were not checked before launch"
! grep -Fxq '<install>' "$CAPABILITIES_OUT" ||
  fail "normal launch triggered remote capability installation"
grep -Fxq "PWD=$HUB" "$OUT" || fail "unknown directory did not fall back to Hub"
grep -Fq '<--permission-mode><bypassPermissions>' "$OUT" || fail "YOLO launch omitted bypass permissions"
grep -Fq '<--effort><max>' "$OUT" || fail "YOLO launch omitted max effort"
grep -Fq '<--teammate-mode><in-process>' "$OUT" || fail "YOLO launch omitted Agent Team mode"
grep -Fxq 'PM_FEISHU_BOSS=<unset>' "$OUT" || fail "ordinary launch inherited boss authority"
grep -Fxq 'PM_FEISHU_BOSS_LAUNCH_TOKEN=<unset>' "$OUT" || fail "ordinary launch inherited boss token"

HOME="$HOME_DIR" PM_HUB_HOME="$HUB" \
  "$HOME_DIR/.claude/skills/pm-orchestrator/scripts/pm-hub.sh" register "$PROJECT" sample >/dev/null

(
  cd "$PROJECT"
  HOME="$HOME_DIR" \
  PATH="$BIN:$PATH" \
  PM_HUB_HOME="$HUB" \
  CLAUDE_YOLO_TEST_OUT="$OUT" \
  "$YOLO" --name project-start
)

grep -Fxq "PWD=$PROJECT" "$OUT" || fail "registered project was not selected"
grep -Fq 'sample' "$OUT" || fail "project cold start was not loaded"

HOME="$HOME_DIR" \
PATH="$BIN:$PATH" \
PM_HUB_HOME="$HUB" \
CLAUDE_YOLO_TEST_OUT="$OUT" \
"$YOLO" hub --name hub-start
grep -Fxq "PWD=$HUB" "$OUT" || fail "explicit hub target failed"

HOME="$HOME_DIR" \
PATH="$BIN:$PATH" \
PM_HUB_HOME="$HUB" \
CLAUDE_YOLO_TEST_OUT="$OUT" \
"$YOLO" board
grep -Fxq "PWD=$PWD" "$OUT" || fail "Agent View changed directory unexpectedly"
grep -Fq 'ARGS=<agents><--permission-mode><bypassPermissions>' "$OUT" || fail "Agent View arguments are incorrect"

HOME="$HOME_DIR" \
PATH="$BIN:$PATH" \
PM_HUB_HOME="$HUB" \
CLAUDE_YOLO_TEST_OUT="$OUT" \
"$YOLO" respawn
grep -Fq 'ARGS=<respawn><--all>' "$OUT" || fail "respawn arguments are incorrect"

HOME="$HOME_DIR" \
PATH="$BIN:$PATH" \
PM_HUB_HOME="$HUB" \
PM_BOSS_ROOT="$SANDBOX" \
CLAUDE_YOLO_TEST_OUT="$OUT" \
"$YOLO" boss --name boss-start
grep -Fxq "PWD=$SANDBOX" "$OUT" || fail "boss mode did not use the configured disk root"
grep -Fxq 'PM_FEISHU_BOSS=1' "$OUT" || fail "boss mode did not mark the Feishu-facing session"
grep -Eq '^PM_FEISHU_BOSS_LAUNCH_TOKEN=[0-9a-f-]{36}$' "$OUT" ||
  fail "boss mode did not create a unique launch token"
grep -Fq '<--name><boss-start>' "$OUT" || fail "boss mode lost Claude arguments"

HOME="$HOME_DIR" \
PATH="$BIN:$PATH" \
PM_HUB_HOME="$HUB" \
CLAUDE_YOLO_TEST_OUT="$OUT" \
"$YOLO" capabilities install
grep -Fxq '<install>' "$CAPABILITIES_OUT" ||
  fail "capabilities install was not routed to the capability tool"

HOME="$HOME_DIR" \
PATH="$BIN:$PATH" \
PM_HUB_HOME="$HUB" \
CLAUDE_YOLO_TEST_OUT="$OUT" \
"$YOLO" provider status
grep -Fxq '<status>' "$PROVIDER_OUT" ||
  fail "provider status was not routed to pm-provider"

echo "PASS: Claude YOLO entrypoint"
