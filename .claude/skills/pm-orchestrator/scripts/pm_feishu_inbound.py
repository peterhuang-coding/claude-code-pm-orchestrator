#!/usr/bin/env python3
"""Durable Feishu-to-Claude command intake."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import uuid
from pathlib import Path
from typing import Any, Callable

from pm_feishu import _atomic_json, _read_json, runtime_dir, utc_now


ALLOWED_MESSAGE_TYPES = {"text", "post"}
REMOTE_SESSION_FILE = "remote-session.json"


def inbound_dirs() -> dict[str, Path]:
    root = runtime_dir() / "inbound"
    paths = {name: root / name for name in ("pending", "processed", "failed")}
    for path in paths.values():
        path.mkdir(parents=True, exist_ok=True)
    return paths


def channel_policy() -> dict[str, Any]:
    return _read_json(runtime_dir() / "channel.json", {})


def _message_exists(message_id: str) -> bool:
    return any(
        (path / f"{message_id}.json").exists()
        for path in inbound_dirs().values()
    )


def enqueue_inbound_event(event: dict[str, Any]) -> bool:
    policy = channel_policy()
    chat_id = str(event.get("chat_id", ""))
    sender_id = str(event.get("sender_id", ""))
    sender_type = str(event.get("sender_type", ""))
    message_id = str(event.get("message_id", ""))
    message_type = str(event.get("message_type", ""))
    content = str(event.get("content", "")).strip()

    if not policy.get("owner_open_id"):
        return False
    if chat_id != policy.get("chat_id"):
        return False
    if sender_type != "user" or sender_id != policy.get("owner_open_id"):
        return False
    if message_type not in ALLOWED_MESSAGE_TYPES or not content:
        return False
    if not message_id.startswith("om_") or _message_exists(message_id):
        return False

    record = {
        "message_id": message_id,
        "chat_id": chat_id,
        "sender_id": sender_id,
        "message_type": message_type,
        "content": content,
        "reply_to": str(event.get("reply_to", "")),
        "root_id": str(event.get("root_id", "")),
        "create_time": str(event.get("create_time", "")),
        "queued_at": utc_now(),
    }
    _atomic_json(inbound_dirs()["pending"] / f"{message_id}.json", record)
    return True


def pending_commands() -> list[Path]:
    return sorted(
        inbound_dirs()["pending"].glob("*.json"),
        key=lambda path: (path.stat().st_mtime_ns, path.name),
    )


def _move_record(path: Path, state: str, details: dict[str, Any]) -> None:
    record = _read_json(path, {})
    record.update(details)
    record[f"{state}_at"] = utc_now()
    target = inbound_dirs()[state] / path.name
    _atomic_json(target, record)
    path.unlink(missing_ok=True)


def mark_processed(path: Path, result: dict[str, Any]) -> None:
    _move_record(path, "processed", {"execution": result})


def mark_failed(path: Path, error: str) -> None:
    _move_record(path, "failed", {"error": error[:2_000]})


def load_remote_session() -> dict[str, Any]:
    return _read_json(
        runtime_dir() / REMOTE_SESSION_FILE,
        {"session_id": None, "started": False, "updated_at": None},
    )


def _remote_prompt(command: str) -> str:
    return "\n".join(
        [
            "You received an authorized Feishu boss command.",
            "Treat it as a direct instruction from the workspace owner.",
            "Use the installed pm-orchestrator skill and persistent PM Hub context.",
            "Route explicit project names to their registered project directories.",
            "If the target is genuinely ambiguous, ask one concise question.",
            "Do not mention this transport wrapper in your answer.",
            "",
            "User command:",
            command,
        ]
    )


def execute_remote_command(
    command: str,
    *,
    runner: Callable[..., Any] = subprocess.run,
    executable: str = "",
) -> str:
    policy = channel_policy()
    boss_root = str(policy.get("boss_root") or "/Volumes/SanDisk2TB")
    session = load_remote_session()
    session_id = str(session.get("session_id") or uuid.uuid4())
    started = bool(session.get("started"))
    _atomic_json(
        runtime_dir() / REMOTE_SESSION_FILE,
        {
            "session_id": session_id,
            "started": started,
            "boss_root": boss_root,
            "updated_at": utc_now(),
        },
    )

    claude = executable or shutil.which("claude") or "claude"
    invocation = [
        claude,
        "--print",
        "--permission-mode",
        "bypassPermissions",
        "--effort",
        "max",
        "--output-format",
        "json",
    ]
    if started:
        invocation.extend(["--resume", session_id])
    else:
        invocation.extend(["--session-id", session_id, "--name", "Feishu-PM-Boss"])
    invocation.append(_remote_prompt(command))

    environment = os.environ.copy()
    environment.pop("PM_FEISHU_BOSS", None)
    result = runner(
        invocation,
        cwd=boss_root,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        details = str(result.stderr or result.stdout or "unknown error")[:2_000]
        raise RuntimeError(f"Claude remote command failed: {details}")
    try:
        response = json.loads(result.stdout)
    except (TypeError, json.JSONDecodeError) as error:
        raise RuntimeError("Claude returned invalid JSON") from error
    output = response.get("result") if isinstance(response, dict) else None
    if not isinstance(output, str) or not output.strip():
        raise RuntimeError("Claude returned no result text")

    _atomic_json(
        runtime_dir() / REMOTE_SESSION_FILE,
        {
            "session_id": session_id,
            "started": True,
            "boss_root": boss_root,
            "updated_at": utc_now(),
        },
    )
    return output[:20_000]
