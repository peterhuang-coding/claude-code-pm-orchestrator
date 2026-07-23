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
```

`claude-yolo` runs from the source package on `/Volumes/SanDisk2TB`, synchronizes all PM Skills and commands before every launch, and then starts the model-neutral `claude-pm` entrypoint. With no path, a registered current project is used; an unknown directory falls back to the central Hub. The entrypoint preserves the model, provider, authentication, effort, concurrency, and subagent routing from the current Claude Code configuration while adding `bypassPermissions` and a bounded cold-start summary.

Use `/project-register` once in a new project. For normal work, run `/do <your request>`; it routes the task, verifies the result, and writes `/wrap-up` state to `/Volumes/SanDisk2TB/claude-pm-hub`. Run `/portfolio` from the Hub to report across projects, and `/idea <text>` to capture work without starting it.

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
