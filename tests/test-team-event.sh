#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
EVENT_TOOL="$ROOT/.claude/skills/pm-orchestrator/scripts/pm-team-event.py"
HUB_TOOL="$ROOT/.claude/skills/pm-orchestrator/scripts/pm-hub.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -f "$EVENT_TOOL" ] || fail "team event hook is missing"

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/pm-team-event-test.XXXXXX")
SANDBOX=$(CDPATH= cd -- "$SANDBOX" && pwd -P)
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
HUB="$SANDBOX/hub"
PROJECT="$SANDBOX/project"
mkdir -p "$PROJECT"
PM_HUB_HOME="$HUB" "$HUB_TOOL" init >/dev/null
PM_HUB_HOME="$HUB" "$HUB_TOOL" register "$PROJECT" sample >/dev/null

printf '{"hook_event_name":"TeammateIdle","cwd":"%s","session_id":"s1","team_name":"F-demo","teammate_name":"review","prompt":"must-not-log"}\n' "$PROJECT" |
  PM_HUB_HOME="$HUB" PM_HUB_TOOL="$HUB_TOOL" python3 "$EVENT_TOOL"
printf '{"hook_event_name":"TaskCompleted","cwd":"%s","session_id":"s1","team_name":"F-demo","task_id":"7","task_subject":"Run regression"}\n' "$PROJECT" |
  PM_HUB_HOME="$HUB" PM_HUB_TOOL="$HUB_TOOL" python3 "$EVENT_TOOL"

LOG=$(find "$HUB/projects/sample/team-events" -type f -name '*.jsonl' -print | sed -n '1p')
[ -f "$LOG" ] || fail "team event log missing"
grep -Fq '"event":"TeammateIdle"' "$LOG" || fail "idle event missing"
grep -Fq '"event":"TaskCompleted"' "$LOG" || fail "task event missing"
grep -Fq '"task_subject":"Run regression"' "$LOG" || fail "bounded task metadata missing"
if grep -Fq 'must-not-log' "$LOG"; then
  fail "unapproved event payload was logged"
fi
[ "$(wc -c < "$LOG" | tr -d ' ')" -le 4000 ] || fail "team event log is unexpectedly large"

echo "PASS: Agent Team event logging"
