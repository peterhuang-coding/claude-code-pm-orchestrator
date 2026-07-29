# Claude Feishu Gateway Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a two-terminal Feishu gateway that forwards only the active `/Volumes/SanDisk2TB` boss Claude session while away mode is enabled.

**Architecture:** Claude Code hooks append bounded events to a durable PM Hub queue. A visible `claude-feishu` console owns delivery to one Feishu custom-bot webhook, while `claude-yolo boss` marks exactly one top-level session as the Feishu-facing boss.

**Tech Stack:** Python 3 standard library, POSIX shell, Claude Code command hooks, macOS Keychain, Feishu custom-bot webhook.

---

## File Structure

- Create `.claude/skills/pm-orchestrator/scripts/pm_feishu.py`: state, queue, boss binding, formatting, Keychain lookup, and webhook delivery.
- Create `.claude/skills/pm-orchestrator/scripts/pm-feishu-hook.py`: bounded Claude hook adapter.
- Create `.claude/skills/pm-orchestrator/scripts/claude-feishu`: interactive and one-shot CLI.
- Modify `.claude/skills/pm-orchestrator/scripts/claude-yolo`: add the explicit `boss` launch mode.
- Modify `.claude/skills/pm-orchestrator/scripts/configure-claude-user.py`: install managed Feishu hooks idempotently.
- Modify `.claude/skills/pm-orchestrator/scripts/install-global.sh`: install and link the new CLI.
- Create `tests/test-pm-feishu.py`: deterministic unit tests for state, filtering, queueing, and formatting.
- Create `tests/test-claude-feishu.sh`: CLI, launcher, configurator, and fake-webhook integration tests.
- Modify `README.md`: document the two-terminal workflow and Keychain setup.

### Task 1: Durable State And Queue

**Files:**
- Create: `.claude/skills/pm-orchestrator/scripts/pm_feishu.py`
- Create: `tests/test-pm-feishu.py`

- [ ] **Step 1: Write failing state and queue tests**

```python
def test_state_defaults_off_and_persists(tmp_path, monkeypatch):
    monkeypatch.setenv("PM_HUB_HOME", str(tmp_path))
    assert load_state()["enabled"] is False
    set_enabled(True)
    assert load_state()["enabled"] is True

def test_only_active_boss_stop_is_queued(tmp_path, monkeypatch):
    monkeypatch.setenv("PM_HUB_HOME", str(tmp_path))
    set_enabled(True)
    bind_boss("boss-1", "/Volumes/SanDisk2TB")
    assert enqueue_hook_event(stop_event("boss-1")) is True
    assert enqueue_hook_event(stop_event("worker-1")) is False
```

- [ ] **Step 2: Run tests and verify RED**

Run: `python3 -m unittest tests/test-pm-feishu.py -v`

Expected: import failure because `pm_feishu.py` does not exist.

- [ ] **Step 3: Implement atomic state, boss binding, and file queue**

Implement:

```python
def runtime_dir() -> Path: ...
def load_state() -> dict[str, object]: ...
def set_enabled(enabled: bool) -> dict[str, object]: ...
def bind_boss(session_id: str, cwd: str) -> None: ...
def enqueue_hook_event(event: dict[str, object]) -> bool: ...
def pending_events() -> list[Path]: ...
def mark_delivered(path: Path, response: dict[str, object]) -> None: ...
```

Use temporary-file plus `os.replace` writes, one JSON file per event, stable
SHA-256 event IDs, a 20,000-character message limit, and directories under
`$PM_HUB_HOME/runtime/feishu`.

- [ ] **Step 4: Run tests and verify GREEN**

Run: `python3 -m unittest tests/test-pm-feishu.py -v`

Expected: all state, binding, filtering, and deduplication tests pass.

### Task 2: Claude Hook Adapter And Natural-Language Switch

**Files:**
- Create: `.claude/skills/pm-orchestrator/scripts/pm-feishu-hook.py`
- Modify: `.claude/skills/pm-orchestrator/scripts/configure-claude-user.py`
- Modify: `tests/test-pm-feishu.py`
- Modify: `tests/test-session-start.sh`

- [ ] **Step 1: Add failing hook tests**

Test exact phrase behavior:

```python
self.run_hook("UserPromptSubmit", prompt="我现在外出了")
self.assertTrue(load_state()["enabled"])
self.run_hook("UserPromptSubmit", prompt="我回来了")
self.assertFalse(load_state()["enabled"])
```

Test that `SessionStart` binds only when `PM_FEISHU_BOSS=1`, and that `Stop`,
`StopFailure`, and `Notification` never emit blocking decisions.

- [ ] **Step 2: Run tests and verify RED**

Run: `python3 -m unittest tests/test-pm-feishu.py -v`

Expected: hook entry point and managed hooks are missing.

- [ ] **Step 3: Implement the hook adapter**

The adapter reads one JSON object from stdin and:

```python
if event_name == "SessionStart" and os.getenv("PM_FEISHU_BOSS") == "1":
    bind_boss(session_id, cwd)
elif event_name == "UserPromptSubmit":
    apply_exact_switch_phrase(prompt)
elif event_name in {"Stop", "StopFailure", "Notification"}:
    enqueue_hook_event(event)
print("{}")
```

Invalid input, disk errors, and missing fields must exit successfully so the
gateway can never break a Claude turn.

- [ ] **Step 4: Register idempotent managed hooks**

Add `pm-feishu-hook.py` to `SessionStart`, `UserPromptSubmit`, `Stop`,
`StopFailure`, and `Notification` using the configurator's existing replacement
pattern. Preserve every unrelated user hook.

- [ ] **Step 5: Run hook and configurator tests**

Run:

```bash
python3 -m unittest tests/test-pm-feishu.py -v
sh tests/test-session-start.sh
```

Expected: all tests pass and a second configurator run produces no settings
change.

### Task 3: Feishu Delivery And Interactive Console

**Files:**
- Modify: `.claude/skills/pm-orchestrator/scripts/pm_feishu.py`
- Create: `.claude/skills/pm-orchestrator/scripts/claude-feishu`
- Create: `tests/test-claude-feishu.sh`

- [ ] **Step 1: Add failing delivery and CLI tests**

Use a local fake HTTP server and assert:

```text
claude-feishu on       -> enabled
claude-feishu off      -> disabled
claude-feishu status   -> boss, mode, queue, connection summary
claude-feishu test     -> one sanitized Feishu request
printf 'cloud on\ncloud status\ncloud quit\n' | claude-feishu
                       -> interactive state is shared
```

- [ ] **Step 2: Run the integration test and verify RED**

Run: `sh tests/test-claude-feishu.sh`

Expected: executable is missing.

- [ ] **Step 3: Implement Keychain and webhook delivery**

Read the webhook using:

```bash
security find-generic-password \
  -s claude-feishu-gateway \
  -a webhook \
  -w
```

Send JSON with `urllib.request`, a 10-second timeout, bounded exponential retry,
and Feishu response-code validation. Redact URLs and credentials from all errors.

- [ ] **Step 4: Implement one-shot and interactive commands**

The executable supports:

```text
claude-feishu
claude-feishu configure
claude-feishu on
claude-feishu off
claude-feishu status
claude-feishu test
claude-feishu logs
```

Interactive mode polls stdin and the queue. Accepted commands are `cloud on`,
`cloud off`, `cloud status`, `cloud test`, `cloud logs`, and `cloud quit`.

- [ ] **Step 5: Run integration tests and verify GREEN**

Run: `sh tests/test-claude-feishu.sh`

Expected: CLI, queue restart, fake webhook delivery, retry, and redaction tests
pass.

### Task 4: Explicit Boss Launcher

**Files:**
- Modify: `.claude/skills/pm-orchestrator/scripts/claude-yolo`
- Modify: `tests/test-claude-yolo.sh`

- [ ] **Step 1: Add a failing launcher test**

Invoke:

```bash
claude-yolo boss --name boss-test
```

Assert:

```text
PWD=/Volumes/SanDisk2TB
PM_FEISHU_BOSS=1
ARGS include --permission-mode bypassPermissions
```

Allow `PM_BOSS_ROOT` to override the disk path in tests.

- [ ] **Step 2: Run the launcher test and verify RED**

Run: `sh tests/test-claude-yolo.sh`

Expected: `boss` is treated as a normal argument or falls back to the PM Hub.

- [ ] **Step 3: Implement boss mode**

Before normal target classification:

```sh
if [ "${1-}" = boss ]; then
  shift
  TARGET=${PM_BOSS_ROOT:-/Volumes/SanDisk2TB}
  [ -d "$TARGET" ] || exit_with_clear_error
  export PM_FEISHU_BOSS=1
fi
```

Continue through the existing `claude-pm` launcher so provider and permission
behavior remain unchanged.

- [ ] **Step 4: Run launcher tests and verify GREEN**

Run: `sh tests/test-claude-yolo.sh`

Expected: existing modes and new boss mode all pass.

### Task 5: Global Installation And Documentation

**Files:**
- Modify: `.claude/skills/pm-orchestrator/scripts/install-global.sh`
- Modify: `tests/test-global-install.sh`
- Modify: `README.md`

- [ ] **Step 1: Add failing install assertions**

Assert the global install provides:

```text
~/.claude/bin/claude-feishu
~/.claude/skills/pm-orchestrator/scripts/pm-feishu-hook.py
~/.claude/skills/pm-orchestrator/scripts/pm_feishu.py
```

- [ ] **Step 2: Run install test and verify RED**

Run: `sh tests/test-global-install.sh`

Expected: missing `claude-feishu` link.

- [ ] **Step 3: Update installer and README**

Document:

```bash
claude-feishu configure

# Terminal 1
cd /Volumes/SanDisk2TB
claude-yolo boss

# Terminal 2
claude-feishu
```

Include `cloud on/off/status/test`, natural-language switches, outbound-only
scope, and the Keychain secret boundary.

- [ ] **Step 4: Run install tests and verify GREEN**

Run:

```bash
sh tests/test-global-install.sh
sh tests/test-feature-command-contract.sh
```

Expected: all installation and documentation contracts pass.

### Task 6: Full Verification And Local Installation

**Files:**
- No new files.

- [ ] **Step 1: Run syntax and unit verification**

Run:

```bash
python3 -m py_compile \
  .claude/skills/pm-orchestrator/scripts/pm_feishu.py \
  .claude/skills/pm-orchestrator/scripts/pm-feishu-hook.py
python3 -m unittest tests/test-pm-feishu.py -v
```

Expected: compilation and tests pass.

- [ ] **Step 2: Run all repository integration tests**

Run:

```bash
for test in tests/test-*.sh; do sh "$test"; done
```

Expected: every test prints `PASS`.

- [ ] **Step 3: Inspect diff and secret hygiene**

Run:

```bash
git diff --check
git grep -nE 'open-apis/bot/v2/hook/[A-Za-z0-9_-]+|app_secret|webhook_secret'
```

Expected: no whitespace errors and no real credentials.

- [ ] **Step 4: Commit implementation**

```bash
git add .claude README.md tests
git commit -m "feat: add Claude Feishu away-mode gateway"
```

- [ ] **Step 5: Install globally**

Run:

```bash
.claude/skills/pm-orchestrator/scripts/install-global.sh
python3 ~/.claude/skills/pm-orchestrator/scripts/configure-claude-user.py
```

Expected: `claude-feishu`, `claude-yolo boss`, and managed hooks are installed.

- [ ] **Step 6: Configure and perform a real Feishu smoke test**

Run:

```bash
claude-feishu configure
claude-feishu on
claude-feishu test
claude-feishu off
```

Expected: one test message appears in the selected Feishu destination, with no
secret printed locally.
