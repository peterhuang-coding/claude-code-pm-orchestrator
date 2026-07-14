# Worktree Plan

## 1. Checkpoint 与 Handoff

```bash
git status
git add .
git commit -m "checkpoint before parallel claude worktrees"

TASK_ID=$(./.claude/skills/pm-orchestrator/scripts/pm-handoff.sh new <short-name>)
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
cd ../<project>-product && ./.claude/skills/pm-orchestrator/scripts/launch-claude-glm.sh
cd ../<project>-tech && ./.claude/skills/pm-orchestrator/scripts/launch-claude-glm.sh
cd ../<project>-test && ./.claude/skills/pm-orchestrator/scripts/launch-claude-glm.sh
cd ../<project>-risk && ./.claude/skills/pm-orchestrator/scripts/launch-claude-glm.sh
cd ../<project>-dev && ./.claude/skills/pm-orchestrator/scripts/launch-claude-glm.sh
```

启动脚本默认使用 `https://api.sfkey.cn`，忽略外部遗留的 `ANTHROPIC_BASE_URL`，清除冲突 token/effort 变量，并将主模型和子 Agent 模型钉到 `glm-5.2`。如果当前应用要求 `/v1`，启动时设置 `SFKEY_BASE_URL=https://api.sfkey.cn/v1`。不要把 API key 写入模板或仓库文件。不要给交互模式添加 `--no-session-persistence`，不要恢复已经过大的旧会话。

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
./.claude/skills/pm-orchestrator/scripts/pm-handoff.sh complete "$TASK_ID"
```
