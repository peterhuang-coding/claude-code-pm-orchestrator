#!/usr/bin/env python3
"""Manage provider credentials and public provider-router state."""

from __future__ import annotations

import argparse
import getpass
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, NoReturn


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


def fail(message: str) -> NoReturn:
    print(f"pm-provider: {message}", file=sys.stderr)
    raise SystemExit(1)


def provider_home() -> Path:
    return Path(
        os.environ.get("PM_PROVIDER_HOME", "~/.claude/provider-router")
    ).expanduser()


def template_path() -> Path:
    return Path(__file__).resolve().parents[3] / "templates" / "provider-router-config.json"


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


def initialize_home() -> tuple[Path, Path]:
    root = provider_home()
    config = root / "config.json"
    state = root / "state.json"
    try:
        if not config.exists():
            atomic_write(config, template_path().read_bytes())
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


def credential_is_configured(provider: str) -> bool:
    fake_path = fake_key_path(provider)
    if fake_path is not None:
        try:
            error_path = fake_error_path(provider, "find")
            if error_path is not None and error_path.is_file():
                fail(f"could not query credential for {provider}")
            return fake_path.is_file()
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
            check=False,
        )
    except OSError:
        fail(f"could not query credential for {provider}")
    if result.returncode == 0:
        return True
    if result.returncode == KEYCHAIN_ITEM_NOT_FOUND:
        return False
    fail(f"could not query credential for {provider}")


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


def status_command(state_path: Path, as_json: bool) -> int:
    state = read_state(state_path)
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
    }
    if as_json:
        print(json.dumps(status, indent=2))
        return 0

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


def use_command(state_path: Path, mode: str) -> int:
    state = read_state(state_path)
    state["active"] = True
    state["mode"] = mode
    state["current_provider"] = None if mode == "auto" else mode
    write_state(state_path, state)
    print(f"Provider mode set to {mode}.")
    return 0


def reset_command(state_path: Path, provider: str | None) -> int:
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

    return parser.parse_args()


def main() -> int:
    args = parse_args()
    _, state_path = initialize_home()
    if args.command == "set":
        return set_command(args.provider)
    if args.command == "remove":
        return remove_command(args.provider)
    if args.command == "status":
        return status_command(state_path, args.as_json)
    if args.command == "use":
        return use_command(state_path, args.mode)
    return reset_command(state_path, args.provider)


if __name__ == "__main__":
    raise SystemExit(main())
