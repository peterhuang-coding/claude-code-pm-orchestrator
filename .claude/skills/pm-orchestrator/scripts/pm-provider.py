#!/usr/bin/env python3
"""Manage provider credentials and public provider-router state."""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import getpass
import http.client
import json
import os
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Iterator, NoReturn


SERVICE = "claude-pm-provider-router"
VALID_PROVIDERS = ("minimax", "glm", "deepseek")
DEFAULT_STATE = {
    "active": False,
    "mode": "auto",
    "cooldowns": {},
    "current_provider": None,
    "last_transition": None,
}
KEYCHAIN_ITEM_NOT_FOUND = 44
CONTROL_BODY_LIMIT = 8 * 1024
LOG_LIMIT = 64 * 1024
CODING_PROVIDER_FIELDS = {
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_CUSTOM_MODEL_OPTION",
    "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME",
    "ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION",
    "CLAUDE_MODEL",
    "CLAUDE_CODE_SUBAGENT_MODEL",
}


def fail(message: str) -> NoReturn:
    print(f"pm-provider: {message}", file=sys.stderr)
    raise SystemExit(1)


def provider_home() -> Path:
    return Path(
        os.environ.get("PM_PROVIDER_HOME", "~/.claude/provider-router")
    ).expanduser()


def template_path() -> Path:
    return Path(__file__).resolve().parents[3] / "templates" / "provider-router-config.json"


def router_path() -> Path:
    return Path(__file__).resolve().with_name("pm-provider-router.js")


def atomic_write(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def atomic_write_json(path: Path, value: object) -> None:
    content = (json.dumps(value, indent=2) + "\n").encode("utf-8")
    atomic_write(path, content)


def migrate_provider_config(config_path: Path) -> None:
    try:
        config = json.loads(config_path.read_text(encoding="utf-8"))
        template = json.loads(template_path().read_text(encoding="utf-8"))
        providers = config.get("providers", [])
        template_providers = template.get("providers", [])
        desired_by_id = {item["id"]: item for item in template_providers}
        current_by_id = {item["id"]: item for item in providers}
    except (OSError, json.JSONDecodeError, AttributeError, StopIteration, TypeError):
        fail("could not migrate config")

    changed = False
    for provider_id, desired in desired_by_id.items():
        current = current_by_id.get(provider_id)
        if current is None:
            continue
        for field in ("base_url", "model", "auth_scheme"):
            if current.get(field) != desired.get(field):
                current[field] = desired[field]
                changed = True
    if changed:
        try:
            atomic_write_json(config_path, config)
        except OSError:
            fail("could not migrate config")


def initialize_home() -> tuple[Path, Path]:
    root = provider_home()
    config = root / "config.json"
    state = root / "state.json"
    try:
        if not config.exists():
            atomic_write(config, template_path().read_bytes())
        else:
            migrate_provider_config(config)
    except OSError:
        fail("could not initialize config")
    try:
        if not state.exists():
            atomic_write_json(state, DEFAULT_STATE)
    except OSError:
        fail("could not initialize state")
    return config, state


def read_state(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        fail("could not read state")
    if not isinstance(value, dict):
        fail("state must be a JSON object")
    state = dict(DEFAULT_STATE)
    state.update(value)
    if not isinstance(state["cooldowns"], dict):
        fail("state cooldowns must be a JSON object")
    return state


def fake_key_path(provider: str) -> Path | None:
    directory = os.environ.get("PM_PROVIDER_KEYCHAIN_DIR")
    return Path(directory).expanduser() / provider if directory else None


def fake_error_path(provider: str, operation: str) -> Path | None:
    credential_path = fake_key_path(provider)
    if credential_path is None:
        return None
    return credential_path.parent / f".{operation}-error-{provider}"


def read_credential(provider: str) -> str | None:
    fake_path = fake_key_path(provider)
    if fake_path is not None:
        try:
            error_path = fake_error_path(provider, "find")
            if error_path is not None and error_path.is_file():
                fail(f"could not query credential for {provider}")
            return fake_path.read_text(encoding="utf-8") if fake_path.is_file() else None
        except OSError:
            fail(f"could not query credential for {provider}")
    try:
        result = subprocess.run(
            [
                "/usr/bin/security",
                "find-generic-password",
                "-w",
                "-s",
                SERVICE,
                "-a",
                provider,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
    except OSError:
        fail(f"could not query credential for {provider}")
    if result.returncode == 0:
        return result.stdout.rstrip("\r\n")
    if result.returncode == KEYCHAIN_ITEM_NOT_FOUND:
        return None
    fail(f"could not query credential for {provider}")


def credential_is_configured(provider: str) -> bool:
    return read_credential(provider) is not None


def store_credential(provider: str, credential: str) -> None:
    fake_path = fake_key_path(provider)
    if fake_path is not None:
        try:
            atomic_write(fake_path, credential.encode("utf-8"))
        except OSError:
            fail(f"could not store credential for {provider}")
        return
    try:
        result = subprocess.run(
            [
                "/usr/bin/security",
                "add-generic-password",
                "-U",
                "-s",
                SERVICE,
                "-a",
                provider,
                "-w",
            ],
            input=credential + "\n",
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError:
        fail(f"could not store credential for {provider}")
    if result.returncode != 0:
        fail(f"could not store credential for {provider}")


def remove_credential(provider: str) -> None:
    fake_path = fake_key_path(provider)
    if fake_path is not None:
        try:
            error_path = fake_error_path(provider, "delete")
            if error_path is not None and error_path.is_file():
                fail(f"could not remove credential for {provider}")
            fake_path.unlink(missing_ok=True)
        except OSError:
            fail(f"could not remove credential for {provider}")
        return
    try:
        result = subprocess.run(
            [
                "/usr/bin/security",
                "delete-generic-password",
                "-s",
                SERVICE,
                "-a",
                provider,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError:
        fail(f"could not remove credential for {provider}")
    if result.returncode not in (0, KEYCHAIN_ITEM_NOT_FOUND):
        fail(f"could not remove credential for {provider}")


def write_state(path: Path, state: dict[str, Any]) -> None:
    try:
        atomic_write_json(path, state)
    except OSError:
        fail("could not write state")


def read_config(config_path: Path) -> dict[str, Any]:
    try:
        config = json.loads(config_path.read_text(encoding="utf-8"))
        listen = config["listen"]
        host = listen["host"]
        port = listen["port"]
    except (OSError, json.JSONDecodeError, KeyError, TypeError):
        fail("could not read config")
    if host not in ("127.0.0.1", "::1", "localhost"):
        fail("config listen host must be loopback")
    if not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535:
        fail("config listen port is invalid")
    return config


def pid_path() -> Path:
    return provider_home() / "router.pid"


def log_path() -> Path:
    return provider_home() / "router.log"


@contextlib.contextmanager
def lifecycle_lock() -> Iterator[None]:
    path = provider_home() / "router.lock"
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a+", encoding="utf-8") as stream:
            os.chmod(path, 0o600)
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
            yield
    except OSError:
        fail("could not lock provider router lifecycle")


def read_pid_record() -> dict[str, Any] | None:
    path = pid_path()
    if not path.exists():
        return None
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        fail("could not read router PID file")
    if (
        not isinstance(value, dict)
        or not isinstance(value.get("pid"), int)
        or isinstance(value.get("pid"), bool)
        or value["pid"] <= 1
        or not isinstance(value.get("instance_id"), str)
        or not value["instance_id"]
    ):
        fail("router PID file is invalid")
    return value


def process_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def process_command(pid: int) -> str:
    try:
        result = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "command="],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
    except OSError:
        fail("could not inspect router process")
    return result.stdout.strip() if result.returncode == 0 else ""


def record_is_owned(record: dict[str, Any]) -> bool:
    command = process_command(record["pid"])
    return (
        str(router_path()) in command
        and "--instance-id" in command
        and record["instance_id"] in command
    )


def remove_pid_file() -> None:
    try:
        pid_path().unlink(missing_ok=True)
    except OSError:
        fail("could not remove router PID file")


def daemon_record() -> dict[str, Any] | None:
    record = read_pid_record()
    if record is None:
        return None
    if not process_alive(record["pid"]):
        remove_pid_file()
        return None
    if not record_is_owned(record):
        fail("refusing unrelated live process in router PID file")
    return record


def control_request(
    method: str,
    endpoint: str,
    token: str,
    port: int,
    body: dict[str, Any] | None = None,
    quiet: bool = False,
) -> dict[str, Any]:
    payload = None
    headers = {"Authorization": f"Bearer {token}"}
    if body is not None:
        payload = json.dumps(body).encode("utf-8")
        if len(payload) > CONTROL_BODY_LIMIT:
            fail("control request is too large")
        headers["Content-Type"] = "application/json"
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=0.5)
    try:
        connection.request(method, endpoint, body=payload, headers=headers)
        response = connection.getresponse()
        response_body = response.read(CONTROL_BODY_LIMIT + 1)
        if not 200 <= response.status < 300 or len(response_body) > CONTROL_BODY_LIMIT:
            raise ValueError("invalid control response")
        value = json.loads(response_body)
    except (OSError, http.client.HTTPException, json.JSONDecodeError, ValueError):
        if quiet:
            return {}
        fail("provider router control request failed")
    finally:
        connection.close()
    if not isinstance(value, dict):
        if quiet:
            return {}
        fail("provider router returned an invalid control response")
    return value


def daemon_health(record: dict[str, Any], token: str, port: int) -> bool:
    value = control_request("GET", "/_pm/health", token, port, quiet=True)
    return value.get("status") == "ok" and value.get("pid") == record["pid"]


def prepare_log() -> Any:
    path = log_path()
    try:
        if path.exists() and path.stat().st_size > LOG_LIMIT:
            with path.open("rb") as stream:
                stream.seek(-LOG_LIMIT, os.SEEK_END)
                tail = stream.read(LOG_LIMIT)
            atomic_write(path, tail)
        stream = path.open("ab", buffering=0)
        os.chmod(path, 0o600)
        return stream
    except OSError:
        fail("could not open router operational log")


def ensure_command(config_path: Path) -> tuple[int, str]:
    config = read_config(config_path)
    port = config["listen"]["port"]
    with lifecycle_lock():
        local_token = read_credential("router-local")
        if local_token is None:
            local_token = secrets.token_urlsafe(32)
            store_credential("router-local", local_token)

        record = daemon_record()
        if record is not None:
            if daemon_health(record, local_token, port):
                print(f"Provider router ready (PID {record['pid']}).")
                return port, local_token
            terminate_owned_daemon(record)

        node = shutil.which("node")
        if node is None:
            fail("node is required to start provider router")
        instance_id = secrets.token_urlsafe(18)
        daemon_environment = {
            "PM_PROVIDER_HOME": str(provider_home()),
            "PM_PROVIDER_CONFIG": str(config_path),
        }
        fake_keychain = os.environ.get("PM_PROVIDER_KEYCHAIN_DIR")
        if fake_keychain:
            daemon_environment["PM_PROVIDER_KEYCHAIN_DIR"] = fake_keychain
        log_stream = prepare_log()
        try:
            process = subprocess.Popen(
                [node, str(router_path()), "--instance-id", instance_id],
                stdin=subprocess.DEVNULL,
                stdout=log_stream,
                stderr=subprocess.STDOUT,
                start_new_session=True,
                close_fds=True,
                env=daemon_environment,
            )
        except OSError:
            fail("could not start provider router")
        finally:
            log_stream.close()

        record = {"pid": process.pid, "instance_id": instance_id}
        try:
            atomic_write_json(pid_path(), record)
        except OSError:
            process.terminate()
            fail("could not write router PID file")

        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if process.poll() is not None:
                remove_pid_file()
                fail("provider router exited during startup")
            if daemon_health(record, local_token, port):
                print(f"Provider router ready (PID {process.pid}).")
                return port, local_token
            time.sleep(0.05)
        process.terminate()
        remove_pid_file()
        fail("provider router did not become healthy")


def terminate_owned_daemon(record: dict[str, Any]) -> None:
    try:
        os.kill(record["pid"], signal.SIGTERM)
    except ProcessLookupError:
        remove_pid_file()
        return
    except OSError:
        fail("could not stop provider router")
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline and process_alive(record["pid"]):
        time.sleep(0.05)
    if process_alive(record["pid"]):
        fail("provider router did not stop")
    remove_pid_file()


def stop_command() -> int:
    with lifecycle_lock():
        record = daemon_record()
        if record is None:
            print("Provider router is not running.")
            return 0
        terminate_owned_daemon(record)
    print("Provider router stopped.")
    return 0


def active_daemon(config_path: Path) -> tuple[dict[str, Any], str, int] | None:
    record = daemon_record()
    if record is None:
        return None
    token = read_credential("router-local")
    if token is None:
        fail("router-local credential is unavailable")
    port = read_config(config_path)["listen"]["port"]
    if not daemon_health(record, token, port):
        return None
    return record, token, port


def set_command(provider: str) -> int:
    if sys.stdin.isatty():
        credential = getpass.getpass("API key: ")
    else:
        credential = sys.stdin.read()
        if credential.endswith("\n"):
            credential = credential[:-1]
            if credential.endswith("\r"):
                credential = credential[:-1]
    if not credential:
        fail("credential must not be empty")
    store_credential(provider, credential)
    print(f"Credential stored for {provider}.")
    return 0


def remove_command(provider: str) -> int:
    remove_credential(provider)
    print(f"Credential removed for {provider}.")
    return 0


def settings_path() -> Path:
    return Path(
        os.environ.get("PM_CLAUDE_SETTINGS", "~/.claude/settings.json")
    ).expanduser()


def legacy_provider(env: dict[str, Any]) -> str | None:
    fingerprint = " ".join(
        str(env.get(name, ""))
        for name in ("ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL", "CLAUDE_MODEL")
    ).lower()
    if "deepseek" in fingerprint:
        return "deepseek"
    if "sfkey" in fingerprint or "glm" in fingerprint:
        return "glm"
    if "minimax" in fingerprint:
        return "minimax"
    return None


def setup_command(state_path: Path) -> int:
    path = settings_path()
    try:
        settings = (
            json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
        )
    except (OSError, json.JSONDecodeError):
        fail("could not read Claude settings")
    if not isinstance(settings, dict):
        fail("Claude settings must be a JSON object")
    env = settings.get("env", {})
    if not isinstance(env, dict):
        fail("Claude settings env must be a JSON object")

    legacy_token = env.get("ANTHROPIC_AUTH_TOKEN") or env.get("ANTHROPIC_API_KEY")
    provider = legacy_provider(env)
    if legacy_token and provider and not credential_is_configured(provider):
        if not isinstance(legacy_token, str):
            fail("legacy provider credential is invalid")
        store_credential(provider, legacy_token)
        if read_credential(provider) != legacy_token:
            fail(f"could not verify migrated credential for {provider}")

    if not credential_is_configured("minimax"):
        fail("MiniMax credential is required before provider setup")

    updated = dict(settings)
    updated_env = dict(env)
    for field in CODING_PROVIDER_FIELDS:
        updated_env.pop(field, None)
    updated["env"] = updated_env
    if updated != settings:
        try:
            atomic_write_json(path, updated)
        except OSError:
            fail("could not update Claude settings")

    state = read_state(state_path)
    state["active"] = True
    state["mode"] = "auto"
    state["current_provider"] = None
    write_state(state_path, state)
    configured = [
        provider for provider in VALID_PROVIDERS if credential_is_configured(provider)
    ]
    print(f"Provider routing activated: {', '.join(configured)}.")
    return 0


def status_command(config_path: Path, state_path: Path, as_json: bool) -> int:
    daemon = active_daemon(config_path)
    state = (
        control_request("GET", "/_pm/status", daemon[1], daemon[2])
        if daemon is not None
        else read_state(state_path)
    )
    status = {
        "active": bool(state["active"]),
        "mode": state["mode"],
        "providers": {
            provider: {"configured": credential_is_configured(provider)}
            for provider in VALID_PROVIDERS
        },
        "current_provider": state["current_provider"],
        "cooldowns": state["cooldowns"],
        "last_transition": state["last_transition"],
        "daemon": {
            "running": daemon is not None,
            "pid": daemon[0]["pid"] if daemon is not None else None,
        },
    }
    if as_json:
        print(json.dumps(status, indent=2))
        return 0

    daemon_label = status["daemon"]["pid"] if status["daemon"]["running"] else "not running"
    print(f"daemon: {daemon_label}")
    print(f"active: {'yes' if status['active'] else 'no'}")
    print(f"mode: {status['mode']}")
    current = status["current_provider"] or "none"
    print(f"current provider: {current}")
    transition = status["last_transition"]
    transition_label = "none" if transition is None else json.dumps(transition, sort_keys=True)
    print(f"last transition: {transition_label}")
    for provider in VALID_PROVIDERS:
        configured = status["providers"][provider]["configured"]
        label = "configured" if configured else "not configured"
        print(f"{provider}: {label}")
    if status["cooldowns"]:
        print(f"cooldowns: {json.dumps(status['cooldowns'], sort_keys=True)}")
    else:
        print("cooldowns: none")
    return 0


def use_command(config_path: Path, state_path: Path, mode: str) -> int:
    daemon = active_daemon(config_path)
    if daemon is not None:
        control_request("POST", "/_pm/mode", daemon[1], daemon[2], {"mode": mode})
        print(f"Provider mode set to {mode}.")
        return 0
    state = read_state(state_path)
    state["active"] = True
    state["mode"] = mode
    state["current_provider"] = None if mode == "auto" else mode
    write_state(state_path, state)
    print(f"Provider mode set to {mode}.")
    return 0


def reset_command(config_path: Path, state_path: Path, provider: str | None) -> int:
    daemon = active_daemon(config_path)
    if daemon is not None:
        control_request(
            "POST", "/_pm/reset", daemon[1], daemon[2], {"provider": provider}
        )
        target = provider or "all providers"
        print(f"Reset state for {target}.")
        return 0
    state = read_state(state_path)
    if provider is None:
        state["cooldowns"] = {}
        state["current_provider"] = None
        state["last_transition"] = None
    else:
        state["cooldowns"].pop(provider, None)
    write_state(state_path, state)
    target = provider or "all providers"
    print(f"Reset state for {target}.")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Manage Claude PM provider routing")
    commands = parser.add_subparsers(dest="command", required=True)

    set_parser = commands.add_parser("set")
    set_parser.add_argument("provider", choices=VALID_PROVIDERS)

    remove_parser = commands.add_parser("remove")
    remove_parser.add_argument("provider", choices=VALID_PROVIDERS)

    status_parser = commands.add_parser("status")
    status_parser.add_argument("--json", action="store_true", dest="as_json")

    use_parser = commands.add_parser("use")
    use_parser.add_argument("mode", choices=("auto", *VALID_PROVIDERS))

    reset_parser = commands.add_parser("reset")
    reset_parser.add_argument("provider", nargs="?", choices=VALID_PROVIDERS)

    setup_parser = commands.add_parser("setup")
    setup_parser.add_argument("--non-interactive", action="store_true")

    commands.add_parser("ensure")
    commands.add_parser("stop")

    exec_parser = commands.add_parser("exec")
    exec_parser.add_argument("exec_args", nargs=argparse.REMAINDER)

    return parser.parse_args()


def main() -> int:
    args = parse_args()
    config_path, state_path = initialize_home()
    if args.command == "set":
        return set_command(args.provider)
    if args.command == "remove":
        return remove_command(args.provider)
    if args.command == "status":
        return status_command(config_path, state_path, args.as_json)
    if args.command == "use":
        return use_command(config_path, state_path, args.mode)
    if args.command == "reset":
        return reset_command(config_path, state_path, args.provider)
    if args.command == "setup":
        return setup_command(state_path)
    if args.command == "ensure":
        ensure_command(config_path)
        return 0
    if args.command == "stop":
        return stop_command()
    if not args.exec_args:
        fail("exec requires a command")
    port, local_token = ensure_command(config_path)
    environment = dict(os.environ)
    environment.update(
        {
            "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{port}",
            "ANTHROPIC_AUTH_TOKEN": local_token,
            "ANTHROPIC_MODEL": "pm-auto",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": "pm-auto",
            "ANTHROPIC_DEFAULT_SONNET_MODEL": "pm-auto",
            "ANTHROPIC_DEFAULT_OPUS_MODEL": "pm-auto",
        }
    )
    try:
        os.execvpe(args.exec_args[0], args.exec_args, environment)
    except OSError:
        fail("could not execute command")


if __name__ == "__main__":
    raise SystemExit(main())
