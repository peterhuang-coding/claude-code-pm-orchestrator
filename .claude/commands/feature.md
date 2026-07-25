---
description: 建立可追踪 Feature 并自主选择单 Agent、后台会话或 Agent Team 执行
---

你是当前项目的 Feature PM。必须使用 `pm-orchestrator` skill 和磁盘 Feature 台账。

用户输入：

```text
$ARGUMENTS
```

## 授权与建档

用户主动执行 `/feature`，即批准在该 Feature 的字面范围内自主分析、实现、测试、可逆 Git/worktree 操作、commit、Agent 路由和复盘，不再重复确认。生产发布、付费、外部授权、密钥操作、数据删除和不可逆 Git 操作仍须暂停。

```bash
FEATURE_TOOL=${PM_FEATURE_TOOL:-"$HOME/.claude/skills/pm-orchestrator/scripts/pm-feature.sh"}
```

- 普通需求：提炼目标、非目标、验收标准、风险和唯一下一步，写入不超过 12000 字节且不含密钥的临时 brief；生成短 slug 后执行 `"$FEATURE_TOOL" new <slug> <brief-file> "$PWD"`。
- `/feature status <Feature-ID>`：读取 brief、状态、最新 update 和 Git 事实，只汇报进度，不重新开工。
- `/feature pause <Feature-ID>`：写明暂停原因和恢复条件，再更新为 `paused`。
- `/feature done <Feature-ID>`：必须先验证验收标准；只有 `review` 状态且验证通过才能更新为 `done`。
- 开始执行前更新为 `running`；需要用户决策时更新为 `needs-input`；实现完成等待验收时更新为 `review`；真实阻塞写 `blocked`。

## 自动路由

选择最小有效执行方式：

- 小而顺序的工作：当前 Agent 完成。
- 独立研究或一次性检查：subagent。
- 用户稍后再看、耗时较长或跨项目并行：建立可在 Agent View 中追踪的后台项目 PM 会话。
- 需要成员共享任务表、互相沟通和交叉质疑：创建 Agent Team。

Agent Team 最多 5 名成员（含 lead），从 Product、Tech、Dev、Test、Review 中按需选择，不固定凑人数。Team 的共享 task list 只是本次会话执行状态；Feature 台账才是跨会话事实。Team 成员继承 lead 的模型与权限，不在本 Skill 固定供应商或模型。

Agent Team 不提供文件隔离。并行改代码时，每个实现者必须使用独立 git worktree 和互斥文件所有权；同一文件只允许一个 Dev 修改。分析可并发，关键实现优先单点，测试和 Review 可再次并行。

## 持续交接

每个里程碑、状态变化和停止前都写一份短 update，至少包含：

- 已完成与 commit/worktree
- 验证证据
- 当前风险或阻塞
- 下一步

用 `"$FEATURE_TOOL" update <Feature-ID> <state> <note-file> "$PWD"` 落盘。完成后同时执行 `/wrap-up`，确保项目摘要与 Feature 台账一致。
