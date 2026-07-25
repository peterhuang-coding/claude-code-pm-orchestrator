#!/bin/sh
set -eu

MODE=${1:-ensure}
CLAUDE_HOME=${PM_CLAUDE_HOME:-"$HOME/.claude"}
AGENT_SKILLS_HOME=${PM_AGENT_SKILLS_HOME:-"$HOME/.agents/skills"}
MMX_SKILL_SOURCE="$AGENT_SKILLS_HOME/mmx-cli"
MMX_SKILL_TARGET="$CLAUDE_HOME/skills/mmx-cli"
SECURITY_BIN=${PM_SECURITY_BIN:-/usr/bin/security}
KEYCHAIN_SERVICE=${PM_PROVIDER_KEYCHAIN_SERVICE:-claude-pm-provider-router}
KEYCHAIN_ACCOUNT=${PM_PROVIDER_KEYCHAIN_ACCOUNT:-minimax}

has_mmx() {
  command -v mmx >/dev/null 2>&1
}

has_cli_skill() {
  [ -f "$MMX_SKILL_SOURCE/SKILL.md" ]
}

has_marketplace() {
  claude plugin marketplace list 2>/dev/null | grep -Fq 'minimax-skills'
}

has_plugin() {
  claude plugin list 2>/dev/null | grep -Fq 'minimax-skills@minimax-skills'
}

has_auth() {
  has_mmx && mmx auth status --output json --quiet --non-interactive >/dev/null 2>&1
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

  printf 'MiniMax capabilities\n'
  printf '  model: MiniMax-M3\n'
  printf '  region: cn\n'
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
  has_auth && return
  [ -x "$SECURITY_BIN" ] || {
    echo "macOS Keychain command is unavailable: $SECURITY_BIN" >&2
    exit 1
  }
  if ! KEY=$(
    "$SECURITY_BIN" find-generic-password \
      -w -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" 2>/dev/null
  ); then
    echo "MiniMax key is not configured in macOS Keychain." >&2
    echo "Run: claude-yolo provider set minimax" >&2
    exit 1
  fi
  mmx auth login --api-key "$KEY" >/dev/null
  unset KEY
  mmx config set --key region --value cn >/dev/null
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

  has_mmx || npm install -g mmx-cli
  has_cli_skill || npx skills add MiniMax-AI/cli -y -g
  has_cli_skill || {
    echo "MiniMax CLI Skill was not installed into $MMX_SKILL_SOURCE" >&2
    exit 1
  }
  ensure_skill_link

  has_marketplace ||
    claude plugin marketplace add https://github.com/MiniMax-AI/skills
  has_plugin || claude plugin install minimax-skills
  ensure_auth
}

case "$MODE" in
  ensure|install)
    ensure_all
    ;;
  status)
    print_status
    ;;
  *)
    echo "Usage: $(basename "$0") [ensure|install|status]" >&2
    exit 2
    ;;
esac
