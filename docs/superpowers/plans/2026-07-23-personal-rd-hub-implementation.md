# Personal R&D Hub Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a model-neutral Claude Code launcher and central multi-project knowledge hub with cold start, autonomous work, wrap-up, and portfolio commands.

**Architecture:** Keep executable workflows in the existing global PM Orchestrator package and store runtime knowledge in a separate Hub. A POSIX shell Hub tool owns registry and file operations; Markdown commands tell Claude how to reconcile semantic summaries with Git and handoffs.

**Tech Stack:** POSIX shell, Git, Markdown Claude Code commands and Skills, shell integration tests.

---

### Task 1: Neutral Launcher

**Files:**
- Delete: `.claude/skills/pm-orchestrator/scripts/launch-claude-deepseek.sh`
- Create: `.claude/skills/pm-orchestrator/scripts/launch-claude.sh`
- Create: `.claude/skills/pm-orchestrator/scripts/claude-pm`
- Replace: `tests/test-launch-claude-deepseek.sh` with `tests/test-launch-claude.sh`

- [ ] Write a launcher test that seeds every provider/model variable and expects exact preservation.
- [ ] Run `sh tests/test-launch-claude.sh` and verify failure because the neutral launcher does not exist.
- [ ] Implement `launch-claude.sh` with only PM path exports and `--permission-mode bypassPermissions`.
- [ ] Add `claude-pm` path resolution and cold-start prompt invocation.
- [ ] Run the launcher test and verify PASS.

### Task 2: Hub Storage

**Files:**
- Create: `.claude/skills/pm-orchestrator/scripts/pm-hub.sh`
- Create: `tests/test-pm-hub.sh`

- [ ] Write failing tests for `init`, `register`, `classify`, `cold-start`, `wrap-up`, `idea`, and `portfolio`.
- [ ] Verify the tests fail because `pm-hub.sh` is absent.
- [ ] Implement safe project IDs, TSV registry, atomic bounded Markdown writes, and secret rejection.
- [ ] Run `sh tests/test-pm-hub.sh` and verify PASS.

### Task 3: Claude Commands and Skill Policy

**Files:**
- Create: `.claude/commands/do.md`
- Create: `.claude/commands/wrap-up.md`
- Create: `.claude/commands/portfolio.md`
- Create: `.claude/commands/idea.md`
- Create: `.claude/commands/project-register.md`
- Modify: `.claude/skills/pm-orchestrator/SKILL.md`
- Modify: `.claude/templates/final-summary.md`
- Modify: `tests/test-skill-handoff-contract.sh`

- [ ] Add failing contract assertions for the commands, autonomy boundary, routing policy, and required wrap-up.
- [ ] Verify the contract test fails.
- [ ] Add concise command workflows and update the PM Skill to use `/do` as the preferred entrypoint.
- [ ] Run the contract test and verify PASS.

### Task 4: Global Installation and Documentation

**Files:**
- Modify: `.claude/skills/pm-orchestrator/scripts/install-global.sh`
- Modify: `tests/test-global-install.sh`
- Modify: `README.md`
- Modify: `.claude/commands/pm-worktrees.md`
- Modify: `.claude/templates/worktree-plan.md`

- [ ] Add failing installation assertions for the neutral entrypoint, all Hub commands, and removal of both legacy launchers.
- [ ] Verify the global installation test fails.
- [ ] Update installation, examples, and worktree launch paths.
- [ ] Run the installation and contract tests and verify PASS.

### Task 5: Initialize Personal Hub

**Files outside repository:**
- Create: `/Volumes/SanDisk2TB/claude-pm-hub/`
- Update: user-global `~/.claude/`

- [ ] Install the package globally without modifying credentials or model settings.
- [ ] Initialize the Hub and register discovered product repositories.
- [ ] Add Feishu setup to `portfolio/feishu-backlog.md`.
- [ ] Add a non-secret active profile label matching the current local configuration.

### Task 6: Full Verification and Delivery

- [ ] Run all `tests/test-*.sh`, shell syntax checks, and `git diff --check`.
- [ ] Use a stub Claude executable to verify cold-start prompt and permission mode.
- [ ] Confirm the repository is free of keys and tokens.
- [ ] Commit implementation changes and push `main`.
