# Claude Code PM Orchestrator

Reusable Claude Code commands, Agents, worktree routing, and persistent PM handoffs for multi-project development.

## Install Once For Every Project

From this repository:

```bash
./.claude/skills/pm-orchestrator/scripts/install-global.sh
```

This installs only the PM orchestrator commands, agents, templates, and skill into `~/.claude`. It does not modify `~/.claude/settings.json` or credentials. A project-local copy remains supported and takes precedence.

## Start Claude Code

```bash
claude-yolo
claude-yolo /path/to/any-project
claude-yolo hub
claude-yolo board
claude-yolo respawn
```

`claude-yolo` runs from the source package on `/Volumes/SanDisk2TB`, synchronizes all PM Skills and commands before every launch, and then starts the model-neutral `claude-pm` entrypoint. With no path, a registered current project is used; an unknown directory falls back to the central Hub. The entrypoint preserves the model, provider, authentication, effort, concurrency, and subagent routing from the current Claude Code configuration while adding `bypassPermissions` and a bounded cold-start summary.

Use `/project-register` once in a new project. `claude-yolo` installs a model-neutral `SessionStart` hook, so every registered project starts with its bounded Hub state even when Claude Code is opened another way.

For a quick task, run `/do <request>`. For work that spans a session or needs progress tracking, run `/feature <request>`; Feature status and evidence persist under `/Volumes/SanDisk2TB/claude-pm-hub`. Run `/today` for a one-screen portfolio review, and `claude-yolo board` for Claude Code's live Agent View across projects. `claude-yolo respawn` restarts stopped background sessions after a machine restart.

Agent Teams are enabled but created only inside complex Features. They inherit the lead session's model and permissions, use at most five members, and require separate git worktrees for parallel edits. The package never hardcodes an API provider or model.

Lower-level `/goal`, `/leader-task`, and `/leader-resume` commands remain available for specialist control and recovery.

For image understanding, use `/imageinput /path/to/image.png Analyze this page`. Set `OPENROUTER_API_KEY` locally; the current coding model remains unchanged and only the image helper uses OpenRouter.

For new products, feature goals, benchmark-driven work, or unattended R&D, start with `/goal <request>`. It researches public benchmark products, writes a bounded goal brief, and waits for `/goal approve <Goal-ID>`. Only approved Goals can run the unattended loop:

```bash
$HOME/.claude/skills/pm-orchestrator/scripts/pm-loop.sh \
  --goal-id <Goal-ID> \
  --until "2026-07-18T08:00"
```

Runtime handoffs are stored under each repository's Git common directory, so different projects are isolated while linked worktrees share the same task state.

Do not commit API keys or tokens. Configure the relay credential locally in Claude Code settings or the shell environment.
