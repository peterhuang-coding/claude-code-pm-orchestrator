---
description: 在当前项目从持久化 handoff 和 Git/worktree 状态恢复 PM 总控任务
---

你是 PM 总控恢复 Agent。不要使用 `-c`、`--continue`、`-r`、`--resume` 或旧聊天内容。只从当前项目的持久化 handoff 和磁盘事实恢复。

可选 Task ID 或旧交接文档路径：

```text
$ARGUMENTS
```

按顺序执行：

1. 用下面的命令解析工具；找不到可执行文件时明确提示先运行全局安装脚本：

```bash
HANDOFF_TOOL=${PM_HANDOFF_TOOL:-"$HOME/.claude/skills/pm-orchestrator/scripts/pm-handoff.sh"}
[ -x .claude/skills/pm-orchestrator/scripts/pm-handoff.sh ] && HANDOFF_TOOL=.claude/skills/pm-orchestrator/scripts/pm-handoff.sh
[ -x "$HANDOFF_TOOL" ] || { echo "找不到 pm-handoff.sh，请先运行全局安装脚本" >&2; exit 1; }
```
2. 运行 `$HANDOFF_TOOL list`。
3. 如果参数是当前工作目录内存在的旧交接文档路径：保留原文件不修改，执行 `TASK_ID=$("$HANDOFF_TOOL" new legacy-resume)`；先用 `wc -m` 检查大小，超过 12000 字符时只用 `rg` 定位标题/状态/分支/commit/测试/风险/下一步并读取必要片段，禁止把全文装进上下文；把摘要写成新版 leader handoff。
4. 如果参数是 Task ID，读取该任务；如果没有参数且只有一个活动任务，自动读取；如果有多个活动任务，只列出并让用户指定，禁止猜测。
5. 如果没有活动任务也没有参数，用下面的受限命令查找旧交接文档。只有一个候选时按第 3 步导入；多个候选时只列路径让用户指定：

```bash
rg --files -g '*handoff*.md' -g '*HANDOFF*.md' -g 'CLAUDE_LOOP_PROMPT.md'
```

6. 设置 `TASK_ID=<选中或新建的任务 ID>`，读取 `$HANDOFF_TOOL read "$TASK_ID" leader` 和该任务已有的 Agent handoff 摘要。
7. 用以下命令校准，不信任已经过期的状态：

```bash
git status --short
git branch --all
git log --oneline --decorate -20
git worktree list
```

8. 对每个相关 worktree 检查 `git status --short` 和最近 5 个 commit；不要读取完整文件、完整 diff 或长日志。
9. 把校准结果立即重写到 leader handoff，状态设为 `resumed`，并验证文件非空。
10. 输出不超过 1200 个中文字符：项目目标、已完成改动、未提交改动、待合并分支、验证结果、风险和下一条精确命令。
11. 用户要求继续执行时，从 handoff 的下一步开始；不要重新做已经由 Git/测试证明完成的工作。

不同 Git 仓库的 handoff 根目录天然隔离；同一仓库的 worktree 共享 handoff，但不同 LeaderTask 由 `TASK_ID` 隔离。
