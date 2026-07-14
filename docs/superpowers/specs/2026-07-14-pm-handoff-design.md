# PM Orchestrator Persistent Handoff Design

## Goal

Ensure every `/leader-task` can be resumed from disk after context overflow, terminal closure, or provider failure while many repositories and worktrees run concurrently.

## Storage

Store runtime state under the repository's absolute Git common directory:

```text
<git-common-dir>/pm-handoffs/<task-id>/
  .active
  leader.md
  agents/<role>.md
```

Different repositories have different Git common directories. Worktrees from one repository intentionally share one directory. Task IDs use `<YYYYMMDD-HHMMSS>-<slug>` and isolate concurrent tasks in the same repository. Non-Git work falls back to `<cwd>/.claude/pm-handoffs`.

## Components

- `pm-handoff.sh`: create, list, read, write, complete, and locate handoffs with atomic writes.
- `launch-claude-glm.sh`: clear conflicting inherited variables and pin all main/default/subagent routes to GLM-5.2 for a fresh interactive session.
- `leader-task.md`: initialize or resume a task before exploration and checkpoint after every phase transition.
- `pm-handoff.md`: manual list/show/checkpoint/complete command.
- Agent definitions: write concise role handoffs through the shared tool.
- Templates: define bounded leader and child handoff schemas.

## Data Flow

1. A new LeaderTask creates a unique task ID and an active marker.
2. The leader writes `leader.md` after routing and every material state change.
3. Each independent Agent writes `agents/<role>.md` before returning.
4. The leader reconciles Agent reports against Git status, branches, worktrees, and commits.
5. Completion requires a non-empty final leader handoff and removes the active marker.
6. A fresh session lists active tasks. One task is resumed automatically; multiple tasks require an explicit task ID.

## Context Controls

- Leader handoff target: no more than 1,500 Chinese characters; hard script limit: 4,000 characters.
- Child report target: no more than 1,200 Chinese characters.
- Never include secrets, full files, repeated reports, code blocks over 20 lines, or long logs.
- Keep raw evidence in files and Git; put only paths, commands, commit IDs, and conclusions in handoffs.

## Failure Handling

- Writes use a temporary file followed by atomic rename.
- Empty, oversized, path-traversing, or secret-looking handoffs are rejected.
- Multiple active tasks never resolve implicitly.
- A missing handoff blocks completion claims but never deletes code or worktrees.

## Validation

Shell integration tests create a repository and linked worktree to verify shared storage, project/task isolation, ambiguous-resume rejection, atomic read/write, size limits, secret rejection, and completion state. A stub Claude executable verifies launch environment and arguments without making a network request.
