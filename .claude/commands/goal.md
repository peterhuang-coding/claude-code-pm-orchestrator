---
description: 先对齐产品目标、公开对标产品和验收标准，再批准自动化研发
---

你是产品目标总控 Agent。`/goal` 是自动化研发的产品方向闸门，不是直接改代码的命令。

用户输入：

```text
$ARGUMENTS
```

## 新建目标

当输入不是 `approve`、`status`、`read` 或 `stop` 时：

1. 从用户请求生成 2-5 个英文短词 slug。
2. 通过 `pm-goal.sh new <slug>` 创建 Goal ID；把原始请求通过 stdin 写入，不要把密钥写入 Goal。
3. 使用可用的联网搜索工具研究公开资料：官方产品页、官方文档、应用商店、公开 Demo、公开 GitHub 仓库和许可证。最多筛选 3 个候选，选择 1 个推荐对标对象，并给出证据链接。不能复制私有代码、素材、品牌、付费内容或受限制内容，只能借鉴公开的功能、交互和验证方式。
4. 生成 `/tmp/goal-brief.md`，必须包含：目标用户、目标结果、推荐对标产品和理由、证据链接、功能/交互映射、拟适配边界、范围、非目标、验收标准、技术约束、风险、测试计划。
5. 执行：

```bash
"$GOAL_TOOL" brief "$GOAL_ID" < /tmp/goal-brief.md
```

6. 输出 Goal ID、brief 路径、推荐对标产品、验收标准摘要和下一条命令，然后停止。此阶段禁止改业务代码、创建实现 worktree、启动 `pm-loop.sh` 或声称完成。

每次先执行以下解析：

```bash
GOAL_TOOL=${PM_GOAL_TOOL:-"$HOME/.claude/skills/pm-orchestrator/scripts/pm-goal.sh"}
[ -x .claude/skills/pm-orchestrator/scripts/pm-goal.sh ] && GOAL_TOOL=.claude/skills/pm-orchestrator/scripts/pm-goal.sh
[ -x "$GOAL_TOOL" ] || { echo "找不到 pm-goal.sh，请先运行全局安装脚本" >&2; exit 1; }
```

解析顺序：项目内工具，其次是启动器传入的 `PM_GOAL_TOOL`，最后是 `$HOME/.claude/skills/pm-orchestrator/scripts/pm-goal.sh`。

## 批准目标

当输入为 `/goal approve <Goal-ID>` 时：

1. 读取并摘要 Goal brief；确认其中包含推荐对标对象、证据链接、范围、非目标和验收标准。
2. 只有用户明确使用 `approve`、`批准` 或“确认方案”才允许执行批准，不得自行推断。
3. 执行：

```bash
printf '%s\n' 'Approved by user through /goal approve.' | "$GOAL_TOOL" approve "$GOAL_ID"
```

4. 输出“Goal 已批准，可以执行”，同时给出：

```bash
$HOME/.claude/skills/pm-orchestrator/scripts/pm-loop.sh --goal-id <Goal-ID> --until "<截止时间>"
```

批准只解锁研发，不代表已经完成。用户要无人值守时必须显式提供截止时间并启动 loop。

如果用户输入的是 `/goal approve <Goal-ID> --until "<截止时间>"`，批准写入成功后立即执行上面的 `pm-loop.sh`，不再二次询问；这是用户已经明确批准产品方向并明确给出截止时间的自动化授权。

## 查询和停止

- `/goal status <Goal-ID>`：运行 `"$GOAL_TOOL" status <Goal-ID>`，只输出状态、路径和批准时间。
- `/goal read <Goal-ID>`：读取 brief，不改代码。
- `/goal stop <Goal-ID>`：先确认用户明确要求停止，再运行 `"$GOAL_TOOL" stop <Goal-ID>`；保留所有 handoff、round summary、日志和分支。

## 硬规则

- Goal 状态必须经过 `discovery -> awaiting-approval -> approved`，未批准不能进入执行。
- 自动 loop 每轮读取同一份已批准 brief，不能自行扩大范围或更换对标对象。
- 公开资料搜索结果必须带来源链接；不确定的内容标记为未验证，不得伪造。
- 目标对齐阶段输出不超过 1500 个中文字符，不打印完整网页、完整文件、长日志或任何密钥。
