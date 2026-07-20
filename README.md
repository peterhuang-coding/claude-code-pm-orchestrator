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
cd /path/to/any-project
$HOME/.claude/skills/pm-orchestrator/scripts/launch-claude-deepseek.sh
```

Then run `/leader-task <your request>`. To recover without resuming an oversized chat, start a new Claude Code session in the original project/worktree and run `/leader-resume`, `/leader-resume <Task ID>`, or `/leader-resume path/to/legacy-handoff.md`.

For image understanding, use `/imageinput /path/to/image.png Analyze this page`. Set `OPENROUTER_API_KEY` locally; the main coding model remains DeepSeek and only the image helper uses OpenRouter.

For new products, feature goals, benchmark-driven work, or unattended R&D, start with `/goal <request>`. It researches public benchmark products, writes a bounded goal brief, and waits for `/goal approve <Goal-ID>`. Only approved Goals can run the unattended loop:

```bash
$HOME/.claude/skills/pm-orchestrator/scripts/pm-loop.sh \
  --goal-id <Goal-ID> \
  --until "2026-07-18T08:00"
```

Runtime handoffs are stored under each repository's Git common directory, so different projects are isolated while linked worktrees share the same task state.

Do not commit API keys or tokens. Configure the relay credential locally in Claude Code settings or the shell environment.
