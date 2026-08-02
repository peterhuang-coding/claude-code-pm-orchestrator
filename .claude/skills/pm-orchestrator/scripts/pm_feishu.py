#!/usr/bin/env python3
"""Durable state and delivery helpers for the Claude Feishu gateway."""

from __future__ import annotations

import hashlib
import json
import os
import fcntl
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional


REQUEST_BYTE_LIMIT = 19_500
MESSAGE_LIMIT = 20_000
ROOT_LABEL = "Portfolio / Boss"
SUPPORTED_EVENTS = {"Stop", "StopFailure", "Notification"}
ON_PHRASES = {"我现在外出了"}
OFF_PHRASES = {"我回来了", "我没外出", "没外出"}
KEYCHAIN_SERVICE = "claude-feishu-gateway"
KEYCHAIN_ACCOUNT = "webhook"
LARK_CHANNEL_FILE = "channel.json"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def runtime_dir() -> Path:
    hub = Path(
        os.environ.get("PM_HUB_HOME", "/Volumes/SanDisk2TB/claude-pm-hub")
    ).expanduser()
    path = hub / "runtime" / "feishu"
    for child in ("pending", "delivered", "expired", "logs"):
        (path / child).mkdir(parents=True, exist_ok=True)
    return path


def _read_json(path: Path, default: dict[str, Any]) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return dict(default)
    return value if isinstance(value, dict) else dict(default)


def _atomic_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        delete=False,
    ) as temporary:
        json.dump(value, temporary, ensure_ascii=False, sort_keys=True)
        temporary.write("\n")
        temporary.flush()
        os.fsync(temporary.fileno())
        temporary_path = Path(temporary.name)
    os.replace(temporary_path, path)


def load_state() -> dict[str, Any]:
    return _read_json(
        runtime_dir() / "state.json",
        {"enabled": False, "updated_at": None},
    )


def set_enabled(enabled: bool) -> dict[str, Any]:
    state = {"enabled": bool(enabled), "updated_at": utc_now()}
    _atomic_json(runtime_dir() / "state.json", state)
    return state


def load_boss() -> dict[str, Any]:
    return _read_json(
        runtime_dir() / "boss.json",
        {"session_id": None, "cwd": None, "bound_at": None},
    )


def bind_boss(session_id: str, cwd: str) -> None:
    if not session_id:
        return
    _atomic_json(
        runtime_dir() / "boss.json",
        {
            "session_id": session_id,
            "cwd": cwd,
            "bound_at": utc_now(),
        },
    )


def is_active_boss(session_id: str) -> bool:
    return bool(session_id) and session_id == load_boss().get("session_id")


def apply_switch_phrase(prompt: str) -> Optional[bool]:
    normalized = prompt.strip().rstrip("。！!")
    if normalized in ON_PHRASES:
        set_enabled(True)
        return True
    if normalized in OFF_PHRASES:
        set_enabled(False)
        return False
    return None


def _event_id(event: dict[str, Any]) -> str:
    stable = {
        key: event.get(key)
        for key in (
            "hook_event_name",
            "session_id",
            "last_assistant_message",
            "message",
            "notification_type",
            "error",
            "error_details",
        )
    }
    transcript_path = str(event.get("transcript_path", ""))
    if transcript_path:
        try:
            stat = Path(transcript_path).expanduser().stat()
            stable["transcript_revision"] = [stat.st_size, stat.st_mtime_ns]
        except OSError:
            stable["transcript_revision"] = transcript_path
    serialized = json.dumps(
        stable, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    )
    return hashlib.sha256(serialized.encode("utf-8")).hexdigest()


def enqueue_hook_event(event: dict[str, Any]) -> bool:
    event_name = str(event.get("hook_event_name", ""))
    if event_name not in SUPPORTED_EVENTS:
        return False
    if not bool(load_state().get("enabled")):
        return False
    boss = load_boss()
    session_id = str(event.get("session_id", ""))
    if not session_id or session_id != boss.get("session_id"):
        return False
    if event.get("agent_id") or event.get("agent_type"):
        return False

    event_id = _event_id(event)
    root = runtime_dir()
    pending = root / "pending" / f"{event_id}.json"
    delivered = root / "delivered" / f"{event_id}.json"
    if pending.exists() or delivered.exists():
        return False

    record = {
        "id": event_id,
        "event": event_name,
        "session_id": session_id,
        "cwd": str(event.get("cwd", "")),
        "created_at": utc_now(),
        "last_assistant_message": str(event.get("last_assistant_message", ""))[
            :MESSAGE_LIMIT
        ],
        "message": str(event.get("message", ""))[:MESSAGE_LIMIT],
        "title": str(event.get("title", ""))[:300],
        "notification_type": str(event.get("notification_type", ""))[:100],
        "error": str(event.get("error", ""))[:100],
        "error_details": str(event.get("error_details", ""))[:2_000],
    }
    _atomic_json(pending, record)
    return True


def pending_events() -> list[Path]:
    return sorted(
        (runtime_dir() / "pending").glob("*.json"),
        key=lambda path: (path.stat().st_mtime_ns, path.name),
    )


def acquire_gateway_lock():
    path = runtime_dir() / "gateway.lock"
    handle = path.open("a+", encoding="utf-8")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as error:
        handle.close()
        raise RuntimeError("Another claude-feishu console is already running") from error
    return handle


def expire_stale_events(max_age_seconds: int = 86_400) -> int:
    cutoff = time.time() - max_age_seconds
    expired = 0
    for path in pending_events():
        try:
            if path.stat().st_mtime >= cutoff:
                continue
            target = runtime_dir() / "expired" / path.name
            os.replace(path, target)
            append_log("expired", "Pending message expired", path.stem)
            expired += 1
        except FileNotFoundError:
            continue
    return expired


def mark_delivered(path: Path, response: dict[str, Any]) -> None:
    event = _read_json(path, {})
    event["delivered_at"] = utc_now()
    event["delivery"] = response
    target = runtime_dir() / "delivered" / path.name
    _atomic_json(target, event)
    path.unlink(missing_ok=True)


def append_log(kind: str, message: str, event_id: str = "") -> None:
    record = {
        "at": utc_now(),
        "kind": kind[:50],
        "event_id": event_id[:64],
        "message": message[:2_000],
    }
    log = runtime_dir() / "logs" / "gateway.jsonl"
    with log.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")


def save_lark_channel(
    chat_id: str,
    name: str = "Claude PM 总控",
    *,
    owner_open_id: str = "",
    boss_root: str = "/Volumes/SanDisk2TB",
) -> None:
    if not chat_id.startswith("oc_"):
        raise ValueError("A Feishu chat ID must start with oc_")
    _atomic_json(
        runtime_dir() / LARK_CHANNEL_FILE,
        {
            "transport": "lark-cli",
            "chat_id": chat_id,
            "name": name,
            "owner_open_id": owner_open_id,
            "boss_root": boss_root,
            "configured_at": utc_now(),
        },
    )


def lark_chat_id() -> str:
    test_chat_id = os.environ.get("PM_FEISHU_TEST_CHAT_ID", "")
    if test_chat_id:
        return test_chat_id
    channel = _read_json(runtime_dir() / LARK_CHANNEL_FILE, {})
    if channel.get("transport") != "lark-cli":
        return ""
    chat_id = str(channel.get("chat_id", ""))
    return chat_id if chat_id.startswith("oc_") else ""


def _lark_cli_send(
    payload: dict[str, Any], retries: int, timeout: float
) -> dict[str, Any]:
    executable = shutil.which("lark-cli")
    chat_id = lark_chat_id()
    if not executable or not chat_id:
        raise RuntimeError("Lark CLI channel is not configured")
    content = payload.get("content", {})
    text = str(content.get("text", "")) if isinstance(content, dict) else ""
    last_error = "unknown delivery error"
    for attempt in range(retries):
        try:
            result = subprocess.run(
                [
                    executable,
                    "im",
                    "+messages-send",
                    "--as",
                    "bot",
                    "--chat-id",
                    chat_id,
                    "--text",
                    text,
                    "--format",
                    "json",
                ],
                capture_output=True,
                text=True,
                timeout=max(timeout, 1),
                check=False,
            )
            parsed = json.loads(result.stdout)
            if result.returncode != 0 or not isinstance(parsed, dict) or not parsed.get("ok"):
                raise RuntimeError("Lark CLI rejected the message")
            return parsed
        except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
            last_error = type(error).__name__
            if attempt + 1 < retries:
                time.sleep(0.2 * (2**attempt))
    raise RuntimeError(f"Feishu delivery failed: {last_error}")


def webhook_url() -> str:
    test_url = os.environ.get("PM_FEISHU_TEST_WEBHOOK", "")
    if test_url:
        return test_url
    result = subprocess.run(
        [
            "security",
            "find-generic-password",
            "-s",
            KEYCHAIN_SERVICE,
            "-a",
            KEYCHAIN_ACCOUNT,
            "-w",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    value = result.stdout.strip()
    if result.returncode != 0 or not value:
        raise RuntimeError(
            "Feishu webhook is not configured. Run: claude-feishu configure"
        )
    if not value.startswith("https://open.feishu.cn/open-apis/bot/v2/hook/"):
        raise RuntimeError("The Keychain value is not a Feishu bot webhook URL")
    return value


def is_configured() -> bool:
    if lark_chat_id() and shutil.which("lark-cli"):
        return True
    try:
        webhook_url()
    except RuntimeError:
        return False
    return True


def send_payload(
    payload: dict[str, Any], retries: int = 3, timeout: float = 10
) -> dict[str, Any]:
    if (
        not os.environ.get("PM_FEISHU_TEST_WEBHOOK")
        and lark_chat_id()
        and shutil.which("lark-cli")
    ):
        return _lark_cli_send(payload, retries=retries, timeout=timeout)
    url = webhook_url()
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    last_error = "unknown delivery error"
    for attempt in range(retries):
        request = urllib.request.Request(
            url,
            data=body,
            headers={"content-type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                response_body = response.read().decode("utf-8")
            parsed = json.loads(response_body)
            if not isinstance(parsed, dict) or parsed.get("code") != 0:
                raise RuntimeError("Feishu rejected the message")
            return parsed
        except (
            OSError,
            RuntimeError,
            ValueError,
            urllib.error.URLError,
        ) as error:
            last_error = type(error).__name__
            if attempt + 1 < retries:
                time.sleep(0.2 * (2**attempt))
    raise RuntimeError(f"Feishu delivery failed: {last_error}")


def _text_payload(prefix: str, body: str) -> dict[str, Any]:
    low = 0
    high = min(len(body), MESSAGE_LIMIT)
    best = prefix
    truncated = high < len(body)
    while low <= high:
        middle = (low + high) // 2
        candidate = prefix + body[:middle]
        if middle < len(body):
            candidate += "…"
        payload = {"msg_type": "text", "content": {"text": candidate}}
        encoded = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        if len(encoded) <= REQUEST_BYTE_LIMIT:
            best = candidate
            truncated = middle < len(body)
            low = middle + 1
        else:
            high = middle - 1
    if truncated and not best.endswith("…"):
        best += "…"
    return {"msg_type": "text", "content": {"text": best}}


def send_text(
    text: str, retries: int = 3, timeout: float = 10
) -> dict[str, Any]:
    return send_payload(
        _text_payload("", text),
        retries=retries,
        timeout=timeout,
    )


def reply_text(
    message_id: str, text: str, retries: int = 3, timeout: float = 10
) -> dict[str, Any]:
    executable = shutil.which("lark-cli")
    if not executable or not message_id.startswith("om_"):
        raise RuntimeError("Lark CLI reply target is not configured")
    bounded = _text_payload("", text)["content"]["text"]
    idempotency_key = "reply-" + hashlib.sha256(
        f"{message_id}\n{bounded}".encode("utf-8")
    ).hexdigest()[:32]
    last_error = "unknown delivery error"
    for attempt in range(retries):
        try:
            result = subprocess.run(
                [
                    executable,
                    "im",
                    "+messages-reply",
                    "--as",
                    "bot",
                    "--message-id",
                    message_id,
                    "--text",
                    bounded,
                    "--idempotency-key",
                    idempotency_key,
                    "--format",
                    "json",
                ],
                capture_output=True,
                text=True,
                timeout=max(timeout, 1),
                check=False,
            )
            parsed = json.loads(result.stdout)
            if result.returncode != 0 or not isinstance(parsed, dict) or not parsed.get("ok"):
                raise RuntimeError("Lark CLI rejected the reply")
            return parsed
        except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
            last_error = type(error).__name__
            if attempt + 1 < retries:
                time.sleep(0.2 * (2**attempt))
    raise RuntimeError(f"Feishu reply failed: {last_error}")


def deliver_pending(
    retries: int = 1, timeout: float = 3
) -> tuple[int, int]:
    if not bool(load_state().get("enabled")):
        return 0, 0
    try:
        expire_stale_events()
        paths = pending_events()
    except OSError:
        return 0, 1
    delivered = 0
    failed = 0
    for path in paths:
        if not bool(load_state().get("enabled")):
            break
        event = _read_json(path, {})
        delivered_path = runtime_dir() / "delivered" / path.name
        if delivered_path.exists():
            path.unlink(missing_ok=True)
            continue
        try:
            response = send_payload(
                format_feishu_payload(event),
                retries=retries,
                timeout=timeout,
            )
            mark_delivered(path, response)
            append_log("delivered", "Message delivered", str(event.get("id", "")))
            delivered += 1
        except (RuntimeError, OSError) as error:
            try:
                append_log("delivery-error", str(error), str(event.get("id", "")))
            except OSError:
                pass
            failed += 1
            break
    return delivered, failed


def format_feishu_payload(event: dict[str, Any]) -> dict[str, Any]:
    event_name = str(event.get("event", "Stop"))
    session = str(event.get("session_id", ""))[:8] or "unknown"
    if event_name == "StopFailure":
        heading = "Claude 调用失败"
        body = str(event.get("last_assistant_message") or event.get("error_details"))
    elif event_name == "Notification":
        heading = str(event.get("title") or "Claude 需要关注")
        body = str(event.get("message", ""))
    else:
        heading = "Claude 已回复"
        body = str(event.get("last_assistant_message", ""))

    lowered = body.lower()
    matches = []
    registry = runtime_dir().parent.parent / "config" / "projects.tsv"
    try:
        lines = registry.read_text(encoding="utf-8").splitlines()
    except OSError:
        lines = []
    for line in lines:
        fields = line.split("\t", 1)
        if len(fields) != 2:
            continue
        project_id, project_path = fields
        aliases = {
            project_id.lower(),
            project_id.lower().replace("-", " "),
        }
        cwd = str(event.get("cwd", ""))
        if cwd == project_path or any(alias in lowered for alias in aliases):
            matches.append(project_id)
    if len(matches) == 1:
        project = matches[0]
    elif len(matches) > 1:
        project = f"Portfolio ({len(matches)} projects)"
    else:
        project = ROOT_LABEL

    summary = ""
    for line in body.splitlines():
        cleaned = line.strip().lstrip("#*-` ").strip()
        if cleaned:
            summary = cleaned[:120]
            break
    prefix = "".join(
        [
            f"【{project} · {heading}】\n",
            f"项目：{project}\n",
            f"摘要：{summary}\n" if summary else "",
            f"会话：{session}\n",
            f"时间：{event.get('created_at', utc_now())}\n\n",
        ]
    )
    return _text_payload(prefix, body)
