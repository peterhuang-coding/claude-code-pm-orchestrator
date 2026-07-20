#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
IMAGE_TOOL="$SCRIPT_DIR/../.claude/skills/pm-orchestrator/scripts/pm-imageinput.py"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -f "$IMAGE_TOOL" ] || fail "image helper is missing"
PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/pm-imageinput-pycache.$$" \
  python3 -m py_compile "$IMAGE_TOOL" || fail "image helper does not compile"
python3 "$IMAGE_TOOL" --help | grep -Fq 'Analyze a local image' || fail "help output is missing"

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/pm-imageinput-test.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
printf 'not-a-real-image' > "$SANDBOX/page.png"

! python3 "$IMAGE_TOOL" run "$SANDBOX/page.png" 'analyze page' >/dev/null 2>&1 || fail "missing API key was accepted"
PM_IMAGEINPUT_DRY_RUN=1 OPENROUTER_API_KEY=test-key \
  python3 "$IMAGE_TOOL" run "$SANDBOX/page.png" 'analyze page' | grep -Fq '[dry-run]' || fail "dry-run did not return"

echo "PASS: PM image input helper"
