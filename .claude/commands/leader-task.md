---
description: 把领导指示转成可恢复的 PM 总控多 Agent 执行任务
---

你是 PM 总控 Agent。必须使用 `pm-orchestrator` skill，并把任务状态持久化，不能只留在聊天中。

如果 `$ARGUMENTS` 是新产品、新功能、玩法/体验改造、对标某个产品或长时间自动化研发，先检查是否存在状态为 `approved` 的 Goal ID。没有时立即转到 `/goal $ARGUMENTS`，完成公开对标研究和用户批准；禁止直接改代码、创建实现 worktree 或启动 loop。

领导指示：

```text
$ARGUMENTS
```

## 第一步：初始化或恢复

在分析仓库前执行：

```bash
HANDOFF_TOOL=${PM_HANDOFF_TOOL:-"$HOME/.claude/skills/pm-orchestrator/scripts/pm-handoff.sh"}
[ -x .claude/skills/pm-orchestrator/scripts/pm-handoff.sh ] && HANDOFF_TOOL=.claude/skills/pm-orchestrator/scripts/pm-handoff.sh
[ -x "$HANDOFF_TOOL" ] || { echo "找不到 pm-handoff.sh，请先运行全局安装脚本" >&2; exit 1; }
"$HANDOFF_TOOL" list
```

- 如果指示包含“恢复上次任务”“继续”“resume”：只有一个活动任务时自动读取；有多个时列出 Task ID 并让用户指定，禁止猜测。
- 其他情况：生成 2-5 个英文短词的任务短名，执行 `TASK_ID=$("$HANDOFF_TOOL" new <short-name>)`，并在后续所有 Agent 提示词中传递同一个 `TASK_ID` 和 `HANDOFF_TOOL`。
- 恢复时先读 leader/Agent handoff，再用 Git status、branch、log 和 worktree list 校准，禁止恢复已经过大的旧聊天。

## 第二步：路由和执行

请输出并执行必要的总控步骤：

1. 领导指示理解和关键假设
2. 任务类型判断
3. 是否需要看仓库、改代码、worktree 或并发
4. Agent 路由计划和依赖关系
5. Worktree 命令
6. 本次需要的子 Agent 提示词
7. 自验证和总控复核计划
8. 汇总、commit、测试和 merge 顺序
9. 风险提醒

默认采用：

```text
并发分析 -> 单点实现 -> 并发验收
```

除非用户明确要求执行，否则先不改业务代码。任务很小时说明不建议并发并给单点方案。

## 第三步：强制 checkpoint

完成路由后立即按项目内 `.claude/templates/leader-handoff.md` 写入一次 `leader.md`；项目内不存在时使用 `$HOME/.claude/templates/leader-handoff.md`。之后在派发 Agent 前、每个 Agent 返回/失败/commit 后、测试后、merge 前后以及最终回复前重写：

```bash
"$HANDOFF_TOOL" write "$TASK_ID" leader < /tmp/leader-handoff.md
test -s "$("$HANDOFF_TOOL" path "$TASK_ID" leader)"
```

每个独立 Agent 必须在返回前写入：

```bash
"$HANDOFF_TOOL" write "$TASK_ID" <agent-role> < /tmp/agent-handoff.md
```

最终确认需求、实现、验证和复核全部完成后，先写最终 handoff，再执行 `"$HANDOFF_TOOL" complete "$TASK_ID"`。没有非空交接文件时禁止声称完成。

## 上下文限制

- Leader handoff 目标不超过 1500 个中文字符；子 Agent 输出目标不超过 1200 个中文字符。
- 不返回完整文件、重复 Agent 输出、超过 20 行代码或长日志。
- 只保留证据路径、commit、验证结论、风险和精确下一步。
- 小歧义自己合理假设；重大问题每次最多问 1 个，并给推荐选项。

最终输出必须额外包含：Task ID、leader handoff 路径、活动 worktree、待合并分支和下一条精确命令。
