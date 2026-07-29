# Claude Feishu Gateway Design

Date: 2026-07-29
Status: Proposed

## Goal

Provide a two-terminal workflow that connects one boss-level Claude Code
conversation to Feishu. The boss conversation is rooted at
`/Volumes/SanDisk2TB` and may coordinate work across multiple registered
projects. Project workers, subagents, and temporary Claude sessions do not send
messages to Feishu directly.

The first release is outbound only: when away mode is enabled, each completed
boss-session response is copied to Feishu. Inbound Feishu replies and remote
task control are deferred to a later release.

## User Experience

Terminal 1 runs the boss Claude Code conversation:

```bash
cd /Volumes/SanDisk2TB
claude-yolo boss
```

Terminal 2 runs the visible Feishu gateway:

```bash
claude-feishu
```

The gateway provides an interactive prompt:

```text
cloud on
cloud off
cloud status
cloud test
cloud logs
cloud quit
```

The same operations are available as one-shot commands:

```bash
claude-feishu on
claude-feishu off
claude-feishu status
claude-feishu test
```

The boss conversation also recognizes explicit phrases:

- `我现在外出了` enables Feishu synchronization.
- `我回来了` disables Feishu synchronization.
- `我没外出` disables Feishu synchronization.

The state is global and persistent. Commands in either terminal update the same
state. Starting the interactive `claude-feishu` console explicitly enables
synchronization and sends an immediate Gateway-online message, so restarting
the second terminal restores visible delivery without another command.

## Architecture

```text
Boss Claude Code session at /Volumes/SanDisk2TB
                    |
                    | Stop / StopFailure / Notification hooks
                    v
          Local Claude Feishu Gateway
          - boss session binding
          - project attribution
          - away-mode state
          - durable outbound queue
          - deduplication and logs
                    |
                    v
            One Feishu bot destination
```

The gateway is a local process with a visible interactive console. Hook scripts
remain short-lived clients: they validate each event, append it to the durable
queue, notify the gateway, and exit without blocking Claude Code.

Only one interactive gateway process may hold the delivery lock. Delivery is
at-least-once because Feishu custom-bot webhooks do not expose a remote
idempotency key: an ambiguous timeout after remote acceptance may produce a
duplicate, which is preferred to silently losing a boss reply.

## Boss Session Binding

Only one Claude Code session is the active Feishu-facing boss session.

`claude-yolo boss` launches Claude Code with `/Volumes/SanDisk2TB` as its current
working directory and registers the resulting session as the active boss. The
binding is stored by session ID and launch timestamp.

Events are forwarded only when all of the following are true:

1. Away mode is enabled.
2. The event session ID matches the active boss session.
3. The event is from the top-level conversation, not a subagent.
4. The event has not already been delivered.

Starting a new boss session replaces the previous active binding after recording
the old session as inactive. Regular `claude-yolo` sessions do not replace it.

## Project Attribution

The boss Claude session is rooted at the raw disk root, but cold start must not
scan the entire disk. Project awareness comes from an explicit registry stored
under the existing PM Hub.

Project attribution reads only the explicit PM Hub project registry. It matches
the event working directory or project names mentioned in the boss response;
when several or no projects match, the message is labeled as a Portfolio/Boss
summary. The first meaningful response line is used as the human-readable task
summary. Session IDs are included only as shortened diagnostic metadata. Active
feature and goal metadata are deferred until the boss session exposes an
explicit current-task identifier to hooks.

## Message Format

Each delivered message contains:

```text
[Project Name | Claude replied]
Summary: first meaningful response line
Session: short boss session ID
Time: local timestamp

Claude's final response
```

Long responses are truncated to a configured Feishu-safe limit. The complete
response remains available in the local event log and Claude transcript.

`StopFailure` and decision-required notifications use distinct headings so that
normal completion, errors, and blocked decisions are visually distinguishable.

## Switch Semantics

Away mode is stored independently from the gateway process:

- Starting bare `claude-feishu` persists `enabled=true` and sends an online
  confirmation.
- `cloud on` persists `enabled=true`.
- `cloud off` persists `enabled=false`.
- Restarting the gateway or Claude Code preserves the last setting.
- If the gateway is offline while enabled, events remain queued.
- Turning synchronization off prevents new deliveries but does not delete logs.
- Turning synchronization back on sends only events created while enabled,
  subject to a configurable backlog age limit.
- Pending events older than 24 hours are expired instead of being delivered.

Natural-language switching is implemented by a narrow `UserPromptSubmit` hook
that matches only the approved phrases. It does not use a model and does not
interpret arbitrary user text.

## Storage And Secrets

Runtime state lives under:

```text
/Volumes/SanDisk2TB/claude-pm-hub/runtime/feishu/
```

It contains:

- gateway state
- active boss-session binding
- append-only event log
- pending and delivered message records
- gateway health information

Feishu webhook URLs, application secrets, and signing secrets are stored in the
macOS Keychain. They must not be written into the Git repository, PM Hub Markdown
files, shell history, or Claude transcripts.

## Feishu Integration

The first release uses one Feishu custom-bot webhook because it is sufficient for
outbound synchronization and does not require a public callback server.

The gateway exposes a local CLI named `claude-feishu`; no unrelated third-party
"Feishu CLI" is required. Sending uses the documented Feishu webhook API with
timeouts, bounded retries, and response validation.

A later release may replace the custom bot with a Feishu application bot using
the official SDK long connection. That upgrade is required for replying in
Feishu and routing replies back into the active Claude session.

## Reliability And Safety

- Hook execution must never block or fail the Claude turn.
- Queue writes use atomic replacement or append-plus-lock semantics.
- Delivery uses stable event IDs for local deduplication and a single-process
  delivery lock.
- Retries use exponential backoff with a bounded maximum.
- Gateway logs redact webhook URLs, secrets, and message credentials.
- Only the registered boss session can send outbound messages.
- Subagent and teammate events remain local unless summarized by the boss.
- A message-size limit prevents oversized Feishu requests.
- `cloud test` sends a synthetic message without reading Claude transcripts.

## Validation

The implementation must verify:

1. `claude-feishu on`, `off`, `status`, and `test` work.
2. Interactive `cloud` commands update the same persistent state.
3. A repeated local boss `Stop` hook event is enqueued once while away mode is
   on; an ambiguous remote timeout may produce a duplicate delivery.
4. The same event is not sent while away mode is off.
5. Non-boss and subagent events are ignored.
6. Project and task labels are derived without scanning the disk root.
7. Gateway downtime queues events and restart resumes delivery.
8. Network and Feishu API failures do not interrupt Claude Code.
9. Secrets do not appear in Git diffs, logs, process arguments, or transcripts.

## Deferred Scope

The first release does not:

- accept Feishu replies into Claude Code
- start, pause, or reassign work from Feishu
- expose a web dashboard
- forward every project worker or subagent message
- automatically discover every directory on the external disk

These capabilities can build on the same gateway and event ledger after outbound
synchronization is stable.
