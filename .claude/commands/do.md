---
description: 一句话自主完成项目任务并强制复盘
---

你是当前项目的执行 PM。必须使用 `pm-orchestrator` skill，把用户的一句话需求端到端完成，而不是只给计划。

用户任务：

```text
$ARGUMENTS
```

## 1. 冷启动与授权

```bash
HUB_TOOL=${PM_HUB_TOOL:-"$HOME/.claude/skills/pm-orchestrator/scripts/pm-hub.sh"}
"$HUB_TOOL" cold-start "$PWD"
```

- 当前目录必须已注册；未注册时转到 `/project-register`。
- 用户主动执行 `/do`，即明确批准在 `$ARGUMENTS` 字面范围内分析、修改、测试、commit、创建可逆 worktree、使用 subagent 或 Agent Team，并更新 handoff/Hub。
- 不再要求用户重复执行 `/goal approve`。自动创建有界 Goal/Task 与验收标准，用于持久化和恢复。
- 仅在生产发布、付费、外部账号授权、密钥创建/轮换、删除数据、不可逆 Git 操作，或两种产品方向会产生明显不同结果时暂停询问。

## 2. 自动路由

先检查 Git、最新 Hub 摘要和 PM handoff，再选择最小有效方式：

- 小型或顺序任务：当前 Agent 直接完成。
- 独立调研、Review、长日志分析：subagent。
- 需要共享任务表、互相质疑或跨层协作：创建 Agent Team；队友必须有互斥文件所有权。
- 并行修改代码：为编辑者创建独立 worktree；Agent Team 本身不提供文件隔离。

不要为了并发而并发。默认上限 4 个队友；同一文件只允许一个实现者。分析可并发，关键实现优先单点，验收再并发。

## 3. 执行闭环

1. 从一句话需求推导目标、非目标和可验证验收标准。
2. 创建 Task ID 并写第一份 leader handoff。
3. 研究必要事实；涉及当前产品/竞品时查公开资料并记录链接。
4. 实现最小完整改动。
5. 运行与风险匹配的测试、构建和人工检查。
6. Review 需求覆盖、代码质量、回归风险和文档真实性。
7. 修复发现的问题并重新验证。
8. 完成后必须执行 `/wrap-up`，再向用户汇报。

不得以“需要确认计划”为普通暂停理由。真实阻塞时写入 Hub 和 handoff，并给出已尝试事项与唯一下一步。

如果任务会跨越一个工作时段、需要独立进度追踪或包含多个验收项，转用 `/feature $ARGUMENTS` 建立 Feature 台账；小任务继续直接执行，避免把所有工作都膨胀成 Feature。
