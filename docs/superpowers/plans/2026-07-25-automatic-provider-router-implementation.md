# Automatic Provider Router Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every `claude-yolo` conversation automatically use MiniMax, then sfkey GLM, then DeepSeek while keeping all provider credentials in macOS Keychain.

**Architecture:** A dependency-free Node.js loopback daemon transparently proxies Anthropic-compatible requests and performs bounded pre-response failover. A Python control program manages Keychain credentials, daemon lifecycle, public configuration, cooldown state, and atomic migration of legacy Claude settings. The existing shell launcher delegates provider subcommands and launches Claude Code through the router only after activation.

**Tech Stack:** Node.js standard `http`/`https` modules, Python 3 standard library, POSIX shell, macOS `security`, existing shell integration tests.

---

## File Map

- Create `.claude/skills/pm-orchestrator/scripts/pm-provider-router.js`: loopback Anthropic request proxy, retry/fallback policy, streaming safety, state events.
- Create `.claude/skills/pm-orchestrator/scripts/pm-provider.py`: provider CLI, Keychain adapter, daemon lifecycle, setup/migration, status and overrides.
- Create `.claude/templates/provider-router-config.json`: public profile order, endpoints, model IDs, retry and cooldown defaults.
- Modify `.claude/skills/pm-orchestrator/scripts/launch-claude.sh`: launch Claude through `pm-provider.py exec` when routing is active.
- Modify `.claude/skills/pm-orchestrator/scripts/claude-yolo`: route `provider` subcommands before normal Hub path selection.
- Modify `.claude/skills/pm-orchestrator/scripts/install-global.sh`: install the template and preserve executable modes.
- Create `install.sh`: portable root installer with Hub/bin options and dependency checks.
- Create `.claude/skills/pm-orchestrator/scripts/pm-doctor.py`: sanitized installation and runtime diagnostics.
- Modify `.claude/skills/pm-orchestrator/scripts/pm-feature.sh`: obtain the resolved Hub from `pm-hub.sh`.
- Modify `.claude/skills/pm-orchestrator/scripts/pm-team-event.py`: obtain the resolved Hub from `pm-hub.sh`.
- Modify `.claude/commands/idea.md`: remove external-disk assumptions.
- Modify `.claude/skills/pm-orchestrator/scripts/pm-session-start.py`: append bounded provider status facts.
- Modify `.claude/skills/pm-orchestrator/SKILL.md`: define provider routing and operational boundaries.
- Modify `README.md` and `.claude/skills/pm-orchestrator/README.md`: document setup and daily commands.
- Create `tests/helpers/mock-anthropic-server.js`: deterministic local upstream supporting JSON and SSE scenarios.
- Create `tests/test-provider-control.sh`: Keychain abstraction, migration, status, activation, and no-secret tests.
- Create `tests/test-provider-router.sh`: priority, fallback, cooldown, streaming, concurrency, and bounded error tests.
- Modify `tests/test-launch-claude.sh`, `tests/test-claude-yolo.sh`, `tests/test-global-install.sh`, and `tests/test-session-start.sh`: integration contracts.
- Create `tests/test-portable-install.sh`: arbitrary-checkout, clean-home, doctor, update, and no-hardcoded-path contracts.

### Task 1: Public Configuration And Keychain Boundary

**Files:**
- Create: `.claude/templates/provider-router-config.json`
- Create: `.claude/skills/pm-orchestrator/scripts/pm-provider.py`
- Create: `tests/test-provider-control.sh`

- [ ] **Step 1: Write the failing configuration and fake-Keychain test**

The test creates isolated `HOME`, `PM_PROVIDER_HOME`, and `PM_PROVIDER_KEYCHAIN_DIR` directories. It runs:

```bash
provider set minimax < "$MINIMAX_SECRET_FILE"
provider set glm < "$GLM_SECRET_FILE"
provider set deepseek < "$DEEPSEEK_SECRET_FILE"
provider status --json
```

Assert that status contains:

```json
{
  "active": false,
  "mode": "auto",
  "providers": {
    "minimax": {"configured": true},
    "glm": {"configured": true},
    "deepseek": {"configured": true}
  }
}
```

Also assert that no command output, public config, state file, or log contains any test secret.

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
sh tests/test-provider-control.sh
```

Expected: `FAIL: pm-provider.py is missing`.

- [ ] **Step 3: Add the public profile template**

Create exact profile IDs and defaults:

```json
{
  "version": 1,
  "listen": {"host": "127.0.0.1", "port": 41937},
  "providers": [
    {
      "id": "minimax",
      "base_url": "https://api.minimaxi.com/anthropic",
      "model": "MiniMax-M3",
      "auth_scheme": "bearer"
    },
    {
      "id": "glm",
      "base_url": "https://api.sfkey.cn",
      "model": "glm-5.2",
      "auth_scheme": "bearer"
    },
    {
      "id": "deepseek",
      "base_url": "https://api.deepseek.com/anthropic",
      "model": "deepseek-v4-pro",
      "auth_scheme": "bearer"
    }
  ],
  "retry": {"network": 2, "server": 2},
  "cooldown_seconds": {
    "network": 300,
    "auth": 21600,
    "quota": 86400,
    "rate_limit": 1800,
    "server": 300,
    "stream": 300
  }
}
```

- [ ] **Step 4: Implement the control program's storage interfaces**

Implement these exact commands:

```text
pm-provider.py set minimax|glm|deepseek
pm-provider.py remove minimax|glm|deepseek
pm-provider.py status [--json]
pm-provider.py use auto|minimax|glm|deepseek
pm-provider.py reset [provider]
```

Use:

```python
SERVICE = "claude-pm-provider-router"
VALID_PROVIDERS = ("minimax", "glm", "deepseek")
```

Production writes and reads secrets with `security add-generic-password -U`, `security find-generic-password -w`, and `security delete-generic-password`. Tests use `PM_PROVIDER_KEYCHAIN_DIR`; files in that directory must be mode `0600`. `set` reads from a TTY with `getpass.getpass()` or from stdin for tests, strips one trailing newline, rejects empty values, and never prints the value.

Public configuration and state live below `PM_PROVIDER_HOME`, defaulting to `~/.claude/provider-router`. Write JSON through a same-directory temporary file, `fsync`, mode `0600`, and `os.replace`.

- [ ] **Step 5: Run the test and verify GREEN**

Run:

```bash
sh tests/test-provider-control.sh
```

Expected: `PASS: provider control and Keychain boundary`.

- [ ] **Step 6: Commit**

```bash
git add .claude/templates/provider-router-config.json \
  .claude/skills/pm-orchestrator/scripts/pm-provider.py \
  tests/test-provider-control.sh
git commit -m "feat: add provider profile control"
```

### Task 2: Router Priority And Pre-Response Fallback

**Files:**
- Create: `.claude/skills/pm-orchestrator/scripts/pm-provider-router.js`
- Create: `tests/helpers/mock-anthropic-server.js`
- Create: `tests/test-provider-router.sh`

- [ ] **Step 1: Write failing mock-upstream scenarios**

The helper accepts a port and scenario file. For each request it records only model, path, and selected safe headers. It supports:

```json
{"status": 200, "body": {"type": "message", "content": [{"type": "text", "text": "ok"}]}}
{"status": 402, "body": {"error": {"type": "quota_error", "message": "plan exhausted"}}}
{"status": 429, "headers": {"retry-after": "2"}, "body": {"error": {"type": "rate_limit_error"}}}
{"status": 500, "body": {"error": {"type": "api_error"}}}
{"status": 400, "body": {"error": {"message": "model_context_window_exceeded"}}}
```

Start three mock servers and the router with a temporary config ordered `minimax`, `glm`, `deepseek`. Send an Anthropic request to the router and assert:

- all healthy: only MiniMax receives `MiniMax-M3`;
- MiniMax 402: GLM receives `glm-5.2`;
- MiniMax and GLM 402: DeepSeek receives `deepseek-v4-pro`;
- MiniMax context-window 400: GLM receives nothing;
- all unavailable: one bounded final error lists attempted provider IDs.

- [ ] **Step 2: Run the router test and verify RED**

Run:

```bash
sh tests/test-provider-router.sh
```

Expected: `FAIL: pm-provider-router.js is missing`.

- [ ] **Step 3: Implement request parsing and provider selection**

Implement a `RouterState` object with:

```javascript
{
  mode: "auto",
  cooldowns: {},
  currentProvider: null,
  lastTransition: null
}
```

For each inbound request:

1. Reject non-loopback clients.
2. Compare `Authorization: Bearer <router-local>` using `crypto.timingSafeEqual`.
3. Buffer the request body with a configurable hard limit of 32 MiB.
4. Parse JSON only for `/v1/messages` and token-count paths.
5. Build candidates from manual mode or configured auto order.
6. Skip missing credentials and active cooldowns.
7. Clone the JSON body and replace only `model`.
8. Join the base URL path and inbound path without dropping `/anthropic`, then preserve the inbound query string.

The daemon loads provider credentials directly from Keychain at startup. In tests, `PM_PROVIDER_KEYCHAIN_DIR` selects the mode-`0600` file adapter. `set` and `remove` restart an active owned daemon so stale credentials cannot remain in memory. Provider credentials are never passed through process arguments or environment variables.

- [ ] **Step 4: Implement bounded retry and error classification**

Use these categories:

```javascript
function classify(status, bodyText) {
  if (status === 401) return "auth";
  if (status === 402) return "quota";
  if (status === 403) return "auth";
  if (status === 429) return "rate_limit";
  if (status >= 500) return "server";
  if (status >= 400 && /context_window|model_context_window_exceeded/i.test(bodyText)) {
    return "context";
  }
  return "request";
}
```

Retry network and server failures up to the public config limit. Retry delay is bounded to 250 ms then 750 ms in tests; production may use the same values. Fallback only for network, auth, quota, rate-limit, and server categories. Buffer at most 64 KiB of an error body.

- [ ] **Step 5: Persist safe state and transitions**

State writes contain provider ID, category, HTTP status, cooldown deadline, timestamp, and bounded upstream request ID. Never write request body, response body, authentication headers, or arbitrary upstream messages.

- [ ] **Step 6: Run tests and verify GREEN**

Run:

```bash
sh tests/test-provider-router.sh
```

Expected: `PASS: provider priority and fallback`.

- [ ] **Step 7: Commit**

```bash
git add .claude/skills/pm-orchestrator/scripts/pm-provider-router.js \
  tests/helpers/mock-anthropic-server.js tests/test-provider-router.sh
git commit -m "feat: add automatic provider fallback router"
```

### Task 3: Streaming Safety And Concurrency

**Files:**
- Modify: `.claude/skills/pm-orchestrator/scripts/pm-provider-router.js`
- Modify: `tests/helpers/mock-anthropic-server.js`
- Modify: `tests/test-provider-router.sh`

- [ ] **Step 1: Add failing SSE and partial-stream tests**

Add mock scenarios:

```json
{"status": 200, "stream": ["event: message_start\\ndata: {}\\n\\n", "event: message_stop\\ndata: {}\\n\\n"]}
{"status": 200, "stream": ["event: message_start\\ndata: {}\\n\\n"], "abort_after_chunk": 1}
```

Assert:

- a complete stream is byte-identical;
- after the first upstream byte, an abort does not send the request to GLM;
- the next independent request skips the temporarily unhealthy provider;
- twelve concurrent requests complete without corrupting atomic state JSON;
- prompts and test secrets do not appear in state or logs.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
PM_ROUTER_TEST_FILTER=stream sh tests/test-provider-router.sh
```

Expected: failure showing partial streams are not tracked safely.

- [ ] **Step 3: Implement commit-on-first-byte streaming**

Do not send downstream status or headers until the upstream status is known. For 2xx responses:

```javascript
let committed = false;
upstream.on("data", (chunk) => {
  if (!committed) {
    committed = true;
    sendSafeHeaders(downstream, upstream);
  }
  downstream.write(chunk);
});
```

If the stream errors after `committed`, mark the provider with category `stream`, end or destroy the downstream response, and do not call the fallback loop. If it errors before commitment, classify it as network failure and allow fallback.

- [ ] **Step 4: Serialize state writes**

Queue state mutations in-process and write with temporary file plus atomic rename. Each request uses an immutable provider snapshot, while cooldown changes affect later requests.

- [ ] **Step 5: Run tests and verify GREEN**

Run:

```bash
sh tests/test-provider-router.sh
```

Expected: `PASS: provider priority, fallback, streaming, and concurrency`.

- [ ] **Step 6: Commit**

```bash
git add .claude/skills/pm-orchestrator/scripts/pm-provider-router.js \
  tests/helpers/mock-anthropic-server.js tests/test-provider-router.sh
git commit -m "fix: prevent replay after streamed responses"
```

### Task 4: Daemon Lifecycle And Provider Commands

**Files:**
- Modify: `.claude/skills/pm-orchestrator/scripts/pm-provider.py`
- Modify: `tests/test-provider-control.sh`

- [ ] **Step 1: Add failing lifecycle tests**

Test:

```text
ensure -> starts exactly one daemon
ensure -> reuses healthy daemon
status -> reports daemon PID and current provider
use glm -> router reloads state without restart
reset minimax -> clears only MiniMax cooldown
stop -> terminates the owned daemon
```

Use a temporary port and fake Keychain. Assert PID/state files contain no secrets.

- [ ] **Step 2: Run and verify RED**

Run:

```bash
sh tests/test-provider-control.sh
```

Expected: `FAIL: provider ensure is unsupported`.

- [ ] **Step 3: Implement lifecycle commands**

Add:

```text
pm-provider.py ensure
pm-provider.py stop
pm-provider.py exec <command> [args...]
```

`ensure` creates `router-local` with `secrets.token_urlsafe(32)` when absent, starts Node with `start_new_session=True`, redirects daemon stdout/stderr to a bounded operational log, and polls `GET /_pm/health` for at most five seconds. PID and lock handling must reject unrelated live processes.

The daemon receives only `PM_PROVIDER_HOME`, the public config path, and the optional test Keychain directory in its environment. In production it retrieves `router-local` and provider credentials itself with `/usr/bin/security`.

`exec` calls `ensure`, then uses `os.execvpe` with:

```python
env["ANTHROPIC_BASE_URL"] = f"http://127.0.0.1:{port}"
env["ANTHROPIC_AUTH_TOKEN"] = local_token
env["ANTHROPIC_MODEL"] = "pm-auto"
env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = "pm-auto"
env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = "pm-auto"
env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = "pm-auto"
```

Do not place the local token in command arguments or files outside Keychain.

- [ ] **Step 4: Implement local control endpoints**

The router supports authenticated loopback endpoints:

```text
GET  /_pm/health
GET  /_pm/status
POST /_pm/mode
POST /_pm/reset
```

Control bodies contain provider IDs only and are capped at 8 KiB.

- [ ] **Step 5: Run tests and verify GREEN**

Run:

```bash
sh tests/test-provider-control.sh
```

Expected: `PASS: provider control, Keychain, and daemon lifecycle`.

- [ ] **Step 6: Commit**

```bash
git add .claude/skills/pm-orchestrator/scripts/pm-provider.py \
  .claude/skills/pm-orchestrator/scripts/pm-provider-router.js \
  tests/test-provider-control.sh
git commit -m "feat: manage provider router lifecycle"
```

### Task 5: Atomic Legacy Settings Migration

**Files:**
- Modify: `.claude/skills/pm-orchestrator/scripts/pm-provider.py`
- Modify: `tests/test-provider-control.sh`
- Modify: `tests/test-session-start.sh`

- [ ] **Step 1: Add failing migration tests**

Create a settings fixture containing DeepSeek coding fields, Agent Teams, hooks, permissions, and OpenRouter vision fields. Run:

```bash
PM_CLAUDE_SETTINGS="$SETTINGS" provider setup --non-interactive
```

Assert:

- legacy DeepSeek token was written to fake Keychain before removal;
- coding provider fields were removed;
- hooks, permissions, Agent Teams, concurrency, and OpenRouter fields are unchanged;
- running setup twice produces identical files;
- missing MiniMax or GLM credentials aborts activation without changing settings;
- no backup or output contains credentials.

- [ ] **Step 2: Run and verify RED**

Run:

```bash
sh tests/test-provider-control.sh
```

Expected: `FAIL: provider setup is unsupported`.

- [ ] **Step 3: Implement setup and activation transaction**

Interactive `setup`:

1. hidden-prompt for a fresh MiniMax credential;
2. hidden-prompt for a fresh sfkey GLM credential;
3. detect the existing DeepSeek bearer credential;
4. write and read back each Keychain item;
5. generate `router-local`;
6. atomically remove only the listed coding-provider fields;
7. write `active: true`;
8. start the daemon and print sanitized status.

`--non-interactive` requires all three fake/real Keychain entries to exist and migrates only the legacy settings fields.

On any failure before step 7, preserve the original settings and inactive state. Never create a plaintext settings backup.

- [ ] **Step 4: Ensure the general Claude configurator remains model-neutral**

`configure-claude-user.py` must continue managing hooks, permissions, Agent Teams, and default concurrency without reintroducing or deleting provider fields. Provider migration remains owned solely by `pm-provider.py setup`.

- [ ] **Step 5: Run tests and verify GREEN**

Run:

```bash
sh tests/test-provider-control.sh
sh tests/test-session-start.sh
```

Expected: both pass.

- [ ] **Step 6: Commit**

```bash
git add .claude/skills/pm-orchestrator/scripts/pm-provider.py \
  tests/test-provider-control.sh tests/test-session-start.sh
git commit -m "feat: migrate provider credentials to Keychain"
```

### Task 6: Claude YOLO And Cold-Start Integration

**Files:**
- Modify: `.claude/skills/pm-orchestrator/scripts/launch-claude.sh`
- Modify: `.claude/skills/pm-orchestrator/scripts/claude-yolo`
- Modify: `.claude/skills/pm-orchestrator/scripts/pm-session-start.py`
- Modify: `tests/test-launch-claude.sh`
- Modify: `tests/test-claude-yolo.sh`
- Modify: `tests/test-session-start.sh`

- [ ] **Step 1: Add failing launcher tests**

Assert:

```text
claude-yolo provider status -> invokes pm-provider.py status without opening Claude
claude-yolo provider setup -> invokes pm-provider.py setup
inactive routing -> preserves legacy launcher behavior
active routing -> launch-claude.sh uses pm-provider.py exec claude
board -> launches Agent View through pm-provider.py exec
SessionStart -> includes mode/current provider but no credentials or raw errors
```

- [ ] **Step 2: Run and verify RED**

Run:

```bash
sh tests/test-launch-claude.sh
sh tests/test-claude-yolo.sh
sh tests/test-session-start.sh
```

Expected: provider subcommands or routed launch assertions fail.

- [ ] **Step 3: Route provider commands**

In `claude-yolo`, process `provider` immediately after installation/config synchronization:

```sh
if [ "${1:-}" = provider ]; then
  shift
  exec python3 "$SCRIPT_DIR/pm-provider.py" "$@"
fi
```

Run `board` through the provider executor when active so background sessions inherit the same local endpoint. `respawn` remains a Claude supervisor command; restarted sessions receive current launch configuration through Agent View.

- [ ] **Step 4: Update the model-neutral launcher**

When provider routing is active:

```sh
exec python3 "$SCRIPT_DIR/pm-provider.py" exec \
  claude --permission-mode bypassPermissions "$@"
```

When inactive, preserve the existing direct `exec claude` path so setup failures do not lock the user out.

- [ ] **Step 5: Add bounded provider facts to cold start**

Call:

```text
pm-provider.py status --json
```

with a two-second timeout. Add only mode, current provider, and cooldown provider IDs to `additionalContext`. Unknown directories and subagents keep their existing behavior.

- [ ] **Step 6: Run tests and verify GREEN**

Run the three focused tests and expect all to pass.

- [ ] **Step 7: Commit**

```bash
git add .claude/skills/pm-orchestrator/scripts/launch-claude.sh \
  .claude/skills/pm-orchestrator/scripts/claude-yolo \
  .claude/skills/pm-orchestrator/scripts/pm-session-start.py \
  tests/test-launch-claude.sh tests/test-claude-yolo.sh tests/test-session-start.sh
git commit -m "feat: route Claude YOLO through provider fallback"
```

### Task 7: Installation, Documentation, And Full Verification

**Files:**
- Create: `install.sh`
- Create: `.claude/skills/pm-orchestrator/scripts/pm-doctor.py`
- Modify: `.claude/skills/pm-orchestrator/scripts/install-global.sh`
- Modify: `.claude/skills/pm-orchestrator/scripts/pm-hub.sh`
- Modify: `.claude/skills/pm-orchestrator/scripts/pm-feature.sh`
- Modify: `.claude/skills/pm-orchestrator/scripts/pm-team-event.py`
- Modify: `.claude/commands/idea.md`
- Modify: `.claude/skills/pm-orchestrator/SKILL.md`
- Modify: `.claude/skills/pm-orchestrator/README.md`
- Modify: `README.md`
- Modify: `tests/test-global-install.sh`
- Create: `tests/test-portable-install.sh`

- [ ] **Step 1: Add failing global-install assertions**

Copy the repository to a temporary path that contains spaces and does not contain `/Volumes/SanDisk2TB`. With isolated `HOME`, run:

```bash
./install.sh --hub "$HOME/custom-hub" --bin-dir "$HOME/.local/bin"
"$HOME/.local/bin/claude-yolo" doctor --json
```

Verify installation includes:

```text
pm-provider.py
pm-provider-router.js
provider-router-config.json
```

Also assert:

- the executable resolves to the installed runtime under `~/.claude`, not the source checkout;
- deleting the temporary source copy does not break `claude-yolo doctor`;
- user config records the selected Hub with `~` expansion handled safely;
- no installed file contains the test checkout path, `/Volumes/SanDisk2TB`, or `/Users/peter_mini`;
- installation does not modify real settings, Keychain, or credentials.

- [ ] **Step 2: Run and verify RED**

Run:

```bash
sh tests/test-global-install.sh
sh tests/test-portable-install.sh
```

Expected: missing portable root installer or doctor.

- [ ] **Step 3: Update installer and documentation**

Create root `install.sh` with exact options:

```text
--hub <path>
--bin-dir <path>
--source-checkout <path>
```

It copies the runtime, commands, agents, templates, and Skill into `~/.claude`; writes `~/.claude/pm-orchestrator/config.json` atomically; and creates `claude-yolo` in the selected bin directory pointing only to the installed copy. It prints a concrete `export PATH=...` line when the selected bin is absent from PATH, but does not silently edit shell profiles.

Change `pm-hub.sh` to resolve its Hub from `PM_HUB_HOME`, then user config, then `~/.claude/pm-hub`. Existing users preserve the external-disk Hub through the user config written during upgrade. `pm-feature.sh` and `pm-team-event.py` must call `pm-hub.sh init` to obtain that canonical resolved path instead of carrying their own defaults. Remove external-disk assumptions from the Skill, commands, current READMEs, and every installed script; historical design documents remain historical and are not installed.

Implement:

```text
claude-yolo doctor [--json]
claude-yolo update
```

`doctor` performs read-only checks and redacts all credential values. `update` reads `source_checkout`, requires a clean Git worktree, runs `git pull --ff-only`, and reruns `install.sh` with the recorded Hub and bin directory. It fails with an actionable message when GitHub authentication, source checkout, PATH, or dependencies are missing.

Document:

```bash
gh auth login
gh repo clone peterhuang-coding/claude-code-pm-orchestrator \
  "$HOME/claude-code-pm-orchestrator"
cd "$HOME/claude-code-pm-orchestrator"
./install.sh
claude-yolo doctor
claude-yolo provider setup
claude-yolo provider status
claude-yolo provider use <provider>
claude-yolo provider auto
claude-yolo provider reset
claude-yolo
```

State clearly that setup requires freshly rotated MiniMax and sfkey credentials, DeepSeek is metered fallback, automatic fallback never replays a started stream, `/imageinput` remains separate, and a checkout can live anywhere.

- [ ] **Step 4: Run all automated verification**

Run every `tests/test-*.sh` in parallel-safe isolated sandboxes, then:

```bash
for f in .claude/skills/pm-orchestrator/scripts/*.sh \
  .claude/skills/pm-orchestrator/scripts/claude-yolo \
  .claude/skills/pm-orchestrator/scripts/claude-pm; do
  sh -n "$f"
done

PYTHONPYCACHEPREFIX=/tmp/pm-provider-pycache \
  python3 -m py_compile \
  .claude/skills/pm-orchestrator/scripts/pm-provider.py \
  .claude/skills/pm-orchestrator/scripts/pm-session-start.py \
  .claude/skills/pm-orchestrator/scripts/configure-claude-user.py

node --check .claude/skills/pm-orchestrator/scripts/pm-provider-router.js
git diff --check
```

Expected: all tests and syntax checks pass.

- [ ] **Step 5: Run security review**

Search repository, test output, temporary router home, daemon logs, Hub, and sanitized settings for the three test credentials. Confirm:

- daemon binds only `127.0.0.1`;
- control endpoints require the local token;
- request/response bodies are not logged;
- state and config are mode `0600`;
- no key appears in process arguments;
- no automatic replay occurs after streamed bytes.

- [ ] **Step 6: Request independent code review and fix findings**

The reviewer must prioritize credential exposure, fallback loops, duplicate tool execution, settings migration rollback, process ownership, concurrency, and unbounded buffers.

- [ ] **Step 7: Commit**

```bash
git add .claude README.md tests
git commit -m "docs: document automatic provider routing"
```

### Task 8: Real Installation And Opt-In Smoke Test

**Files:**
- Runtime only: `~/.claude`, macOS Keychain, `~/.claude/provider-router`
- Modify after validation only: PM Hub wrap-up

- [ ] **Step 1: Install the tested package globally**

Run:

```bash
./.claude/skills/pm-orchestrator/scripts/install-global.sh
```

Confirm global files match the committed source.

- [ ] **Step 2: Require credential rotation before setup**

Do not import the MiniMax credential exposed in chat. Ask the user to revoke it, create a fresh MiniMax key, and have the current sfkey credential available. Then run:

```bash
claude-yolo provider setup
```

The terminal prompts for MiniMax and sfkey without echo. The existing DeepSeek credential is migrated locally.

- [ ] **Step 3: Verify sanitized configuration**

Print only field names and booleans. Confirm no coding-provider base URL, model, or credential remains in `~/.claude/settings.json`; OpenRouter vision, hooks, permissions, Agent Teams, and concurrency remain.

- [ ] **Step 4: Run opt-in minimal provider smoke tests**

With explicit user approval to consume plan/API tokens, send a minimal `max_tokens: 1` request through each forced provider, then restore auto mode:

```bash
claude-yolo provider use minimax
claude-yolo provider use glm
claude-yolo provider use deepseek
claude-yolo provider auto
```

Do not simulate exhaustion against real accounts. Validate fallback using mocks only.

- [ ] **Step 5: Verify a real Claude cold start**

Run a no-persistence one-shot Claude request through the router and confirm `/status`-equivalent sanitized metadata identifies the localhost endpoint while `provider status` identifies MiniMax as current.

- [ ] **Step 6: Merge, push, and wrap up**

Fast-forward `main`, rerun the full test suite on merged state, push GitHub, and write a PM Hub summary containing commit, verification, active profile order, operational limits, and the single next action.
