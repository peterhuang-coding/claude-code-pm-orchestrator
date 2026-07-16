# Unattended PM Loop Design

## Goal

Allow a project to run unattended optimization and test iterations until an explicit local-time deadline, while preserving enough state to resume safely the next day.

## Chosen approach

Use an external supervisor script that launches one fresh Claude Code print session per round. Each round reads the durable PM handoff and Git state, performs one bounded improvement cycle, validates it, commits only verified changes, and writes a compact handoff summary. The next round starts with a clean context, so automatic context compaction is achieved by session rotation rather than relying on a long interactive conversation.

The loop runs from the project repository and uses the existing GLM launcher. It does not depend on the current interactive Claude session remaining alive.

## Goal alignment gate

Unattended execution is never the first phase. The `/goal` command creates the shared Task ID and enters `discovery`. Product/Research/Tech agents may search public web sources, official product pages, public demos, app stores, public repositories, and licenses to find one recommended benchmark and up to two alternatives. They produce `goal-brief.md` with:

- target user and concrete outcome;
- recommended benchmark and evidence links;
- feature/interaction comparison and the proposed adaptation boundary;
- in-scope work, explicit non-goals, and acceptance criteria;
- technical constraints, risks, and validation plan.

The goal then enters `awaiting-approval` and the command stops. It must not create implementation worktrees, modify business code, start `pm-loop.sh`, or claim completion before explicit approval. The user approves with `/goal approve <Goal-ID>`, which records approver/time and transitions the goal to `approved`. Only an approved goal may start the loop. Approval is a product-direction gate, not an ordinary tool-permission prompt.

Goal states are `discovery`, `awaiting-approval`, `approved`, `executing`, `completed`, `blocked`, and `stopped`. `/goal status <Goal-ID>` reads the brief and state; `/goal stop <Goal-ID>` requests a graceful stop while preserving the final handoff.

## User interface

```bash
cd /Volumes/SanDisk2TB/<project>
$HOME/.claude/skills/pm-orchestrator/scripts/pm-loop.sh \
  --until "2026-07-17T08:00"
```

The deadline is interpreted in the machine's local timezone unless an explicit offset is provided. The script prints the Task ID, branch, round number, and handoff location without printing prompts, credentials, or full model logs.

Supported controls:

- `--until <ISO-8601 local or offset time>`: required stop deadline.
- `--max-rounds <positive integer>`: optional safety cap.
- `--sleep-seconds <positive integer>`: optional delay between rounds, default 10.
- `--allow-dirty`: explicit opt-in for starting with uncommitted changes; without it, the loop stops before changing a dirty worktree.

The loop requires an approved Goal ID, either passed explicitly or found in the current Task handoff. A missing brief or an `awaiting-approval` goal is a hard stop.

## State and isolation

- A new unique Task ID is created in the target repository's Git common handoff directory.
- Work is isolated on `pm-loop/<task-slug>` created from the current branch. The loop never commits directly to `main` or another starting branch.
- A lock under the Git common directory prevents two loops from mutating the same repository at once.
- Each round records a small `round-<n>.md` summary and updates the leader handoff. Full Claude output is redirected to a bounded per-round log and is never loaded wholesale into the next prompt.
- Existing project-local PM tools take precedence; otherwise the global tool path and launcher are used.

## Round contract

Every round receives only:

1. project root, current branch, and short Git status;
2. approved Goal ID and the bounded `goal-brief.md`;
3. Task ID and current leader/Agent handoff summaries;
4. the last round's bounded result;
5. deadline and remaining round budget.

The Claude session must:

1. select the highest-value unfinished improvement already supported by the task scope;
2. inspect only the files needed for that improvement;
3. write or update a focused test before changing behavior when practical;
4. implement the smallest change;
5. run the strongest available validation;
6. revert its own unverified change or mark the round blocked if validation fails;
7. commit only verified changes to the loop branch;
8. write a handoff containing status, changed paths, commit, tests, risks, and exactly one next action;
9. return a short machine-readable result: `CONTINUE`, `DONE`, or `BLOCKED`.

The loop stops on `DONE`, `BLOCKED`, deadline, maximum rounds, a dirty-worktree safety violation, or three consecutive failed rounds. A transient API/transport failure is retried with bounded backoff and counted separately from a code-validation failure.

## No-confirmation policy

The loop uses the existing `bypassPermissions` GLM launcher and does not pause for ordinary tool approvals. This does not authorize secrets, production deployment, destructive Git operations, deleting user changes, or changes outside the current repository. Such conditions write `BLOCKED` and stop for human review.

## Resume and completion

When the loop stops, it writes a final handoff but does not mark the task complete until the next human-controlled resume verifies the branch and tests. The next-day workflow is:

```text
/leader-resume <Task-ID>
```

The leader then reviews the loop branch, final handoff, round summaries, and validation results before merging.

## Failure handling

- The lock is released on normal exit and trapped signals.
- A stale lock includes its PID and start time; the loop refuses to overwrite it automatically.
- A failed Claude round leaves its log and handoff path for diagnosis, but the next round receives only a bounded summary.
- The script exits non-zero for invalid deadlines, missing tools, lock contention, safety stops, or blocked work; it exits zero for deadline/DONE completion.
