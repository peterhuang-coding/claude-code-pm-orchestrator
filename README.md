# Claude Code PM Orchestrator

Reusable Claude Code commands, Agents, worktree routing, and persistent PM handoffs for multi-project development.

## Install Once For Every Project

From this repository:

```bash
./.claude/skills/pm-orchestrator/scripts/install-global.sh
```

This installs only the PM orchestrator commands, agents, templates, and skill into `~/.claude`. It does not modify `~/.claude/settings.json` or credentials. A project-local copy remains supported and takes precedence.

Install or repair the MiniMax Ultra capability layer:

```bash
claude-yolo capabilities install
claude-yolo capabilities status
```

The installer selects the China endpoint and `MiniMax-M3`, installs the official
`mmx-cli` Skill for text, image, video, speech, music, vision, and search, and
enables the official `minimax-skills` Claude Code plugin. Normal
`claude-yolo` startup performs only a local status check and never installs
remote packages implicitly. Provider routing reads the MiniMax credential from
macOS Keychain service `claude-pm-provider-router`, account `minimax`.
The official `mmx-cli` requires its own non-interactive authentication and saves
that credential in `~/.mmx/config.json` with mode `0600`; credentials are never
stored in this repository.

## Start Claude Code

```bash
claude-yolo
claude-yolo /path/to/any-project
claude-yolo hub
claude-yolo boss
claude-yolo board
claude-yolo respawn
```

`claude-yolo` runs from the source package on `/Volumes/SanDisk2TB`, synchronizes all PM Skills and commands before every launch, and then starts the model-neutral `claude-pm` entrypoint. With no path, a registered current project is used; an unknown directory falls back to the central Hub. The entrypoint preserves the model, provider, authentication, effort, concurrency, and subagent routing from the current Claude Code configuration while adding `bypassPermissions` and a bounded cold-start summary.

Use `/project-register` once in a new project. `claude-yolo` installs a model-neutral `SessionStart` hook, so every registered project starts with its bounded Hub state even when Claude Code is opened another way.

For a quick task, run `/do <request>`. For work that spans a session or needs progress tracking, run `/feature <request>`; Feature status and evidence persist under `/Volumes/SanDisk2TB/claude-pm-hub`. Run `/today` for a one-screen portfolio review, and `claude-yolo board` for Claude Code's live Agent View across projects. `claude-yolo respawn` restarts stopped background sessions after a machine restart.

Agent Teams are enabled but created only inside complex Features. They inherit the lead session's model and permissions, use at most five members, and require separate git worktrees for parallel edits. The package never hardcodes an API provider or model.

Lower-level `/goal`, `/leader-task`, and `/leader-resume` commands remain available for specialist control and recovery.

## Feishu Away Mode

The Feishu gateway uses one boss Claude conversation rooted at
`/Volumes/SanDisk2TB`. Project sessions, teammates, and subagents do not send
messages to Feishu directly.

Install and authorize the official Feishu/Lark CLI once. Grant only the `im`
scopes needed for messages and group chat management:

```bash
npx @larksuite/cli@latest install
```

Create or choose one private group named `Claude PM 总控`, add the CLI bot, then
bind it automatically:

```bash
claude-feishu configure
```

The command discovers the group and stores only its non-secret `oc_` chat ID in
the PM Hub runtime directory. OAuth credentials remain in the Lark CLI's native
macOS credential store. A legacy custom-bot webhook remains supported as a
fallback when Lark CLI is unavailable.

Then use two terminals:

```bash
# Terminal 1: the only Feishu-facing boss conversation
cd /Volumes/SanDisk2TB
claude-yolo boss
```

```bash
# Terminal 2: visible gateway console
claude-feishu
```

Starting `claude-feishu` turns synchronization on and immediately sends a
Gateway-online message to Feishu. It also starts a WebSocket listener for
commands sent by the configured owner in `Claude PM 总控`. Text and post
messages are acknowledged, executed serially by one persistent remote Claude
boss session rooted at `/Volumes/SanDisk2TB`, and answered as replies to the
source message. The remote session inherits the current Claude provider and
model, uses maximum effort and `bypassPermissions`, and remains independent of
the visible local terminal. The console accepts:

```text
cloud on
cloud off
cloud status
cloud test
cloud logs
cloud quit
```

The same controls are available as `claude-feishu on`, `off`, `status`, `test`,
and `logs`. In the boss conversation, `我现在外出了` turns synchronization on;
`我回来了`, `我没外出`, or `没外出` turns it off. The current release is outbound
and inbound: completed local boss replies, failures, and attention notifications
are copied to Feishu, while owner-authored Feishu messages drive the dedicated
remote boss session. `cloud off` ignores new inbound commands, pauses queued
work, and cancels the active remote command; `cloud on` resumes with a fresh
command lifecycle. Messages from bots, other users, or other chats are
never executed. Only one gateway console can run at a time. Pending outbound
messages expire after 24 hours; outbound delivery is at-least-once. Durable
inbound message IDs and an atomic running state provide at-most-once command
execution. If the gateway stops during a command, that command is marked
uncertain and is not automatically retried, avoiding repeated high-permission
side effects. A completed command whose Feishu reply failed keeps its result and
retries only the reply. `claude-feishu status` reports `Duplex ready` only while
the event WebSocket is live; configured but disconnected gateways report
`Duplex offline`.

For image understanding, use `/imageinput /path/to/image.png Analyze this page`. Set `OPENROUTER_API_KEY` locally; the current coding model remains unchanged and only the image helper uses OpenRouter.

For new products, feature goals, benchmark-driven work, or unattended R&D, start with `/goal <request>`. It researches public benchmark products, writes a bounded goal brief, and waits for `/goal approve <Goal-ID>`. Only approved Goals can run the unattended loop:

```bash
$HOME/.claude/skills/pm-orchestrator/scripts/pm-loop.sh \
  --goal-id <Goal-ID> \
  --until "2026-07-18T08:00"
```

Runtime handoffs are stored under each repository's Git common directory, so different projects are isolated while linked worktrees share the same task state.

Do not commit API keys or tokens. Configure the relay credential locally in Claude Code settings or the shell environment.
