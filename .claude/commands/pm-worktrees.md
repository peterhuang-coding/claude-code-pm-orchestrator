---
description: 根据需求生成 PM 多 Agent git worktree 并行命令
---

你是 PM worktree 规划 Agent。请使用 `pm-orchestrator` skill，为以下需求生成可复制的 git worktree 并行命令。

需求：

```text
$ARGUMENTS
```

严格要求：

- 先要求用户或当前 Agent 检查当前目录是否是 git repo：`git status`。
- 推断 `<project>` 为仓库目录名，`<short-name>` 为任务短名。
- 只输出命令和注意事项，不实际执行 destructive 操作，除非用户明确要求。
- 命名不要冲突；如果可能冲突，提示先改 `<short-name>`。
- 固定把模型钉到中转站 GLM-5.2：`claude --model glm-5.2`。
- 固定使用中转站 base URL：`ANTHROPIC_BASE_URL=https://api.sfkey.cn`。如果你的应用要求 `/v1` 后缀，改成 `https://api.sfkey.cn/v1`。
- 可以保留高并发工具调用：`CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=15`。
- 不要使用 `CLAUDE_CODE_EFFORT_LEVEL=max`，避免中转站把子会话路由到无权限模型。
- 不要把 API key 写进命令、模板或仓库文件；key 应该放在本机 Claude Code 配置或 shell 环境里。
- 先用 `pm-handoff.sh new <short-name>` 创建唯一 `TASK_ID`；所有 worktree/Agent 共用该 ID。
- 使用统一启动脚本清理旧 DeepSeek/Token 环境并钉住主模型和子 Agent 模型。

请输出以下命令块：

```bash
git status
git add .
git commit -m "checkpoint before parallel claude worktrees"

TASK_ID=$(./.claude/skills/pm-orchestrator/scripts/pm-handoff.sh new <short-name>)
echo "$TASK_ID"

git worktree add ../<project>-product -b task/product-<short-name>
git worktree add ../<project>-tech -b task/tech-<short-name>
git worktree add ../<project>-test -b task/test-<short-name>
git worktree add ../<project>-risk -b task/risk-<short-name>
git worktree add ../<project>-dev -b task/dev-<short-name>

cd ../<project>-product && ./.claude/skills/pm-orchestrator/scripts/launch-claude-glm.sh
cd ../<project>-tech && ./.claude/skills/pm-orchestrator/scripts/launch-claude-glm.sh
cd ../<project>-test && ./.claude/skills/pm-orchestrator/scripts/launch-claude-glm.sh
cd ../<project>-risk && ./.claude/skills/pm-orchestrator/scripts/launch-claude-glm.sh
cd ../<project>-dev && ./.claude/skills/pm-orchestrator/scripts/launch-claude-glm.sh

git status
git diff
git add .
git commit -m "implement <short-name>"

cd <main-project-path>
git checkout <main-branch>
git merge task/dev-<short-name>

git worktree remove ../<project>-product
git worktree remove ../<project>-tech
git worktree remove ../<project>-test
git worktree remove ../<project>-risk
git worktree remove ../<project>-dev
```

补充说明每一步用途、何时不应该创建 worktree、如何处理已有未提交改动。

启动脚本用于新的交互会话；不要附加 `--no-session-persistence`，也不要用 `-c`、`--continue`、`-r` 或 `--resume` 载入已超限旧会话。每个 Agent 的第一条提示词必须带 `TASK_ID` 和唯一 agent role。
