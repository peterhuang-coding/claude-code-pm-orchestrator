# Agent Team Feature Tracking Design

## Goal

Turn Claude YOLO into a true daily operating system for a user who tracks several products for roughly one hour on four days per week: every session starts with current project facts, every feature has durable progress, background work is visible in native Agent View, and complex work uses Agent Teams without depending on their temporary state for recovery.

## Operating Model

```text
Portfolio Hub
  -> native Agent View: all background project PM sessions
      -> one project PM session per feature
          -> optional Agent Team for coordinated parallel work
              -> optional worktrees for parallel code edits
```

Agent View is the cross-project control surface. Agent Teams are an execution mechanism inside one feature. The Hub feature ledger and Git are the durable source of truth.

## True Cold Start

A user-level `SessionStart` command hook runs for normal sessions, background sessions, subagents, teammates, clear, and compact. It classifies `cwd`, loads a bounded Hub/Git/handoff summary, sets a useful session title, asks Claude to reload globally synchronized Skills, and adds the cold-start facts as context before the first prompt.

`claude-yolo` still supplies an initial instruction for interactive sessions: immediately show a concise dashboard and then wait for the user's decision. The hook makes the same context available even when Claude is opened through `claude agents`, a background dispatch, or plain `claude`.

## Feature Ledger

Each registered project stores features under:

```text
claude-pm-hub/projects/<project-id>/features/<feature-id>/
  feature.md
  status
  created-at
  updated-at
  updates/
```

Valid states are `backlog`, `ready`, `running`, `needs-input`, `review`, `blocked`, `paused`, and `done`. Writes are atomic, bounded, and reject secret-like content. Feature IDs include a timestamp, slug, and process suffix.

The ledger supports:

- create a feature from a bounded brief;
- list and read project features;
- update status with a verified progress note;
- show a project or portfolio dashboard ordered with `needs-input`, `review`, and `blocked` first.

## User Commands

- `/today`: one-screen portfolio or project dashboard showing features that need the user's attention, currently running work, recent completions, and no more than three recommended decisions.
- `/feature <request>`: create and execute a feature. The invocation itself authorizes routine implementation. Small work stays in one session; complex collaborative work explicitly creates an Agent Team; independent long work may dispatch a background project PM session.
- `/feature status [id]`, `/feature pause [id]`, `/feature done [id]`: inspect or transition durable feature state.
- Existing `/do` delegates feature-sized work to `/feature` so users do not need to remember both systems.

## Native Agent View

`claude-yolo board` synchronizes the external-disk package and opens:

```text
claude agents --permission-mode bypassPermissions
```

The user's current model Profile is preserved. Agent View provides the global machine-level list of background sessions. `claude-yolo respawn` restarts stopped background sessions after sleep by invoking `claude respawn --all`.

## Agent Team Policy

Agent Teams remain enabled globally. Default display is `in-process` because neither tmux nor iTerm2 is installed. A complex feature uses at most five predictable roles: `product`, `tech`, `dev`, `test`, and `review`.

- Use a Team when workers need a shared task list or direct communication.
- Use subagents for focused side work whose result can be summarized.
- Use Agent View for independent features or projects.
- Use worktrees whenever multiple workers edit code in parallel.
- Do not create nested teams.
- Team lead must update the feature ledger at start, after each major milestone, on needs-input/block, and before cleanup.

## Hooks and Configuration

An idempotent configurator preserves credentials and model settings while synchronizing:

- `permissions.defaultMode = bypassPermissions`;
- `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = 1`;
- `teammateMode = in-process`;
- `CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY = 12`;
- the PM `SessionStart` hook.

Team runtime events are recorded through `TeammateIdle` and `TaskCompleted` hooks using only bounded non-secret metadata. Event logs are diagnostic; they do not replace explicit feature updates.

## Daily Workflow

1. Run `claude-yolo board` and inspect only `Needs input` and `Ready for review`.
2. Attach to a session, decide or review, then detach.
3. Run `claude-yolo hub` and `/today` for the portfolio summary.
4. Start no more than three important features with `/feature`.
5. Leave background project PM sessions running; use `caffeinate` for overnight work and `claude-yolo respawn` after machine sleep.

## Safety

Routine repository work, reversible worktrees, Agent Teams, tests, commits, and Hub updates proceed without confirmation. Production deployment, payment, external authorization, secret changes, destructive deletion, and irreversible Git history changes still require the user.
