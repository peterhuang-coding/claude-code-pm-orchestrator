#!/usr/bin/env python3
"""Durable Feishu-to-Claude command intake."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import threading
import uuid
from pathlib import Path
from typing import Any, Callable

from pm_feishu import (
    _atomic_json,
    _read_json,
    append_log,
    load_state,
    reply_text,
    runtime_dir,
    utc_now,
)


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


def handle_event_line(line: str) -> bool:
    if not bool(load_state().get("enabled")):
        return False
    try:
        event = json.loads(line)
    except (TypeError, json.JSONDecodeError):
        return False
    return isinstance(event, dict) and enqueue_inbound_event(event)


def process_pending_once(
    *,
    executor: Callable[[str], str] = execute_remote_command,
    replier: Callable[[str, str], dict[str, Any]] = reply_text,
) -> tuple[int, int]:
    if not bool(load_state().get("enabled")):
        return 0, 0
    paths = pending_commands()
    if not paths:
        return 0, 0
    path = paths[0]
    record = _read_json(path, {})
    message_id = str(record.get("message_id", ""))
    content = str(record.get("content", ""))
    try:
        acknowledgement = replier(message_id, "已收到，开始处理。")
        result = executor(content)
        final_reply = replier(message_id, result)
        mark_processed(
            path,
            {
                "result": result,
                "acknowledgement": acknowledgement,
                "reply": final_reply,
            },
        )
        return 1, 0
    except (OSError, RuntimeError, ValueError) as error:
        details = str(error)[:1_500] or type(error).__name__
        try:
            replier(message_id, f"Claude 远程任务失败：{details}")
        except (OSError, RuntimeError, ValueError):
            pass
        mark_failed(path, details)
        return 0, 1


def inbound_configured() -> bool:
    policy = channel_policy()
    return bool(
        str(policy.get("chat_id", "")).startswith("oc_")
        and str(policy.get("owner_open_id", "")).startswith("ou_")
        and shutil.which("lark-cli")
    )


def run_lark_listener(
    stop_event: threading.Event,
    *,
    popen: Callable[..., Any] = subprocess.Popen,
    executable: str = "",
) -> int:
    lark = executable or shutil.which("lark-cli") or "lark-cli"
    environment = os.environ.copy()
    environment["LARK_CLI_NO_PROXY_WARN"] = "1"
    process = popen(
        [
            lark,
            "event",
            "consume",
            "im.message.receive_v1",
            "--as",
            "bot",
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        env=environment,
    )
    if process.stdin is None or process.stdout is None or process.stderr is None:
        raise RuntimeError("Lark event consumer pipes are unavailable")

    ready = False
    while not stop_event.is_set():
        line = process.stderr.readline()
        if not line:
            break
        if "[event] ready event_key=im.message.receive_v1" in line:
            ready = True
            break
    if not ready:
        try:
            process.stdin.close()
        except OSError:
            pass
        if process.poll() is None:
            process.terminate()
        process.wait(timeout=5)
        raise RuntimeError("Lark event consumer did not emit its ready marker")

    def stop_watcher() -> None:
        stop_event.wait()
        try:
            if not process.stdin.closed:
                process.stdin.close()
        except OSError:
            pass

    watcher = threading.Thread(
        target=stop_watcher,
        name="claude-feishu-listener-stop",
        daemon=True,
    )
    watcher.start()

    received = 0
    try:
        for line in process.stdout:
            if stop_event.is_set():
                break
            if handle_event_line(line):
                received += 1
    finally:
        try:
            if not process.stdin.closed:
                process.stdin.close()
        except OSError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=5)
    return received


def listen_forever(stop_event: threading.Event) -> None:
    while not stop_event.is_set():
        try:
            run_lark_listener(stop_event)
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            try:
                append_log("inbound-listener-error", str(error))
            except OSError:
                pass
        if not stop_event.is_set():
            stop_event.wait(2)
