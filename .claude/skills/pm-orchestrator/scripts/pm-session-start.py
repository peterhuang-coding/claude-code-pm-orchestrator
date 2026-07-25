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
PROVIDER_TIMEOUT_SECONDS = 2


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


def provider_context() -> str:
    tool = os.environ.get(
        "PM_PROVIDER_TOOL",
        str(Path(__file__).resolve().with_name("pm-provider.py")),
    )
    try:
        result = subprocess.run(
            [tool, "status", "--json"],
            check=False,
            capture_output=True,
            text=True,
            env=os.environ.copy(),
            timeout=PROVIDER_TIMEOUT_SECONDS,
        )
        status = json.loads(result.stdout) if result.returncode == 0 else {}
    except (subprocess.TimeoutExpired, OSError, json.JSONDecodeError):
        return ""
    if not isinstance(status, dict) or not status.get("active"):
        return ""
    mode = status.get("mode") if isinstance(status.get("mode"), str) else "unknown"
    current = (
        status.get("current_provider")
        if isinstance(status.get("current_provider"), str)
        else "none"
    )
    cooldowns = status.get("cooldowns")
    cooldown_ids = (
        sorted(key for key in cooldowns if isinstance(key, str))
        if isinstance(cooldowns, dict)
        else []
    )
    cooldown_label = ",".join(cooldown_ids) if cooldown_ids else "none"
    return (
        f"Provider routing: mode={mode}; current={current}; "
        f"cooldowns={cooldown_label}"
    )


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
    provider = provider_context()
    if provider:
        context += "\n\n## Provider\n" + provider
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
