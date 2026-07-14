---
description: 查看、恢复、更新或完成 PM 总控持久化交接
---

使用 `.claude/skills/pm-orchestrator/scripts/pm-handoff.sh` 处理以下请求：

```text
$ARGUMENTS
```

规则：

- “列表”：运行 `pm-handoff.sh list`。
- “查看/恢复 [Task ID]”：读取 leader handoff 和已有 Agent handoff，再用 Git status、branch、log、worktree list 校准。
- “checkpoint [Task ID]”：按 `.claude/templates/leader-handoff.md` 重写 leader handoff，并验证文件非空。
- “完成 [Task ID]”：先确认最终 leader handoff 非空且 Git/验证状态已记录，再运行 `pm-handoff.sh complete <Task ID>`。
- 多个活动任务且未指定 Task ID 时只列出，不猜测。
- 不打印完整文件、长日志、重复 Agent 输出或任何密钥。
