# Goal-Gated Unattended PM Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `/goal` approval gate and a deadline-bounded unattended loop that only runs approved product goals.

**Architecture:** `pm-goal.sh` stores Goal metadata beside the existing repository-scoped PM handoff, with explicit states and atomic transitions. `pm-loop.sh` validates an approved Goal, creates an isolated `pm-loop/<task-slug>` branch, launches one fresh print-mode Claude session per round through the existing GLM launcher, bounds the next prompt to handoff summaries, and stops on completion, deadline, safety failure, or repeated failures. Markdown commands and the main skill document describe the product-research approval phase; shell tests protect state transitions and loop safety.

**Tech Stack:** POSIX `sh`, Git, existing `pm-handoff.sh`, existing `launch-claude-glm.sh`, Claude Code print mode, Markdown command/skill files.

---

### Task 1: Define and implement the Goal state machine

**Files:**
- Create: `.claude/skills/pm-orchestrator/scripts/pm-goal.sh`
- Create: `tests/test-pm-goal.sh`

- [ ] Write `tests/test-pm-goal.sh` first. In a temporary Git repo, create a Goal from stdin and assert `discovery`; write a non-empty brief and assert `awaiting-approval`; assert approval without a note fails; approve with a note and assert `approved`; assert a second approval fails; stop it and assert `stopped`. Also assert empty briefs, unknown IDs, secret-looking content, and invalid transitions fail without changing state.
- [ ] Run `sh tests/test-pm-goal.sh` and verify it fails because `pm-goal.sh` is absent.
- [ ] Implement `pm-goal.sh` with commands `new <slug>`, `brief <id>`, `approve <id>`, `status [id]`, `read [id]`, `stop <id>`, and `path [id]`. Reuse `pm-handoff.sh` so Goal ID and Task ID are identical; store `goal.md` beside `leader.md`; write atomically; cap content; reject secrets; record `approved_at`, `approved_by=user`, and the approval note.
- [ ] Run `sh tests/test-pm-goal.sh`; expected output is `PASS: PM goal state machine`.
- [ ] Commit with `git add .claude/skills/pm-orchestrator/scripts/pm-goal.sh tests/test-pm-goal.sh && git commit -m "feat: add approved goal state machine"`.

### Task 2: Define and implement the unattended supervisor

**Files:**
- Create: `.claude/skills/pm-orchestrator/scripts/pm-loop.sh`
- Create: `tests/test-pm-loop.sh`

- [ ] Write `tests/test-pm-loop.sh` first. Use a temporary repo and fake launcher; assert a past `--until` exits zero without invoking Claude, an unapproved Goal refuses to run, a dirty worktree refuses without `--allow-dirty`, an existing lock refuses, and `--max-rounds 1` stops after one fake round.
- [ ] Run `sh tests/test-pm-loop.sh` and verify it fails because `pm-loop.sh` is absent.
- [ ] Implement option parsing for required `--until`, optional `--goal-id`, `--max-rounds`, `--sleep-seconds`, and `--allow-dirty`; resolve tools from project-local, launcher environment, then `$HOME/.claude`; validate local or offset ISO deadlines.
- [ ] Require an approved Goal brief, refuse unsafe dirty worktrees by default, create `pm-loop/<goal-slug>` from the current branch, refuse an existing branch, create a Git-common lock, and release it with traps. Never run reset, clean, checkout, deployment, or deletion commands.
- [ ] For each round, launch `launch-claude-glm.sh --print --no-session-persistence` with only bounded Goal brief, status, handoff, last result, deadline, and budget. Save full output to a per-round log; pass only a bounded summary forward. Require `CONTINUE`, `DONE`, or `BLOCKED` and update leader handoff after every round.
- [ ] Stop on deadline or `DONE`; stop non-zero on `BLOCKED`, safety failure, lock contention, invalid state, or three consecutive code-validation failures; retry transport failures with bounded backoff; never mark the PM task complete automatically.
- [ ] Run `sh tests/test-pm-loop.sh`; expected output is `PASS: unattended PM loop safety`.
- [ ] Commit with `git add .claude/skills/pm-orchestrator/scripts/pm-loop.sh tests/test-pm-loop.sh && git commit -m "feat: add approved-goal unattended loop"`.

### Task 3: Add `/goal` commands and update the Skill contract

**Files:**
- Create: `.claude/commands/goal.md`
- Modify: `.claude/commands/leader-task.md`
- Modify: `.claude/commands/leader-resume.md`
- Modify: `.claude/skills/pm-orchestrator/SKILL.md`
- Modify: `.claude/skills/pm-orchestrator/README.md`
- Modify: `tests/test-skill-handoff-contract.sh`

- [ ] Add `/goal <request>`: create Goal, research public official pages, demos, app stores, public repos and licenses, produce bounded `goal-brief.md`, and stop at `awaiting-approval`; prohibit business-code edits, worktrees, and loop start in this phase.
- [ ] Add `/goal approve <Goal-ID>`, `/goal status <Goal-ID>`, `/goal read <Goal-ID>`, and `/goal stop <Goal-ID>`; only explicit approval unlocks execution.
- [ ] Update `SKILL.md`, leader commands, and README so every product goal requires a recommended benchmark, evidence links, scope, non-goals, acceptance criteria, and approval before implementation. Public research may borrow behavior and interaction patterns but may not copy private code, assets, branding, or restricted material.
- [ ] Require `/leader-resume` to read Goal state before continuing and document that `pm-loop.sh` uses fresh sessions as automatic compaction.
- [ ] Extend `tests/test-skill-handoff-contract.sh` for `/goal`, `approved`, public research, `pm-goal.sh`, and `pm-loop.sh`; run it and expect `PASS: PM skill handoff contract`.
- [ ] Commit with `git add .claude/commands/goal.md .claude/commands/leader-task.md .claude/commands/leader-resume.md .claude/skills/pm-orchestrator/SKILL.md .claude/skills/pm-orchestrator/README.md tests/test-skill-handoff-contract.sh && git commit -m "feat: gate automation behind approved goals"`.

### Task 4: Verify, install, and publish

**Files:**
- Modify: `.claude/skills/pm-orchestrator/scripts/install-global.sh` only if its existing recursive copy does not include the new scripts
- Test: all files under `tests/`

- [ ] Run `sh tests/test-global-install.sh`, `sh tests/test-launch-claude-glm.sh`, `sh tests/test-pm-handoff.sh`, `sh tests/test-pm-goal.sh`, `sh tests/test-pm-loop.sh`, `sh tests/test-skill-handoff-contract.sh`, `git diff --check`, and `sh -n .claude/skills/pm-orchestrator/scripts/*.sh tests/*.sh`; all must exit 0.
- [ ] Push the verified commits, fast-forward `/Volumes/SanDisk2TB/claude-code-pm-orchestrator`, and run `/Volumes/SanDisk2TB/claude-code-pm-orchestrator/.claude/skills/pm-orchestrator/scripts/install-global.sh`; preserve `~/.claude/settings.json` and credentials.
- [ ] From a sibling project, verify the global scripts use that repository's handoff root; verify an unapproved Goal refuses the loop and an approved Goal with a past deadline exits cleanly without invoking Claude.
- [ ] Record the final commit, tests, installed paths, Goal ID workflow, and overnight command in the handoff. Do not mark the user Goal complete; only make the loop ready for the first run.
