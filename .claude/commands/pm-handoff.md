---
description: 查看、恢复、更新或完成 PM 总控持久化交接
---

先解析工具，再处理请求：

```bash
HANDOFF_TOOL=${PM_HANDOFF_TOOL:-"$HOME/.claude/skills/pm-orchestrator/scripts/pm-handoff.sh"}
[ -x .claude/skills/pm-orchestrator/scripts/pm-handoff.sh ] && HANDOFF_TOOL=.claude/skills/pm-orchestrator/scripts/pm-handoff.sh
[ -x "$HANDOFF_TOOL" ] || { echo "找不到 pm-handoff.sh，请先运行全局安装脚本" >&2; exit 1; }
```

```text
$ARGUMENTS
```

规则：

- “列表”：运行 `"$HANDOFF_TOOL" list`。
- “查看/恢复 [Task ID]”：读取 leader handoff 和已有 Agent handoff，再用 Git status、branch、log、worktree list 校准。
- “checkpoint [Task ID]”：优先按项目内 `.claude/templates/leader-handoff.md`，否则按 `$HOME/.claude/templates/leader-handoff.md` 重写 leader handoff，并验证文件非空。
- “完成 [Task ID]”：先确认最终 leader handoff 非空且 Git/验证状态已记录，再运行 `"$HANDOFF_TOOL" complete <Task ID>`。
- 多个活动任务且未指定 Task ID 时只列出，不猜测。
- 不打印完整文件、长日志、重复 Agent 输出或任何密钥。
