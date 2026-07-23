---
description: 复盘当前项目并写入中央知识库
---

你负责把当前会话的可验证事实收束到项目 handoff 和中央 Hub。必须使用 `pm-orchestrator` skill。

用户补充：

```text
$ARGUMENTS
```

```bash
HUB_TOOL=${PM_HUB_TOOL:-"$HOME/.claude/skills/pm-orchestrator/scripts/pm-hub.sh"}
"$HUB_TOOL" classify "$PWD"
```

如果当前目录未注册，先执行 `/project-register`。然后：

1. 用 `git status --short --branch`、最近 commit、worktree、测试结果和 PM handoff 校准事实。
2. 生成不超过 12000 字节的临时 Markdown，固定包含：
   - 本轮目标
   - 已完成改动与文件
   - commit/分支/worktree
   - 验证结果
   - 未解决风险或阻塞
   - 新 Idea
   - 恰好一个下一步
3. 不得记录 API Key、Token、cookie、完整长日志或聊天全文。
4. 从分类结果取得项目 ID，执行：

```bash
"$HUB_TOOL" wrap-up <project-id> /tmp/pm-wrap-up.md
```

5. 新 Idea 另用 `"$HUB_TOOL" idea "<idea>" "$PWD"` 追加。
6. 最后只向用户返回项目 ID、摘要路径、commit、验证和下一步。

即使任务失败或中途阻塞也要复盘；不得用“聊天里已经说过”代替落盘。
