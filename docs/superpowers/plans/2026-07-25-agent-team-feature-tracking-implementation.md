# Agent Team Feature Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add true SessionStart cold start, durable feature tracking, native Agent View launch, and Agent Team configuration to Claude YOLO.

**Architecture:** POSIX shell owns atomic Hub feature state; a small Python hook safely translates Claude lifecycle JSON into bounded cold-start context and event logs. Markdown commands define routing and checkpoint behavior.

**Tech Stack:** POSIX shell, Python 3 standard library, Claude Code user hooks, Markdown Skills and commands, shell integration tests.

---

### Task 1: SessionStart Cold Start and Configurator

**Files:**
- Create: `.claude/skills/pm-orchestrator/scripts/pm-session-start.py`
- Create: `.claude/skills/pm-orchestrator/scripts/configure-claude-user.py`
- Create: `tests/test-session-start.sh`
- Modify: `.claude/skills/pm-orchestrator/scripts/claude-yolo`

- [ ] Write failing tests for bounded hook JSON, project and Hub titles, unknown-directory silence, idempotent settings merge, model preservation, and Skill reload.
- [ ] Implement the SessionStart hook and settings configurator.
- [ ] Invoke the configurator after each disk-source synchronization.
- [ ] Verify focused tests pass.

### Task 2: Durable Feature Ledger

**Files:**
- Create: `.claude/skills/pm-orchestrator/scripts/pm-feature.sh`
- Create: `tests/test-pm-feature.sh`

- [ ] Write failing tests for feature create, status transitions, read/list/dashboard, multi-project isolation, atomic updates, size limits, and secret rejection.
- [ ] Implement the minimal feature state machine.
- [ ] Verify focused tests pass.

### Task 3: User Commands and Team Routing

**Files:**
- Create: `.claude/commands/today.md`
- Create: `.claude/commands/feature.md`
- Modify: `.claude/commands/do.md`
- Modify: `.claude/skills/pm-orchestrator/SKILL.md`
- Modify: `tests/test-skill-handoff-contract.sh`

- [ ] Add failing contract assertions for dashboards, durable checkpoints, explicit Agent Team creation, predictable roles, worktree isolation, and no repeated routine approval.
- [ ] Implement the commands and Skill policy.
- [ ] Verify contract tests pass.

### Task 4: Agent View and Team Event Recording

**Files:**
- Create: `.claude/skills/pm-orchestrator/scripts/pm-team-event.py`
- Create: `tests/test-team-event.sh`
- Modify: `.claude/skills/pm-orchestrator/scripts/claude-yolo`
- Modify: `.claude/skills/pm-orchestrator/scripts/configure-claude-user.py`

- [ ] Write failing tests for `claude-yolo board`, `respawn`, and bounded team event logging.
- [ ] Implement native Agent View/respawn routing and hook synchronization.
- [ ] Verify focused tests pass.

### Task 5: Install, Documentation, and Delivery

**Files:**
- Modify: `.claude/skills/pm-orchestrator/scripts/install-global.sh`
- Modify: `tests/test-global-install.sh`
- Modify: `README.md`
- Modify: `.claude/skills/pm-orchestrator/README.md`

- [ ] Install scripts and commands globally without changing model credentials.
- [ ] Run all shell tests, Python compile checks, syntax checks, `git diff --check`, and secret scans.
- [ ] Run no-API smoke tests for cold start, Agent View arguments, settings merge, and feature dashboards.
- [ ] Request independent code review, fix findings, merge, push, and write the final Hub wrap-up.
