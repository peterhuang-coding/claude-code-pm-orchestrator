# Worktree Plan

## 1. Checkpoint 与 Handoff

```bash
git status
git add .
git commit -m "checkpoint before parallel claude worktrees"

HANDOFF_TOOL=${PM_HANDOFF_TOOL:-"$HOME/.claude/skills/pm-orchestrator/scripts/pm-handoff.sh"}
[ -x .claude/skills/pm-orchestrator/scripts/pm-handoff.sh ] && HANDOFF_TOOL=.claude/skills/pm-orchestrator/scripts/pm-handoff.sh
TASK_ID=$("$HANDOFF_TOOL" new <short-name>)
echo "$TASK_ID"
```

## 2. 创建 worktree

```bash
git worktree add ../<project>-product -b task/product-<short-name>
git worktree add ../<project>-tech -b task/tech-<short-name>
git worktree add ../<project>-test -b task/test-<short-name>
git worktree add ../<project>-risk -b task/risk-<short-name>
git worktree add ../<project>-dev -b task/dev-<short-name>
```

## 3. 启动 Claude

```bash
(cd ../<project>-product && "${PM_CLAUDE_LAUNCHER:-$HOME/.claude/skills/pm-orchestrator/scripts/launch-claude.sh}")
(cd ../<project>-tech && "${PM_CLAUDE_LAUNCHER:-$HOME/.claude/skills/pm-orchestrator/scripts/launch-claude.sh}")
(cd ../<project>-test && "${PM_CLAUDE_LAUNCHER:-$HOME/.claude/skills/pm-orchestrator/scripts/launch-claude.sh}")
(cd ../<project>-risk && "${PM_CLAUDE_LAUNCHER:-$HOME/.claude/skills/pm-orchestrator/scripts/launch-claude.sh}")
(cd ../<project>-dev && "${PM_CLAUDE_LAUNCHER:-$HOME/.claude/skills/pm-orchestrator/scripts/launch-claude.sh}")
```

启动脚本不覆盖模型、Provider、认证、effort 或并发设置；主 Agent 和子 Agent 继承 Claude Code 当前 Profile。不要把 API key 写入模板或仓库文件。不要给交互模式添加 `--no-session-persistence`，不要恢复已经过大的旧会话。

## 4. 查看 diff

```bash
git status
git diff
```

## 5. Commit

```bash
git add .
git commit -m "implement <short-name>"
```

## 6. Merge

```bash
cd <main-project-path>
git checkout <main-branch>
git merge task/dev-<short-name>
```

## 7. 清理 worktree

```bash
git worktree remove ../<project>-product
git worktree remove ../<project>-tech
git worktree remove ../<project>-test
git worktree remove ../<project>-risk
git worktree remove ../<project>-dev
```

只有总控已收集所有 Agent handoff、完成 merge/验证并写入最终 leader handoff 后，才清理 worktree 和执行：

```bash
"$HANDOFF_TOOL" complete "$TASK_ID"
```
