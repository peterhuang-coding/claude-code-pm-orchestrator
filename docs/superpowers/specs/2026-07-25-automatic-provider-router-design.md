# Automatic Claude Code Provider Router

## Goal

Make `claude-yolo` the single entrypoint for all Claude Code conversations while automatically using providers in this fixed order:

1. MiniMax Token Plan
2. sfkey relay with GLM
3. DeepSeek metered API

The router must work for the lead session, subagents, Agent Teams, background sessions, and resumed project work without placing credentials in Git, Skills, the PM Hub, shell history, or Claude Code transcripts.

## Non-Goals

- Routing `/imageinput`; OpenRouter vision remains independent.
- Balancing traffic for speed or quality while a higher-priority provider is healthy.
- Replaying a response after streamed bytes or a tool call have reached Claude Code.
- Treating context-window or malformed-request errors as provider exhaustion.
- Guaranteeing identical behavior after switching between different model families.

## Provider Profiles

Profiles contain public routing metadata only:

| Priority | ID | Base URL | Model |
| --- | --- | --- | --- |
| 1 | `minimax` | `https://api.minimaxi.com/anthropic` | `MiniMax-M2.7` |
| 2 | `glm` | `https://api.sfkey.cn` | `glm-5.2` |
| 3 | `deepseek` | `https://api.deepseek.com/anthropic` | `deepseek-v4-pro` |

The MiniMax China endpoint is the default because this installation is used in China. The public metadata can be changed without changing the routing engine.

Credentials live in macOS Keychain under service `claude-pm-provider-router` and accounts `minimax`, `glm`, and `deepseek`. A fourth random `router-local` credential authenticates Claude Code to the loopback daemon and remains stable across daemon restarts. The exposed MiniMax key from chat must be revoked and is never imported. The existing DeepSeek credential may be migrated locally from `~/.claude/settings.json` only after the Keychain write succeeds.

## Architecture

```text
claude-yolo
    |
    +-- ensure global Skills and hooks
    +-- ensure provider router daemon
    +-- export one localhost base URL and Keychain-backed local token
    |
Claude Code + Agent Teams
    |
    v
127.0.0.1 provider router
    |
    +-- MiniMax
    +-- sfkey / GLM
    +-- DeepSeek
```

The router is a small Node.js service using only standard library HTTP/HTTPS modules. It binds exclusively to `127.0.0.1`, validates the stable random `router-local` bearer token, and transparently proxies the Anthropic-compatible request and streaming response. The local token is passed through the launched process environment, never command-line arguments. The router rewrites only the request `model` for the selected provider and the upstream authentication header. Anthropic version, beta headers, tools, system prompts, messages, metadata, and streaming fields are preserved.

One daemon serves concurrent local Claude Code sessions. A lock and PID file prevent duplicate daemons. Runtime files use mode `0600`; no prompt or response body is logged.

## Configuration Separation

`~/.claude/settings.json` retains model-neutral settings such as hooks, permissions, Agent Teams, concurrency, and OpenRouter vision configuration. The migration removes global coding-provider fields that would override routing:

- `ANTHROPIC_AUTH_TOKEN`
- `ANTHROPIC_API_KEY`
- `ANTHROPIC_BASE_URL`
- `ANTHROPIC_MODEL`
- `ANTHROPIC_DEFAULT_HAIKU_MODEL`
- `ANTHROPIC_DEFAULT_SONNET_MODEL`
- `ANTHROPIC_DEFAULT_OPUS_MODEL`
- `CLAUDE_MODEL`
- DeepSeek-specific custom model labels

`claude-yolo` supplies the localhost endpoint and virtual model only to the process it launches. Plain `claude` remains model-neutral and does not silently receive a paid credential.

## Routing State

The router starts in `auto` mode. It selects the first configured provider that is not cooling down. A successful request makes that provider the current healthy provider. Provider state contains only:

- provider ID
- health and cooldown deadline
- last status category
- last transition timestamp
- bounded error code and request ID, when available

State is written atomically under `~/.claude/provider-router/`. Conversation text, file content, headers, and credentials are never recorded.

Manual modes are temporary overrides:

```bash
claude-yolo provider use minimax
claude-yolo provider use glm
claude-yolo provider use deepseek
claude-yolo provider auto
claude-yolo provider reset
claude-yolo provider status
```

`status` reports configured/missing credentials, current provider, cooldowns, and the most recent transition without revealing secret values.

## Failure Policy

The router may fall back only before a successful response begins.

| Failure | Behavior |
| --- | --- |
| DNS, connection, TLS, or timeout | Retry the same provider twice with bounded backoff, then cool down for 5 minutes and fall back |
| HTTP 401 | Mark credential invalid, fall back, and surface the credential problem in status |
| HTTP 402 | Treat as plan/quota exhaustion, cool down for 24 hours, and fall back |
| HTTP 403 | Treat as access/plan exhaustion, cool down for 6 hours, and fall back |
| HTTP 429 | Honor bounded `Retry-After` when present; otherwise cool down for 30 minutes, then fall back |
| HTTP 500-599 | Retry twice, cool down for 5 minutes, then fall back |
| Context window exceeded | Return unchanged; Claude Code must compact or reduce context |
| Other HTTP 400-499 | Return unchanged; do not hide invalid requests or tool-schema problems |

If all providers are unavailable, return the final structured upstream error plus a bounded router summary naming attempted providers. Never loop indefinitely.

## Streaming And Tool Safety

For a non-2xx upstream response, the router buffers only a bounded error body before deciding whether to fall back. For a 2xx response, headers and bytes are streamed immediately.

After any response byte has been sent to Claude Code:

- do not replay the request;
- do not switch providers for that request;
- if the stream breaks, mark the provider temporarily unhealthy;
- allow the next user turn or retry to use the next provider.

This prevents duplicate file edits, shell commands, commits, purchases, or external actions caused by replaying a partially completed tool-use response.

## Credential Workflow

Keys are entered through a hidden terminal prompt:

```bash
claude-yolo provider set minimax
claude-yolo provider set glm
claude-yolo provider set deepseek
```

The command writes directly to Keychain, verifies that a value can be retrieved, and never prints the value. Removing a credential requires an explicit provider ID:

```bash
claude-yolo provider remove <provider>
```

Configuration and migration are idempotent. Existing credentials are not deleted until their Keychain copy is verified. Backups must not contain plaintext credentials.

## Cold Start And Handoffs

The existing PM Hub, `/feature`, `/today`, and `/wrap-up` remain the durable work state. Provider switching does not create a new Feature or modify project Git state.

SessionStart adds a bounded factual line naming router mode and current provider. Provider transitions are recorded as operational metadata, so a later cold start can explain why the model changed without restoring old chat.

## Testing

Automated tests use three local mock Anthropic-compatible servers and fake Keychain commands. They cover:

- priority order and manual override;
- quota, authentication, rate-limit, timeout, and 5xx fallback;
- no fallback for context-window and other 4xx errors;
- cooldown and reset behavior;
- concurrent Agent Team requests;
- streamed success pass-through;
- no replay after partial streaming;
- model rewriting and header preservation;
- bounded logs with no secrets or prompt bodies;
- atomic state/config writes;
- `settings.json` migration without changing hooks, permissions, Agent Teams, or OpenRouter;
- `claude-yolo provider` commands and normal cold start.

Real-provider smoke tests are opt-in and send only a minimal prompt. They must never run during the normal test suite or spend metered API credits unexpectedly.

## Acceptance Criteria

1. `claude-yolo` prefers MiniMax when all three credentials are configured.
2. A simulated MiniMax quota error switches the same unstarted request to GLM.
3. A simulated GLM quota error switches to DeepSeek without user confirmation.
4. Context-window errors do not switch providers.
5. Partial streamed responses are never replayed.
6. Lead, subagent, Agent Team, and background Claude Code sessions use the localhost router.
7. No provider key appears in settings, process arguments, logs, Hub files, repository files, or test output.
8. Status and override commands work without restarting the router manually.
9. Existing PM Orchestrator tests remain green.

## Operational Limits

- Different models can produce different reasoning quality and tool behavior after a switch.
- A provider can return an ambiguous 403; the user can immediately reset or force another provider.
- Machine sleep or shutdown stops the local daemon and background agents; the next `claude-yolo` launch restarts the daemon.
- The router protects against automatic replay, but the user should still review production, payment, credential, deletion, and irreversible Git actions.
