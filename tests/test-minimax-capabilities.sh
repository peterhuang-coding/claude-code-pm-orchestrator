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
  "auth login")
    mkdir -p "$HOME/.mmx"
    printf '%s\n' '{"api_key":"configured-key","region":"cn"}' >"$HOME/.mmx/config.json"
    chmod 600 "$HOME/.mmx/config.json"
    printf 'mmx-login\n' >>"$PM_TEST_LOG"
    ;;
  "config set")
    printf 'mmx-config <%s>\n' "$*" >>"$PM_TEST_LOG"
    python3 - "$HOME/.mmx/config.json" "$@" <<'PY'
import json
import sys

path = sys.argv[1]
args = sys.argv[2:]
key = args[args.index("--key") + 1].replace("-", "_")
value = args[args.index("--value") + 1]
with open(path, encoding="utf-8") as stream:
    config = json.load(stream)
config[key] = value
with open(path, "w", encoding="utf-8") as stream:
    json.dump(config, stream)
PY
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
    if [ -f "$HOME/.minimax-marketplace" ]; then
      echo '[{"name":"minimax-skills"}]'
    else
      echo '[]'
    fi
    ;;
  "plugin list --json")
    if [ -f "$HOME/.minimax-plugin" ]; then
      ENABLED=$(cat "$HOME/.minimax-plugin")
      printf '[{"id":"minimax-skills@minimax-skills","enabled":%s}]\n' "$ENABLED"
    else
      echo '[]'
    fi
    ;;
  "plugin marketplace add")
    touch "$HOME/.minimax-marketplace"
    printf 'claude-marketplace <%s>\n' "$*" >>"$PM_TEST_LOG"
    ;;
  "plugin install minimax-skills")
    printf '%s\n' true >"$HOME/.minimax-plugin"
    printf 'claude-plugin <%s>\n' "$*" >>"$PM_TEST_LOG"
    ;;
  "plugin enable minimax-skills@minimax-skills")
    printf '%s\n' true >"$HOME/.minimax-plugin"
    printf 'claude-enable <%s>\n' "$*" >>"$PM_TEST_LOG"
    ;;
  *) exit 2 ;;
esac
EOF

chmod +x "$PM_TEST_BIN/"*

OUT="$SANDBOX/ensure.out"
PATH="$PM_TEST_BIN:/usr/bin:/bin" "$INSTALLER" install >"$OUT" 2>&1

grep -Fq 'npm <install -g mmx-cli@1.0.18>' "$PM_TEST_LOG" ||
  fail "mmx-cli was not installed"
grep -Fq 'npx <--yes skills@1.5.20 add MiniMax-AI/cli -y -g>' "$PM_TEST_LOG" ||
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
PATH="$PM_TEST_BIN:/usr/bin:/bin" "$INSTALLER" install >"$OUT" 2>&1
cmp -s "$SANDBOX/commands.before" "$PM_TEST_LOG" ||
  fail "second install was not idempotent"

PATH="$PM_TEST_BIN:/usr/bin:/bin" "$INSTALLER" status >"$OUT"
grep -Fq 'model: MiniMax-M3' "$OUT" || fail "status omitted MiniMax-M3"
grep -Fq 'ready: yes' "$OUT" || fail "status did not report ready"

python3 - "$HOME/.mmx/config.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    config = json.load(stream)
config["region"] = "global"
config["default_text_model"] = "MiniMax-M2.7"
with open(path, "w", encoding="utf-8") as stream:
    json.dump(config, stream)
PY
: >"$PM_TEST_LOG"
PATH="$PM_TEST_BIN:/usr/bin:/bin" "$INSTALLER" install >"$OUT" 2>&1
grep -Fq 'region --value cn' "$PM_TEST_LOG" ||
  fail "existing global mmx config was not migrated to cn"
grep -Fq 'default-text-model --value MiniMax-M3' "$PM_TEST_LOG" ||
  fail "existing mmx model was not migrated to MiniMax-M3"
! grep -Fq 'npm <' "$PM_TEST_LOG" ||
  fail "config migration unnecessarily reinstalled mmx-cli"

printf '%s\n' false >"$HOME/.minimax-plugin"
if PATH="$PM_TEST_BIN:/usr/bin:/bin" "$INSTALLER" status >"$OUT" 2>&1; then
  fail "disabled MiniMax plugin was reported ready"
fi
grep -Fq 'minimax-skills plugin: no' "$OUT" ||
  fail "status did not report disabled MiniMax plugin"
PATH="$PM_TEST_BIN:/usr/bin:/bin" "$INSTALLER" install >"$OUT" 2>&1
grep -Fxq true "$HOME/.minimax-plugin" ||
  fail "disabled MiniMax plugin was not re-enabled"

echo "PASS: MiniMax multimodal capabilities installer"
