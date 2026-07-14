# Global PM Orchestrator Installation Design

## Goal

Install the PM orchestrator once and use it from any sibling Git repository without copying `.claude` into every project.

## Design

- Keep `/Volumes/SanDisk2TB/claude-code-pm-orchestrator` as the canonical source repository.
- Install commands, agents, templates, and the skill into `~/.claude` with `install-global.sh`.
- Never read, rewrite, or replace `~/.claude/settings.json` or credentials.
- Resolve the handoff tool in this order: project-local copy, launcher-provided `PM_HANDOFF_TOOL`, then the user-global copy.
- The launcher exports absolute `PM_HANDOFF_TOOL` and `PM_CLAUDE_LAUNCHER` paths so sessions launched from either the canonical or global location remain stable.
- Runtime handoffs stay under each target repository's Git common directory. Repositories remain isolated while worktrees for one repository share task state.

## Compatibility

Existing project-local installations continue to win. Global installation adds reuse across projects and does not require changing project repositories.
