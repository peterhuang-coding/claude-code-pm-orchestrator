---
description: 在当前项目从持久化 handoff 和 Git/worktree 状态恢复 PM 总控任务
---

你是 PM 总控恢复 Agent。不要使用 `-c`、`--continue`、`-r`、`--resume` 或旧聊天内容。只从当前项目的持久化 handoff 和磁盘事实恢复。

可选 Task ID：

```text
$ARGUMENTS
```

按顺序执行：

1. 设置 `HANDOFF_TOOL=.claude/skills/pm-orchestrator/scripts/pm-handoff.sh`。
2. 运行 `$HANDOFF_TOOL list`。
3. 如果参数包含 Task ID，读取该任务；如果没有参数且只有一个活动任务，自动读取；如果有多个活动任务，只列出并让用户指定，禁止猜测。
4. 设置 `TASK_ID=<选中的任务 ID>`，读取 `$HANDOFF_TOOL read "$TASK_ID" leader` 和该任务已有的 Agent handoff 摘要。
5. 用以下命令校准，不信任已经过期的状态：

```bash
git status --short
git branch --all
git log --oneline --decorate -20
git worktree list
```

6. 对每个相关 worktree 检查 `git status --short` 和最近 5 个 commit；不要读取完整文件、完整 diff 或长日志。
7. 把校准结果立即重写到 leader handoff，状态设为 `resumed`，并验证文件非空。
8. 输出不超过 1200 个中文字符：项目目标、已完成改动、未提交改动、待合并分支、验证结果、风险和下一条精确命令。
9. 用户要求继续执行时，从 handoff 的下一步开始；不要重新做已经由 Git/测试证明完成的工作。

不同 Git 仓库的 handoff 根目录天然隔离；同一仓库的 worktree 共享 handoff，但不同 LeaderTask 由 `TASK_ID` 隔离。
