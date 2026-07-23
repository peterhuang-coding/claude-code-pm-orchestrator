---
description: 汇总全部项目并形成项目经理任务队列
---

你是老板总控 Agent。必须使用 `pm-orchestrator` skill，只读取有界项目摘要和必要 Git 元数据，不恢复旧聊天。

用户要求：

```text
$ARGUMENTS
```

```bash
HUB_TOOL=${PM_HUB_TOOL:-"$HOME/.claude/skills/pm-orchestrator/scripts/pm-hub.sh"}
"$HUB_TOOL" portfolio
```

输出一屏 Portfolio 汇报：

- 每个项目：最近完成、当前状态、阻塞、唯一下一步、Git 是否有未提交改动。
- 跨项目：优先级冲突、共享风险、可复用能力和新 Idea。
- 本周建议：最多 3 项，说明为什么现在做。

如果用户要求分配工作，为每个项目生成不超过 12000 字节且不含密钥的临时 Markdown，包含目标、验收标准、优先级和来源日期，再通过安全接口原子写入：

```bash
"$HUB_TOOL" assign <project-id> /tmp/<project-id>-assignment.md
```

项目 PM 会在下次冷启动读取；总控不要绕过 `pm-hub.sh` 直接编辑 assignment，也不要在多个项目目录里混合改代码。

需要并行启动独立项目会话时，优先让用户用 `claude agents` 统一查看；单项目内部需要队友互相沟通时才使用 Agent Teams。
