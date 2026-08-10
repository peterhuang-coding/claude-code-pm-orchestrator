#!/bin/sh
set -eu

MODE=${1:-status}
CLAUDE_HOME=${PM_CLAUDE_HOME:-"$HOME/.claude"}
AGENT_SKILLS_HOME="$HOME/.agents/skills"
MMX_SKILL_SOURCE="$AGENT_SKILLS_HOME/mmx-cli"
MMX_SKILL_TARGET="$CLAUDE_HOME/skills/mmx-cli"
MMX_CONFIG_DIR=${MMX_CONFIG_DIR:-"$HOME/.mmx"}
MMX_CONFIG="$MMX_CONFIG_DIR/config.json"
SECURITY_BIN=${PM_SECURITY_BIN:-/usr/bin/security}
KEYCHAIN_SERVICE=${PM_PROVIDER_KEYCHAIN_SERVICE:-claude-pm-provider-router}
KEYCHAIN_ACCOUNT=${PM_PROVIDER_KEYCHAIN_ACCOUNT:-minimax}
MMX_CLI_VERSION=1.0.18
SKILLS_CLI_VERSION=1.5.20

has_mmx() {
  command -v mmx >/dev/null 2>&1
}

has_cli_skill() {
  [ -f "$MMX_SKILL_SOURCE/SKILL.md" ]
}

has_marketplace() {
  claude plugin marketplace list --json 2>/dev/null |
    python3 -c 'import json,sys; raise SystemExit(0 if any(x.get("name") == "minimax-skills" for x in json.load(sys.stdin)) else 1)'
}

plugin_matches() {
  EXPECT_ENABLED=$1
  claude plugin list --json 2>/dev/null |
    python3 -c 'import json,sys; expected=sys.argv[1]=="true"; raise SystemExit(0 if any(x.get("id") == "minimax-skills@minimax-skills" and (not expected or x.get("enabled") is True) for x in json.load(sys.stdin)) else 1)' "$EXPECT_ENABLED"
}

plugin_is_installed() {
  plugin_matches false
}

has_plugin() {
  plugin_matches true
}

read_mmx_field() {
  FIELD=$1
  [ -f "$MMX_CONFIG" ] || return 1
  python3 -c 'import json,sys; value=json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2]); print(value if isinstance(value, str) else "")' "$MMX_CONFIG" "$FIELD"
}

has_auth() {
  [ -f "$MMX_CONFIG" ] &&
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); raise SystemExit(0 if (isinstance(d.get("api_key"),str) and d["api_key"]) or isinstance(d.get("oauth"),dict) else 1)' "$MMX_CONFIG" 2>/dev/null
}

mmx_config_matches() {
  [ "$(read_mmx_field region 2>/dev/null || true)" = cn ] &&
    [ "$(read_mmx_field default_text_model 2>/dev/null || true)" = MiniMax-M3 ]
}

skill_is_linked() {
  [ -f "$MMX_SKILL_TARGET/SKILL.md" ]
}

print_status() {
  READY=yes
  has_mmx || READY=no
  has_cli_skill || READY=no
  skill_is_linked || READY=no
  has_marketplace || READY=no
  has_plugin || READY=no
  has_auth || READY=no
  mmx_config_matches || READY=no

  printf 'MiniMax capabilities\n'
  printf '  model: %s\n' "$(read_mmx_field default_text_model 2>/dev/null || echo unconfigured)"
  printf '  region: %s\n' "$(read_mmx_field region 2>/dev/null || echo unconfigured)"
  printf '  mmx-cli: %s\n' "$(has_mmx && echo yes || echo no)"
  printf '  mmx-cli skill: %s\n' "$(skill_is_linked && echo yes || echo no)"
  printf '  minimax-skills plugin: %s\n' "$(has_plugin && echo yes || echo no)"
  printf '  authenticated: %s\n' "$(has_auth && echo yes || echo no)"
  printf '  ready: %s\n' "$READY"
  [ "$READY" = yes ]
}

ensure_node() {
  command -v node >/dev/null 2>&1 || {
    echo "MiniMax capabilities require Node.js 18 or newer." >&2
    exit 1
  }
  MAJOR=$(node --version | sed 's/^v//' | cut -d. -f1)
  case "$MAJOR" in
    ''|*[!0-9]*)
      echo "Could not determine the installed Node.js version." >&2
      exit 1
      ;;
  esac
  [ "$MAJOR" -ge 18 ] || {
    echo "MiniMax capabilities require Node.js 18 or newer." >&2
    exit 1
  }
}

ensure_skill_link() {
  mkdir -p "$CLAUDE_HOME/skills"
  if skill_is_linked; then
    return
  fi
  if [ -e "$MMX_SKILL_TARGET" ] || [ -L "$MMX_SKILL_TARGET" ]; then
    echo "Refusing to replace existing path: $MMX_SKILL_TARGET" >&2
    exit 1
  fi
  ln -s "$MMX_SKILL_SOURCE" "$MMX_SKILL_TARGET"
}

ensure_auth() {
  if ! has_auth; then
    [ -x "$SECURITY_BIN" ] || {
      echo "macOS Keychain command is unavailable: $SECURITY_BIN" >&2
      exit 1
    }
    if ! KEY=$(
      "$SECURITY_BIN" find-generic-password \
        -w -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" 2>/dev/null
    ); then
      echo "MiniMax key is not configured in macOS Keychain." >&2
      echo "Run: security add-generic-password -U -s $KEYCHAIN_SERVICE -a $KEYCHAIN_ACCOUNT -w" >&2
      exit 1
    fi
    mmx auth login --api-key "$KEY" >/dev/null
    unset KEY
  fi
  [ "$(read_mmx_field region 2>/dev/null || true)" = cn ] ||
    mmx config set --key region --value cn >/dev/null
  [ "$(read_mmx_field default_text_model 2>/dev/null || true)" = MiniMax-M3 ] ||
    mmx config set --key default-text-model --value MiniMax-M3 >/dev/null
}

ensure_all() {
  ensure_node
  command -v npm >/dev/null 2>&1 || {
    echo "npm is required to install mmx-cli." >&2
    exit 1
  }
  command -v npx >/dev/null 2>&1 || {
    echo "npx is required to install the MiniMax Skill." >&2
    exit 1
  }
  command -v claude >/dev/null 2>&1 || {
    echo "Claude Code is required to install MiniMax Skills." >&2
    exit 1
  }

  has_mmx || npm install -g "mmx-cli@$MMX_CLI_VERSION"
  has_cli_skill ||
    npx --yes "skills@$SKILLS_CLI_VERSION" add MiniMax-AI/cli -y -g
  has_cli_skill || {
    echo "MiniMax CLI Skill was not installed into $MMX_SKILL_SOURCE" >&2
    exit 1
  }
  ensure_skill_link

  has_marketplace ||
    claude plugin marketplace add https://github.com/MiniMax-AI/skills
  if ! plugin_is_installed; then
    claude plugin install minimax-skills
  elif ! has_plugin; then
    claude plugin enable minimax-skills@minimax-skills
  fi
  ensure_auth
}

case "$MODE" in
  install)
    ensure_all
    ;;
  status)
    print_status
    ;;
  *)
    echo "Usage: $(basename "$0") [install|status]" >&2
    exit 2
    ;;
esac
