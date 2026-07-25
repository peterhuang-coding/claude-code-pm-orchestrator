#!/usr/bin/env python3
"""Record bounded Agent Team lifecycle metadata in the PM Hub."""

from __future__ import annotations

import fcntl
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


ALLOWED_FIELDS = (
    "session_id",
    "team_name",
    "teammate_name",
    "task_id",
    "task_subject",
)
MAX_FIELD_CHARS = 240


def bounded(value: object) -> str:
    return str(value)[:MAX_FIELD_CHARS]


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, OSError):
        return 0

    cwd = str(payload.get("cwd") or os.getcwd())
    tool = os.environ.get(
        "PM_HUB_TOOL",
        str(Path(__file__).resolve().with_name("pm-hub.sh")),
    )
    try:
        result = subprocess.run(
            [tool, "classify", cwd],
            check=False,
            capture_output=True,
            text=True,
            env=os.environ.copy(),
            timeout=5,
        )
    except (subprocess.TimeoutExpired, OSError):
        return 0
    fields = result.stdout.rstrip("\n").split("\t")
    if result.returncode != 0 or not fields or fields[0] != "project":
        return 0

    event = bounded(payload.get("hook_event_name", ""))
    if event not in {"TeammateIdle", "TaskCompleted"}:
        return 0

    record = {
        "event": event,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }
    for key in ALLOWED_FIELDS:
        if key in payload:
            record[key] = bounded(payload[key])

    hub = Path(os.environ.get("PM_HUB_HOME", "/Volumes/SanDisk2TB/claude-pm-hub"))
    log_dir = hub / "projects" / fields[1] / "team-events"
    log_dir.mkdir(parents=True, exist_ok=True)
    log_path = log_dir / f"{datetime.now(timezone.utc):%Y-%m-%d}.jsonl"
    line = json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n"
    with log_path.open("a", encoding="utf-8") as stream:
        fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
        stream.write(line)
        stream.flush()
        fcntl.flock(stream.fileno(), fcntl.LOCK_UN)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
