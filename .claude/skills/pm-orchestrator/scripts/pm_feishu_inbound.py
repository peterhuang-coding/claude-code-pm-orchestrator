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
from typing import Any, Callable, Optional

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
LISTENER_STATE_FILE = "listener-state.json"


class RemoteCommandCancelled(RuntimeError):
    """Raised after a running Claude child has been stopped."""


def inbound_dirs() -> dict[str, Path]:
    root = runtime_dir() / "inbound"
    paths = {
        name: root / name
        for name in ("pending", "running", "processed", "failed")
    }
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


def running_commands() -> list[Path]:
    return sorted(
        inbound_dirs()["running"].glob("*.json"),
        key=lambda path: (path.stat().st_mtime_ns, path.name),
    )


def claim_pending(path: Path) -> Path:
    """Atomically claim a command before any privileged side effect."""
    target = inbound_dirs()["running"] / path.name
    os.replace(path, target)
    record = _read_json(target, {})
    record.update({"phase": "executing", "claimed_at": utc_now()})
    _atomic_json(target, record)
    return target


def _move_record(path: Path, state: str, details: dict[str, Any]) -> None:
    record = _read_json(path, {})
    record.update(details)
    record[f"{state}_at"] = utc_now()
    _atomic_json(path, record)
    target = inbound_dirs()[state] / path.name
    os.replace(path, target)


def mark_processed(path: Path, result: dict[str, Any]) -> None:
    _move_record(path, "processed", {"execution": result})


def mark_failed(path: Path, error: str) -> None:
    _move_record(path, "failed", {"error": error[:2_000]})


def load_remote_session() -> dict[str, Any]:
    return _read_json(
        runtime_dir() / REMOTE_SESSION_FILE,
        {"session_id": None, "phase": "new", "updated_at": None},
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
    stop_event: Optional[threading.Event] = None,
    runner: Callable[..., Any] = subprocess.Popen,
    executable: str = "",
) -> str:
    policy = channel_policy()
    boss_root = str(policy.get("boss_root") or "/Volumes/SanDisk2TB")
    session = load_remote_session()
    phase = str(session.get("phase") or ("ready" if session.get("started") else "new"))
    started = phase == "ready" and bool(session.get("session_id"))
    session_id = str(session.get("session_id") or uuid.uuid4())
    if phase == "creating":
        session_id = str(uuid.uuid4())
        started = False
    _atomic_json(
        runtime_dir() / REMOTE_SESSION_FILE,
        {
            "session_id": session_id,
            "phase": "ready" if started else "creating",
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
    process = runner(
        invocation,
        cwd=boss_root,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    stopper = stop_event or threading.Event()
    stdout = ""
    stderr = ""
    while True:
        if stopper.is_set():
            if process.returncode is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            raise RemoteCommandCancelled("Claude remote command was cancelled")
        try:
            stdout, stderr = process.communicate(timeout=0.25)
            break
        except subprocess.TimeoutExpired:
            continue
    if process.returncode != 0:
        details = str(stderr or stdout or "unknown error")[:2_000]
        raise RuntimeError(f"Claude remote command failed: {details}")
    try:
        response = json.loads(stdout)
    except (TypeError, json.JSONDecodeError) as error:
        raise RuntimeError("Claude returned invalid JSON") from error
    output = response.get("result") if isinstance(response, dict) else None
    if not isinstance(output, str) or not output.strip():
        raise RuntimeError("Claude returned no result text")

    _atomic_json(
        runtime_dir() / REMOTE_SESSION_FILE,
        {
            "session_id": session_id,
            "phase": "ready",
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
    executor: Callable[..., str] = execute_remote_command,
    replier: Callable[[str, str], dict[str, Any]] = reply_text,
    stop_event: Optional[threading.Event] = None,
) -> tuple[int, int]:
    if not bool(load_state().get("enabled")):
        return 0, 0
    running = running_commands()
    if running:
        path = running[0]
        record = _read_json(path, {})
        message_id = str(record.get("message_id", ""))
        if record.get("phase") == "reply_pending":
            try:
                final_reply = replier(message_id, str(record.get("result", "")))
            except (OSError, RuntimeError, ValueError):
                return 0, 1
            mark_processed(
                path,
                {
                    "result": str(record.get("result", "")),
                    "acknowledgement": record.get("acknowledgement"),
                    "reply": final_reply,
                },
            )
            return 1, 0

        details = "Gateway stopped during execution; command was not retried"
        try:
            replier(
                message_id,
                "上次执行被中断，结果无法确认。为避免重复执行高权限操作，系统不会自动重试。",
            )
        except (OSError, RuntimeError, ValueError):
            pass
        mark_failed(path, details)
        return 0, 1

    paths = pending_commands()
    if not paths:
        return 0, 0
    path = claim_pending(paths[0])
    record = _read_json(path, {})
    message_id = str(record.get("message_id", ""))
    content = str(record.get("content", ""))
    try:
        try:
            acknowledgement = replier(message_id, "已收到，开始处理。")
        except (OSError, RuntimeError, ValueError):
            acknowledgement = None
        if executor is execute_remote_command:
            result = executor(content, stop_event=stop_event)
        else:
            result = executor(content)
        record.update(
            {
                "phase": "reply_pending",
                "result": result,
                "acknowledgement": acknowledgement,
                "executed_at": utc_now(),
            }
        )
        _atomic_json(path, record)
        try:
            final_reply = replier(message_id, result)
        except (OSError, RuntimeError, ValueError):
            return 0, 1
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
    boss_root = Path(str(policy.get("boss_root", ""))).expanduser()
    return bool(
        str(policy.get("chat_id", "")).startswith("oc_")
        and str(policy.get("owner_open_id", "")).startswith("ou_")
        and shutil.which("lark-cli")
        and shutil.which("claude")
        and boss_root.is_dir()
    )


def _set_listener_runtime(status: str, message: str = "") -> None:
    _atomic_json(
        runtime_dir() / LISTENER_STATE_FILE,
        {
            "status": status,
            "pid": os.getpid(),
            "message": message[:500],
            "updated_at": utc_now(),
        },
    )


def listener_runtime_status() -> str:
    state = _read_json(runtime_dir() / LISTENER_STATE_FILE, {})
    status = str(state.get("status") or "offline")
    if status not in {"starting", "ready"}:
        return "offline"
    try:
        os.kill(int(state.get("pid", 0)), 0)
    except (OSError, TypeError, ValueError):
        return "offline"
    return status


def _stop_listener_process(process: Any) -> None:
    try:
        if process.stdin is not None and not process.stdin.closed:
            process.stdin.close()
    except OSError:
        pass
    if process.poll() is not None:
        return
    try:
        process.wait(timeout=2)
        return
    except subprocess.TimeoutExpired:
        process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def run_lark_listener(
    stop_event: threading.Event,
    *,
    popen: Callable[..., Any] = subprocess.Popen,
    executable: str = "",
) -> int:
    lark = executable or shutil.which("lark-cli") or "lark-cli"
    environment = os.environ.copy()
    environment["LARK_CLI_NO_PROXY_WARN"] = "1"
    _set_listener_runtime("starting")
    try:
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
    except (OSError, subprocess.SubprocessError):
        _set_listener_runtime("offline", "consumer spawn failed")
        raise
    if process.stdin is None or process.stdout is None or process.stderr is None:
        raise RuntimeError("Lark event consumer pipes are unavailable")

    ready_event = threading.Event()
    stderr_done = threading.Event()
    def drain_stderr() -> None:
        try:
            for line in process.stderr:
                cleaned = line.strip()
                if "[event] ready event_key=im.message.receive_v1" in line:
                    ready_event.set()
                elif cleaned:
                    try:
                        append_log("inbound-listener", cleaned)
                    except OSError:
                        pass
        finally:
            stderr_done.set()

    stderr_worker = threading.Thread(
        target=drain_stderr,
        name="claude-feishu-listener-stderr",
        daemon=True,
    )
    stderr_worker.start()

    while not ready_event.wait(0.05):
        if stop_event.is_set():
            _stop_listener_process(process)
            stderr_worker.join(timeout=2)
            _set_listener_runtime("offline", "stopped before ready")
            return 0
        if stderr_done.is_set() or process.poll() is not None:
            _stop_listener_process(process)
            stderr_worker.join(timeout=2)
            _set_listener_runtime("offline", "ready marker missing")
            raise RuntimeError("Lark event consumer did not emit its ready marker")
    _set_listener_runtime("ready")

    def stop_watcher() -> None:
        stop_event.wait()
        _stop_listener_process(process)

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
        _stop_listener_process(process)
        stderr_worker.join(timeout=2)
        _set_listener_runtime("offline")
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
