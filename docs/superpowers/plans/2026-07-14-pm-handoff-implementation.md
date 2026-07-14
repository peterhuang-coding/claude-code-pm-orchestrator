# PM Orchestrator Persistent Handoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add durable, isolated, bounded handoffs to every PM LeaderTask and child Agent workflow.

**Architecture:** A POSIX shell tool stores runtime reports under each repository's Git common directory, shared by its worktrees and isolated by unique task ID. Commands and Agent definitions invoke the tool at mandatory checkpoints and reconstruct state from Git during recovery.

**Tech Stack:** Claude Code Markdown skills/commands/agents, POSIX shell, Git worktrees.

---

### Task 1: Define failing handoff integration tests

**Files:**
- Create: `tests/test-pm-handoff.sh`

- [x] Write tests for shared worktree storage, unique tasks, ambiguous recovery, bounded writes, secret rejection, and completion.
- [x] Run `sh tests/test-pm-handoff.sh` and verify it fails because `pm-handoff.sh` does not exist.

### Task 2: Implement the handoff storage tool

**Files:**
- Create: `.claude/skills/pm-orchestrator/scripts/pm-handoff.sh`

- [x] Implement `root`, `new`, `list`, `write`, `read`, `path`, and `complete` commands.
- [x] Validate identifiers and content before atomic rename.
- [x] Run `sh tests/test-pm-handoff.sh` and verify all integration checks pass.

### Task 3: Make LeaderTask checkpoints mandatory

**Files:**
- Modify: `.claude/skills/pm-orchestrator/SKILL.md`
- Modify: `.claude/commands/leader-task.md`
- Create: `.claude/commands/pm-handoff.md`
- Create: `.claude/templates/leader-handoff.md`

- [x] Add initialization, resume, checkpoint, final verification, multi-project isolation, and context-budget rules.
- [x] Add a manual recovery command and concise leader template.
- [x] Check that all required checkpoint phrases and commands are discoverable with `rg`.

### Task 4: Require child Agent handoffs

**Files:**
- Modify: `.claude/agents/*.md`
- Modify: `.claude/templates/child-agent-output.md`
- Modify: `.claude/templates/dev-handoff.md`

- [x] Permit only the Bash access needed for Git inspection and the handoff tool.
- [x] Require each role to write a bounded report before returning.
- [x] Verify every Agent definition references `pm-handoff.sh` and `TASK_ID`.

### Task 5: Harden worktree launch instructions

**Files:**
- Modify: `.claude/skills/pm-orchestrator/SKILL.md`
- Modify: `.claude/commands/pm-worktrees.md`
- Modify: `.claude/templates/worktree-plan.md`
- Create: `.claude/skills/pm-orchestrator/scripts/launch-claude-glm.sh`
- Create: `tests/test-launch-claude-glm.sh`

- [x] Write and run a failing launcher test with a stub `claude` executable.
- [x] Pin the relay URL, GLM-5.2 main/default/subagent models, and permission mode in interactive launch commands.
- [x] Explicitly exclude resume flags and interactive `--no-session-persistence`.
- [x] Run `sh tests/test-launch-claude-glm.sh` and verify it passes.
- [x] Verify no API key or token value is present.

### Task 6: Validate, synchronize, and publish

**Files:**
- Synchronize the updated `.claude` tree to `/Volumes/SanDisk2TB/skills` and `/Volumes/SanDisk2TB/amsterdam-brewery-unity`.

- [x] Run the integration test and static consistency checks.
- [x] Compare source and Unity copies with `diff -qr` for the managed PM files.
- [ ] Initialize or update the selected GitHub repository, commit the skill, and push.
- [ ] Report the GitHub URL and the exact interactive Claude Code launch command.
