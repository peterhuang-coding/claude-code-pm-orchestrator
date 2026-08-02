# Claude Feishu Duplex Gateway Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the authorized owner send commands in the private Feishu PM chat and receive results from one persistent, unattended Claude Code boss session.

**Architecture:** Extend the existing gateway with a focused inbound module. The module consumes official Lark WebSocket events, persists accepted commands in a serial queue, runs or resumes a model-neutral Claude print session, and replies through Lark CLI.

**Tech Stack:** Python 3 standard library, official `lark-cli`, Claude Code CLI, JSON/NDJSON, macOS process management.

---

### Task 1: Inbound Event Policy and Durable Queue

**Files:**
- Create: `.claude/skills/pm-orchestrator/scripts/pm_feishu_inbound.py`
- Create: `tests/test-pm-feishu-inbound.py`

- [ ] **Step 1: Write failing policy tests**

Add tests that construct channel configuration and assert `accept_event()`
accepts only an owner-authored text event in the configured chat. Separate tests
must reject a bot sender, wrong chat, wrong user, empty content, unsupported
message type, and duplicate message ID.

- [ ] **Step 2: Verify RED**

Run:

```bash
python3 tests/test-pm-feishu-inbound.py
```

Expected: import or attribute failures because the inbound module does not exist.

- [ ] **Step 3: Implement queue primitives**

Implement:

```python
def inbound_dirs() -> dict[str, Path]: ...
def accept_event(event: dict[str, Any]) -> bool: ...
def pending_commands() -> list[Path]: ...
def mark_processed(path: Path, result: dict[str, Any]) -> None: ...
def mark_failed(path: Path, error: str) -> None: ...
```

Use `pm_feishu._atomic_json`, `runtime_dir()`, and message ID filenames.

- [ ] **Step 4: Verify GREEN**

Run the inbound unit tests and existing `test-pm-feishu.py`; expect all tests
to pass.

### Task 2: Persistent Claude Remote Boss

**Files:**
- Modify: `.claude/skills/pm-orchestrator/scripts/pm_feishu_inbound.py`
- Modify: `tests/test-pm-feishu-inbound.py`

- [ ] **Step 1: Write failing Claude command tests**

Test a fake runner and assert the first command uses:

```text
claude --print --session-id <uuid> --permission-mode bypassPermissions --effort max --output-format json
```

Assert the next command uses `--resume <same uuid>`, keeps the configured root
as `cwd`, preserves the user message, and does not set `PM_FEISHU_BOSS`.

- [ ] **Step 2: Verify RED**

Run the inbound test file; expect missing executor failures.

- [ ] **Step 3: Implement remote session execution**

Implement:

```python
def load_remote_session() -> dict[str, Any]: ...
def execute_remote_command(command: str, runner=subprocess.run) -> str: ...
```

Persist a UUID before the first call, parse Claude JSON output's `result`
field, and bound errors/output before returning.

- [ ] **Step 4: Verify GREEN**

Run unit tests; expect first-turn and resume tests to pass.

### Task 3: Lark Event Consumer and Replies

**Files:**
- Modify: `.claude/skills/pm-orchestrator/scripts/pm_feishu.py`
- Modify: `.claude/skills/pm-orchestrator/scripts/pm_feishu_inbound.py`
- Modify: `.claude/skills/pm-orchestrator/scripts/claude-feishu`
- Modify: `tests/test-pm-feishu.py`
- Modify: `tests/test-pm-feishu-inbound.py`

- [ ] **Step 1: Write failing listener/reply tests**

Use fake subprocesses to emit a ready marker and NDJSON events. Assert accepted
events are queued, bot events are ignored, source messages receive an
acknowledgement and final reply, and shutdown terminates the consumer.

- [ ] **Step 2: Verify RED**

Run both Python test files and confirm listener/reply symbols are missing.

- [ ] **Step 3: Implement Lark listener and reply helper**

Add:

```python
def reply_text(message_id: str, text: str, ...) -> dict[str, Any]: ...
class LarkEventListener:
    def run(self, stop: threading.Event) -> None: ...
    def close(self) -> None: ...
def drain_inbound_once() -> tuple[int, int]: ...
```

Use `lark-cli im +messages-reply --as bot --message-id ... --text ...` and the
official event ready-marker contract.

- [ ] **Step 4: Wire the gateway console**

Start inbound listener and serial inbound worker alongside the existing
outbound delivery worker. `cloud off` prevents execution; shutdown sets stop
events, closes listener stdin or sends SIGTERM, joins workers, and releases the
gateway lock.

- [ ] **Step 5: Verify GREEN**

Run Python and shell gateway tests; expect all to pass with no hanging process.

### Task 4: Configuration, Documentation, and Real Validation

**Files:**
- Modify: `.claude/skills/pm-orchestrator/scripts/claude-feishu`
- Modify: `README.md`
- Modify: `tests/test-claude-feishu.sh`

- [ ] **Step 1: Write failing configuration tests**

Assert `claude-feishu configure` saves the authenticated user's open ID and
root in `channel.json`, while printing no token or secret.

- [ ] **Step 2: Implement configuration metadata**

Read `lark-cli auth status`, extract `identities.user.openId`, and save it
with the chat ID. Refuse inbound mode when owner metadata is absent.

- [ ] **Step 3: Update docs**

Document one-command startup, supported Feishu message types, security filters,
status behavior, and the fact that the remote boss is a dedicated persisted
Claude session rather than the visible local terminal.

- [ ] **Step 4: Run complete regression**

```bash
for test in tests/test-*.sh; do sh "$test"; done
python3 tests/test-pm-feishu.py
python3 tests/test-pm-feishu-inbound.py
```

Expected: all test groups pass.

- [ ] **Step 5: Run real end-to-end smoke test**

Start `claude-feishu`, send one harmless Feishu command, and verify the
configured chat receives both acknowledgement and final reply. Confirm the
inbound pending queue is empty and the message ID appears once in processed.

- [ ] **Step 6: Install, merge, and push**

Run `install-global.sh`, merge `feat/feishu-duplex` into `main`, push, and
verify `claude-feishu status` reports duplex readiness.
