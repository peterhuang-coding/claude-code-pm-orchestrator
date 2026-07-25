#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
INSTALLER="$ROOT/.claude/skills/pm-orchestrator/scripts/install-minimax-capabilities.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -x "$INSTALLER" ] || fail "MiniMax capabilities installer is missing"

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/minimax-capabilities-test.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
export HOME="$SANDBOX/home"
export PM_TEST_BIN="$SANDBOX/bin"
export PM_TEST_LOG="$SANDBOX/commands.log"
export PM_SECURITY_BIN="$PM_TEST_BIN/security"
mkdir -p "$HOME" "$PM_TEST_BIN"
: >"$PM_TEST_LOG"

cat >"$PM_TEST_BIN/node" <<'EOF'
#!/bin/sh
echo v22.0.0
EOF

cat >"$PM_TEST_BIN/npm" <<'EOF'
#!/bin/sh
printf 'npm <%s>\n' "$*" >>"$PM_TEST_LOG"
cat >"$PM_TEST_BIN/mmx" <<'MMX'
#!/bin/sh
case "$1 ${2:-}" in
  "--version ") echo "mmx 1.0.18" ;;
  "auth status")
    [ -f "$HOME/.mmx-authenticated" ] || exit 1
    echo '{"method":"api-key"}'
    ;;
  "auth login")
    touch "$HOME/.mmx-authenticated"
    printf 'mmx-login\n' >>"$PM_TEST_LOG"
    ;;
  "config set")
    printf 'mmx-config <%s>\n' "$*" >>"$PM_TEST_LOG"
    ;;
  *) exit 2 ;;
esac
MMX
chmod +x "$PM_TEST_BIN/mmx"
EOF

cat >"$PM_TEST_BIN/npx" <<'EOF'
#!/bin/sh
printf 'npx <%s>\n' "$*" >>"$PM_TEST_LOG"
mkdir -p "$HOME/.agents/skills/mmx-cli"
printf '%s\n' '---' 'name: mmx-cli' '---' >"$HOME/.agents/skills/mmx-cli/SKILL.md"
EOF

cat >"$PM_TEST_BIN/security" <<'EOF'
#!/bin/sh
printf '%s\n' 'test-minimax-secret'
EOF

cat >"$PM_TEST_BIN/claude" <<'EOF'
#!/bin/sh
case "$1 ${2:-} ${3:-}" in
  "plugin marketplace list")
    [ ! -f "$HOME/.minimax-marketplace" ] || echo "minimax-skills"
    ;;
  "plugin list ")
    [ ! -f "$HOME/.minimax-plugin" ] || echo "minimax-skills@minimax-skills"
    ;;
  "plugin marketplace add")
    touch "$HOME/.minimax-marketplace"
    printf 'claude-marketplace <%s>\n' "$*" >>"$PM_TEST_LOG"
    ;;
  "plugin install minimax-skills")
    touch "$HOME/.minimax-plugin"
    printf 'claude-plugin <%s>\n' "$*" >>"$PM_TEST_LOG"
    ;;
  *) exit 2 ;;
esac
EOF

chmod +x "$PM_TEST_BIN/"*

OUT="$SANDBOX/ensure.out"
PATH="$PM_TEST_BIN:/usr/bin:/bin" "$INSTALLER" ensure >"$OUT" 2>&1

grep -Fq 'npm <install -g mmx-cli>' "$PM_TEST_LOG" ||
  fail "mmx-cli was not installed"
grep -Fq 'npx <skills add MiniMax-AI/cli -y -g>' "$PM_TEST_LOG" ||
  fail "official mmx-cli Skill was not installed"
grep -Fq 'claude-marketplace <plugin marketplace add https://github.com/MiniMax-AI/skills>' "$PM_TEST_LOG" ||
  fail "MiniMax Skill marketplace was not added"
grep -Fq 'claude-plugin <plugin install minimax-skills>' "$PM_TEST_LOG" ||
  fail "MiniMax Skills plugin was not installed"
grep -Fq 'mmx-login' "$PM_TEST_LOG" || fail "mmx-cli was not authenticated"
grep -Fq 'default-text-model --value MiniMax-M3' "$PM_TEST_LOG" ||
  fail "MiniMax-M3 was not selected as the default text model"
[ -L "$HOME/.claude/skills/mmx-cli" ] ||
  fail "Claude Code mmx-cli Skill link was not created"
[ "$(readlink "$HOME/.claude/skills/mmx-cli")" = "$HOME/.agents/skills/mmx-cli" ] ||
  fail "Claude Code mmx-cli Skill link has the wrong target"
! grep -Fq 'test-minimax-secret' "$OUT" ||
  fail "MiniMax credential leaked to installer output"

cp "$PM_TEST_LOG" "$SANDBOX/commands.before"
PATH="$PM_TEST_BIN:/usr/bin:/bin" "$INSTALLER" ensure >"$OUT" 2>&1
cmp -s "$SANDBOX/commands.before" "$PM_TEST_LOG" ||
  fail "second ensure was not idempotent"

PATH="$PM_TEST_BIN:/usr/bin:/bin" "$INSTALLER" status >"$OUT"
grep -Fq 'model: MiniMax-M3' "$OUT" || fail "status omitted MiniMax-M3"
grep -Fq 'ready: yes' "$OUT" || fail "status did not report ready"

echo "PASS: MiniMax multimodal capabilities installer"
