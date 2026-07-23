---
description: 把当前仓库注册到个人研发总控
---

你负责把当前目录注册到中央 Hub：

```bash
HUB_TOOL=${PM_HUB_TOOL:-"$HOME/.claude/skills/pm-orchestrator/scripts/pm-hub.sh"}
"$HUB_TOOL" register "$PWD"
"$HUB_TOOL" cold-start "$PWD"
```

如用户在 `$ARGUMENTS` 中给了简短 ID，ID 只能包含小写字母、数字和连字符：

```bash
"$HUB_TOOL" register "$PWD" <project-id>
```

注册只创建中央摘要、Idea、任务队列和 sessions 目录，不修改项目代码、Git 配置或 Claude 模型设置。完成后报告项目 ID 与 Hub 路径。
