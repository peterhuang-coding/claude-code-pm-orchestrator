#!/usr/bin/env python3
"""Non-blocking Claude Code hook adapter for the Feishu gateway."""

from __future__ import annotations

import json
import os
import sys
from typing import Any

from pm_feishu import (
    apply_switch_phrase,
    bind_boss,
    enqueue_hook_event,
    is_active_boss,
)


def process(event: dict[str, Any]) -> None:
    event_name = str(event.get("hook_event_name", ""))
    if event_name == "SessionStart":
        if os.environ.get("PM_FEISHU_BOSS") == "1":
            bind_boss(
                str(event.get("session_id", "")),
                str(event.get("cwd", "")),
            )
        return
    if event_name == "UserPromptSubmit":
        prompt = event.get("prompt", "")
        if isinstance(prompt, str) and is_active_boss(
            str(event.get("session_id", ""))
        ):
            apply_switch_phrase(prompt)
        return
    if event_name in {"Stop", "StopFailure", "Notification"}:
        enqueue_hook_event(event)


def main() -> int:
    try:
        payload = json.load(sys.stdin)
        if isinstance(payload, dict):
            process(payload)
    except Exception:
        # A notification bridge must never interfere with a Claude turn.
        pass
    print("{}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
