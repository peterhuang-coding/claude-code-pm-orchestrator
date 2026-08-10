#!/usr/bin/env python3
"""Apply model-neutral Claude Code defaults required by PM Orchestrator."""

from __future__ import annotations

import json
import os
import shlex
import fcntl
import tempfile
import copy
from pathlib import Path
from typing import Any, Optional


def command_hook(
    script: Path,
    *,
    async_hook: bool = False,
    timeout: Optional[int] = None,
    fail_open: bool = False,
) -> dict[str, Any]:
    command = f"python3 {shlex.quote(str(script.resolve()))}"
    if fail_open:
        command += " || true"
    hook: dict[str, Any] = {"type": "command", "command": command}
    if async_hook:
        hook["async"] = True
    if timeout is not None:
        hook["timeout"] = timeout
    return {"hooks": [hook]}


def replace_managed_hook(
    hooks: dict[str, Any],
    event: str,
    script_name: str,
    script: Path,
    *,
    async_hook: bool = False,
    timeout: Optional[int] = None,
    fail_open: bool = False,
) -> None:
    groups = hooks.get(event, [])
    retained = []
    for group in groups if isinstance(groups, list) else []:
        nested = group.get("hooks", []) if isinstance(group, dict) else []
        if any(
            script_name in str(item.get("command", ""))
            for item in nested
            if isinstance(item, dict)
        ):
            continue
        retained.append(group)
    retained.append(
        command_hook(
            script,
            async_hook=async_hook,
            timeout=timeout,
            fail_open=fail_open,
        )
    )
    hooks[event] = retained


def managed_scripts_dir(settings_path: Path) -> Path:
    installed = settings_path.parent / "skills" / "pm-orchestrator" / "scripts"
    required = (
        "pm-session-start.py",
        "pm-feishu-hook.py",
        "pm-team-event.py",
    )
    if all((installed / name).is_file() for name in required):
        return installed
    return Path(__file__).resolve().parent


def main() -> int:
    settings_path = Path(
        os.environ.get("PM_CLAUDE_SETTINGS", "~/.claude/settings.json")
    ).expanduser()
    settings_path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = settings_path.with_suffix(settings_path.suffix + ".pm-orchestrator.lock")
    with lock_path.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        if settings_path.exists():
            settings = json.loads(settings_path.read_text(encoding="utf-8"))
        else:
            settings = {}
        original_settings = copy.deepcopy(settings)

        env = settings.setdefault("env", {})
        env["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] = "1"
        env.setdefault("CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY", "12")
        env.pop("CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS", None)

        permissions = settings.setdefault("permissions", {})
        permissions["defaultMode"] = "bypassPermissions"
        settings["teammateMode"] = "in-process"
        settings["skipDangerousModePermissionPrompt"] = True

        scripts = managed_scripts_dir(settings_path)
        hooks = settings.setdefault("hooks", {})
        replace_managed_hook(
            hooks, "SessionStart", "pm-session-start.py", scripts / "pm-session-start.py"
        )
        for event in (
            "SessionStart",
            "UserPromptSubmit",
            "Stop",
            "StopFailure",
            "Notification",
        ):
            replace_managed_hook(
                hooks,
                event,
                "pm-feishu-hook.py",
                scripts / "pm-feishu-hook.py",
                async_hook=event not in ("SessionStart", "UserPromptSubmit"),
                timeout=2 if event in ("SessionStart", "UserPromptSubmit") else 5,
                fail_open=True,
            )
        for event in ("TeammateIdle", "TaskCompleted"):
            replace_managed_hook(
                hooks, event, "pm-team-event.py", scripts / "pm-team-event.py"
            )

        if settings == original_settings:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
            return 0

        serialized = (
            json.dumps(settings, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        )
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            dir=settings_path.parent,
            prefix=f".{settings_path.name}.",
            delete=False,
        ) as temporary:
            temporary.write(serialized)
            temporary.flush()
            os.fsync(temporary.fileno())
            temporary_path = Path(temporary.name)
        temporary_path.chmod(0o600)
        os.replace(temporary_path, settings_path)
        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
