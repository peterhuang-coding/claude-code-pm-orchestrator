# Claude Code PM Orchestrator

Reusable Claude Code commands, Agents, worktree routing, and persistent PM handoffs for multi-project development.

## Install Into A Project

From the target project root:

```bash
rsync -a --exclude '*.bak.*' /path/to/this-repo/.claude/ .claude/
chmod +x .claude/skills/pm-orchestrator/scripts/*.sh
```

## Start Claude Code

```bash
./.claude/skills/pm-orchestrator/scripts/launch-claude-glm.sh
```

Then run `/leader-task <your request>`. To recover without resuming an oversized chat, start a new Claude Code session in the original project/worktree and run `/leader-resume` or `/leader-resume <Task ID>`.

Runtime handoffs are stored under each repository's Git common directory, so different projects are isolated while linked worktrees share the same task state.

Do not commit API keys or tokens. Configure the relay credential locally in Claude Code settings or the shell environment.
