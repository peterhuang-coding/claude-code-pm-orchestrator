# Personal R&D Hub Design

## Goal

Provide one model-neutral Claude Code entrypoint for several projects, with automatic cold start, durable project memory, one-command autonomous execution, reliable wrap-up, and a portfolio view that lets one lead report on and assign work across all registered projects.

## Architecture

The PM Orchestrator remains the versioned software package. Runtime knowledge lives separately under `/Volumes/SanDisk2TB/claude-pm-hub`, and credentials remain in Claude Code settings, environment variables, or the system keychain.

The neutral `launch-claude.sh` is the low-level launcher. `claude-pm` is the user entrypoint: it resolves an optional project path, confirms the global package is installed, generates a bounded cold-start prompt, and starts Claude Code with `bypassPermissions`. It does not set or clear model, provider, authentication, effort, or concurrency variables.

## Hub Layout

```text
/Volumes/SanDisk2TB/claude-pm-hub/
  README.md
  config/
    projects.tsv
    active-profile
  portfolio/
    ideas.md
    feishu-backlog.md
  projects/
    <project-id>/
      project.md
      latest.md
      ideas.md
      assignments.md
      sessions/
```

`projects.tsv` is the machine-readable registry. Project records are bounded Markdown intended for both people and agents. Session records are append-only; `latest.md` is replaced atomically.

## Commands

- `/do <request>` is the normal work entrypoint. It cold-starts first, infers a bounded goal and acceptance criteria, chooses the smallest effective execution mode, runs verification, and calls the wrap-up flow before reporting completion.
- `/wrap-up [note]` reconciles Git and PM handoffs, writes a concise session record, updates `latest.md`, captures new ideas, and preserves exactly one next action.
- `/portfolio` reads only registered project summaries, ideas, assignments, and current Git state, then reports the portfolio and may write project assignments.
- `/idea <text>` records an idea in the current project or the portfolio inbox.
- Existing `/goal`, `/leader-task`, `/leader-resume`, and PM scripts remain available as lower-level recovery and specialist controls.

## Cold Start

The launcher classifies the working directory:

1. Registered project: read that project's `latest.md`, assignments, newest PM handoff metadata, and bounded Git status.
2. Hub root: read all registered projects' bounded summaries and portfolio inboxes.
3. Unknown directory: report that it is unregistered and offer `/project-register`; do not write automatically.

Cold start starts a fresh interactive Claude session with a generated prompt. It never resumes an old conversation or imports full transcripts.

## Autonomy Policy

Routine repository work proceeds without user confirmation: analysis, project-local edits, tests, commits, reversible worktrees, subagents, Agent Teams, handoffs, and Hub updates.

Stop for the user only when an action involves production deployment, payment, external account authorization, secret creation or rotation, destructive data deletion, irreversible Git history changes, or genuinely ambiguous product direction with materially different outcomes.

## Execution Routing

- Single agent: small or sequential tasks.
- Subagents: independent research, review, or context-heavy side work whose summary is sufficient.
- Agent Teams: complex tasks whose workers need a shared task list or direct communication.
- Worktrees: parallel code edits requiring filesystem isolation.
- Agent view: independent project sessions that the user wants to monitor from one screen.

Agent Teams are runtime coordination only. Hub records and Git remain the durable source of truth because team resumption and cleanup are not reliable enough for long-term memory.

## Model Profiles

The package contains no provider-specific model. The active model remains controlled by Claude Code settings or the shell. The Hub records only a non-secret active profile label and display metadata. Future provider changes update local Claude settings and credentials, not the launcher or Skill.

## Feishu

The initial release records Feishu assistant setup as a portfolio backlog with the required discovery tasks: choose app ownership, enumerate requested scopes, decide tenant visibility, create the app, obtain user authorization, and add a purpose-built MCP connector. No external permission is claimed until the user completes the provider approval flow.

## Verification

Shell integration tests cover model/environment preservation, permission arguments, global installation cleanup, project registration, directory classification, bounded cold-start output, atomic wrap-up, idea capture, multi-project isolation, and secret rejection. A stub `claude` executable verifies startup without consuming API quota.
