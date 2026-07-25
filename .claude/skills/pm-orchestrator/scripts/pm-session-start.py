#!/usr/bin/env python3
"""Inject bounded PM Hub context into registered Claude Code sessions."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path


MAX_CONTEXT_CHARS = 9_000
COMMAND_TIMEOUT_SECONDS = 5


def run_hub(tool: str, *args: str) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    try:
        return subprocess.run(
            [tool, *args],
            check=False,
            capture_output=True,
            text=True,
            env=env,
            timeout=COMMAND_TIMEOUT_SECONDS,
        )
    except (subprocess.TimeoutExpired, OSError):
        return subprocess.CompletedProcess([tool, *args], 124, "", "command failed")


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, OSError):
        print("{}")
        return 0

    cwd = str(payload.get("cwd") or os.getcwd())
    if any(payload.get(key) for key in ("agent_type", "agent_id", "teammate_name")):
        print("{}")
        return 0
    tool = os.environ.get(
        "PM_HUB_TOOL",
        str(Path(__file__).resolve().with_name("pm-hub.sh")),
    )
    classification = run_hub(tool, "classify", cwd)
    if classification.returncode != 0:
        print("{}")
        return 0

    fields = classification.stdout.rstrip("\n").split("\t")
    kind = fields[0] if fields else "unknown"
    if kind not in {"project", "hub"}:
        print("{}")
        return 0

    context_result = run_hub(tool, "cold-start", cwd)
    if context_result.returncode != 0:
        print("{}")
        return 0

    title = "PM: Portfolio" if kind == "hub" else f"PM: {fields[1]}"
    context = context_result.stdout
    feature_tool = str(Path(__file__).resolve().with_name("pm-feature.sh"))
    feature_args = ["dashboard", "--all" if kind == "hub" else cwd]
    try:
        features = subprocess.run(
            [feature_tool, *feature_args],
            check=False,
            capture_output=True,
            text=True,
            env=os.environ.copy(),
            timeout=COMMAND_TIMEOUT_SECONDS,
        )
    except (subprocess.TimeoutExpired, OSError):
        features = subprocess.CompletedProcess(feature_args, 124, "", "command failed")
    if features.returncode == 0:
        context += "\n\n## Feature Dashboard\n" + features.stdout
    output = {
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": context[:MAX_CONTEXT_CHARS],
            "sessionTitle": title[:120],
            "reloadSkills": True,
        },
        "suppressOutput": True,
    }
    print(json.dumps(output, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
