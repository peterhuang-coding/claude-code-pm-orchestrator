# Claude Feishu Duplex Gateway Design

## Goal

Turn the existing outbound-only `claude-feishu` gateway into an always-on,
bidirectional control channel. A message sent by the authorized owner in the
private `Claude PM 总控` chat starts or resumes one dedicated Claude Code boss
session, and the result is replied to the originating Feishu message.

## Chosen Architecture

The gateway owns a dedicated remote Claude session instead of injecting
keystrokes into an interactive terminal. This keeps the Feishu control plane
working when no local Claude UI is open and avoids coupling execution to tmux,
terminal focus, or transient prompt state.

The existing outbound hook path remains unchanged:

`Claude hooks -> durable outbound queue -> Lark CLI -> Feishu`

The new inbound path is:

`Feishu WebSocket event -> filter/dedupe -> durable inbound queue -> Claude -p
session -> reply to source message`

## Components

### Channel Configuration

`channel.json` stores non-secret routing metadata:

- target chat ID
- authorized owner open ID
- remote boss root, defaulting to `/Volumes/SanDisk2TB`
- transport name

OAuth tokens remain owned by the official Lark CLI credential store. No token,
app secret, or API key is written to the repository or PM Hub.

### Event Listener

The gateway starts:

`lark-cli event consume im.message.receive_v1 --as bot`

It waits for the official `[event] ready` marker, consumes NDJSON from stdout,
and terminates the consumer gracefully on gateway shutdown.

An event is accepted only when all conditions hold:

- `chat_id` equals the configured private PM chat
- `sender_type` is `user`
- `sender_id` equals the configured owner
- `message_type` is text or post and rendered content is non-empty
- `message_id` is absent from pending, processed, and failed ledgers

Bot messages, other chats, other users, empty content, and duplicate deliveries
are ignored.

### Durable Inbound Queue

Accepted events are atomically written under:

`<PM_HUB_HOME>/runtime/feishu/inbound/{pending,processed,failed}`

One worker processes pending commands serially. A successful Claude result and
Feishu reply moves the record to `processed`. A bounded failure moves it to
`failed` and sends a concise failure reply. This prevents concurrent writes to
one Claude session and makes restarts recover queued commands.

### Remote Claude Session

The first command creates a UUID-backed session with:

- working directory `/Volumes/SanDisk2TB`
- `--print`
- `--permission-mode bypassPermissions`
- `--effort max`
- no hard-coded provider or model

Later commands use `--resume <session_id>`. Session metadata is persisted in
`remote-session.json`. The prompt identifies the message as an authorized
Feishu boss command, asks Claude to use the installed PM orchestrator and Hub,
and preserves the user's text verbatim.

The remote process does not set `PM_FEISHU_BOSS`, so its Stop hook cannot
enqueue a duplicate outbound notification. Its result is replied directly to
the source Feishu message.

## User Experience

The user runs:

```bash
claude-feishu
```

The console reports outbound and inbound readiness. Sending a command in
`Claude PM 总控` produces:

1. a short acknowledgement reply;
2. serialized Claude execution;
3. the final result or a bounded error reply.

`cloud off` stops both outbound delivery and inbound command execution.
`cloud on` resumes both. Existing `status`, `test`, `logs`, and `quit`
commands remain compatible.

## Safety

- Exact chat and owner allowlists are mandatory.
- Incoming bot messages are never executed.
- Message IDs are durable idempotency keys.
- Commands are serialized.
- No model, provider, or credentials are hard-coded.
- The listener is stopped with stdin close or SIGTERM, never SIGKILL.
- Claude output and errors are length-bounded before being sent to Feishu.

## Verification

- Unit tests cover filtering, deduplication, queue transitions, command
  construction, session resume, and failure handling.
- Shell integration tests use fake Lark CLI and fake Claude binaries.
- Existing outbound webhook and Lark CLI tests remain green.
- A real Feishu test sends one harmless command and verifies an acknowledgement
  and final reply appear in the configured chat.
