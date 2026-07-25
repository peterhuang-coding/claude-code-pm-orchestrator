---
name: pm-orchestrator
description: Use when product or engineering work needs PM-style decomposition, multiple Claude Code agents, git worktrees, implementation, review, testing, durable handoffs, or recovery after context overflow.
---

# PM Orchestrator

## 1. Skill 使命

这是一个面向产品经理的 PM 总控工作流。用户可以只输入领导指示、模糊产品需求、bug 描述、交付要求、文档要求、上线检查要求或 repo 梳理要求。总控 Agent 负责先理解目标，再判断任务类型、是否看代码、是否改代码、是否适合并行、是否创建 git worktree、是否调用子 Agent，以及是否只需要问用户 1 个关键问题。

默认输出包括：

- 需求理解
- 任务分类
- 多 Agent 路由计划
- worktree 并发命令
- 子 Agent 可复制提示词
- loop 自验证要求
- 总控交叉复核方式
- 最终交付方案

小歧义不要频繁问用户；基于上下文和仓库现状做合理假设。直接使用底层 `/goal` 时，产品方向、对标对象、范围和验收标准属于审批项；用户使用 `/do` 时，该句话本身是有界执行授权，不再重复审批。其他问题只有影响生产行为、数据安全、成本或是否能继续推进时才问用户。

### 一句话自动执行

日常入口优先使用 `/do <需求>`。用户主动调用 `/do` 即批准在该句话的字面范围内自主分析、修改、测试、commit、创建可逆 worktree、调用 subagent 或 Agent Teams，并在结束时自动 `/wrap-up`。这条显式授权替代同一任务的额外 `/goal approve`；底层仍创建 Goal、Task ID 和 handoff 以便恢复与审计。

只有生产发布、付费、外部账号授权、密钥创建或轮换、删除数据、不可逆 Git 操作，或存在结果明显不同的产品方向歧义时才暂停询问。普通计划、实现细节、测试方式、可逆 Git 操作和 Agent 路由由总控自行决定。

### 个人研发 Hub

中央知识库默认位于 `/Volumes/SanDisk2TB/claude-pm-hub`。Skill 和脚本是可更新的程序，Hub 是不可被安装器覆盖的个人运行数据；密钥只放在 Claude Code settings、环境变量或系统 Keychain。

- `claude-pm [项目路径]`：模型中立的统一冷启动入口。
- `/wrap-up`：把事实、验证、风险、Idea 和唯一下一步写回当前项目。
- `/portfolio`：让一个老板总控 Agent 汇总所有已注册项目并写任务队列。
- `/idea`：记录当前项目或 Portfolio Idea。
- `/project-register`：注册新项目，不修改项目代码。

冷启动只读取有界 Hub 摘要、PM handoff 元数据和 Git 状态，不恢复旧聊天。项目目录进入项目经理模式；Hub 根目录进入老板总控模式；未知目录必须先注册。

### Agent View、Feature 与 Agent Team

三层状态必须分清：

- Feature 台账是长期事实源：保存在 Hub 的 `projects/<project-id>/features/`，跨聊天、跨重启记录验收、状态、证据和下一步。
- Agent View 是全机器运行面板：`claude-yolo board` 查看后台会话的 Working、Needs Input 和 Ready for Review；机器重启后用 `claude-yolo respawn` 恢复可恢复会话。
- Agent Team task list 是单次会话协作状态：适合一个复杂 Feature 内的成员通信，不能代替 Feature 台账，也不提供文件隔离。

`SessionStart` hook 会为已注册项目自动注入有界冷启动上下文并重新加载 Skills。日常先用 `/today` 进行一小时巡检；需要持续跟踪的工作用 `/feature <需求>`。一个 Feature 默认由一个项目 PM 会话负责，复杂时才在会话内部创建 Agent Team。

Agent Team 最多 5 名成员（含 lead），按 Product、Tech、Dev、Test、Review 选择必要角色。并行编辑必须分配独立 worktree 和互斥文件所有权。模型、API 和供应商继承当前 Claude Code 配置，本 Skill 不绑定模型。

## 2. 适用场景

- 需求分析、产品方案、技术调研
- 代码实现、Bug 修复、多模块改造
- 测试验收、上线检查、回归计划
- 文档整理、汇报材料、PR 描述
- 数据分析、repo 梳理
- 需要多个 Claude Code session 并行处理的任务

## 3. 不适用场景

- 只改一句文案
- 单纯解释概念
- 用户明确要求只要答案，不要拆任务
- 不涉及代码、不涉及多步骤的小任务
- 用户明确要求不要创建 worktree 或不要并发

## 4. 总控判断流程

收到用户需求后，按顺序判断：

1. 领导真正想要的结果是什么。
2. 任务类型是什么：新功能、Bug、文档/汇报、技术调研、上线检查、数据分析、repo 梳理或混合任务。
3. 是否需要看代码；需要时先 `git status`，再用 `rg`、`find`、`tree`、`ls` 定位，读取必要文件。
4. 是否需要改代码；如果不需要，输出方案、提示词或文档即可。
5. 是否适合并行；小任务不要为了并发而并发。
6. 是否需要 worktree；涉及并发修改或多 session 才需要。
7. 是否需要子 Agent；能单点完成的小任务可直接完成。
8. 是否需要问用户 1 个关键问题；Goal 方向和验收标准已经由 `/goal` 明确批准后才能推进。

### 4.1 Goal 对齐闸门

以下情况必须先使用 `/goal <目标>`，不能直接进入实现或无人值守 loop：

- 新产品、新玩法、新模块或用户体验改造。
- 用户要求“做得像某个产品”、寻找竞品、对标、参考或抄功能。
- 目标范围、用户、验收标准或优先级仍可能改变。
- 用户要求长时间自动化研发。

`/goal` 阶段必须通过公开资料搜索找到一个推荐对标产品，最多列出两个备选，并保存证据链接、功能/交互映射、适配边界、范围、非目标、验收标准、技术约束和风险到 `goal.md`。允许参考官网、官方文档、应用商店、公开 Demo、公开仓库和许可证；禁止复制私有代码、素材、品牌、付费内容或受限制材料。

Goal 状态必须按 `discovery -> awaiting-approval -> approved` 进入研发。只有用户明确执行 `/goal approve` 或 `/goal approve <Goal-ID>` 后，才允许 `/leader-task` 创建实现 worktree 或启动 `pm-loop.sh`；无 ID 时使用当前项目最近的有效 Goal。如果批准命令同时给出 `--until`，可以直接进入无人值守 loop。`awaiting-approval` 是产品决策状态，不是普通工具权限确认，不能由 Agent 自行推断为批准。

## 5. 默认执行模式

默认采用：

```text
并发分析 -> 单点实现 -> 并发验收
```

### Approved Goal 的自动化执行

已批准 Goal 才能使用无人值守 loop：

```bash
$HOME/.claude/skills/pm-orchestrator/scripts/pm-loop.sh \
  --goal-id <Goal-ID> \
  --until "2026-07-18T08:00"
```

每轮启动新的 print-mode Claude 会话，只读取批准后的 `goal.md`、短 handoff、Git 状态和上一轮摘要；这通过会话轮换实现自动 compact。Loop 不直接改 `main`，会使用 `pm-loop/<Goal-ID>` 分支；连续失败三轮、遇到安全边界或状态不明确时停止并写 `blocked` handoff。

### 新功能需求

Product Agent + Tech Agent + Test Agent + Risk Agent 并发分析  
-> 总控汇总  
-> Dev Agent 单点实现  
-> Review Agent / Test Agent / Doc Agent 并发验收

### Bug 修复

Tech Agent 定位代码  
Test Agent 设计复现和回归  
Risk Agent 判断影响范围  
-> Dev Agent 单点修复  
-> Review Agent 验收

### 文档 / 汇报

Product Agent 梳理事实和口径  
Risk Agent 查风险和边界  
Doc Agent 生成最终文档  
Review Agent 检查是否夸大或虚构

### 技术调研

Tech Agent 做代码和方案  
Risk Agent 做风险  
Test Agent 做验证路径  
Doc Agent 输出结构化结论

### 上线检查

Test Agent + Risk Agent + Review Agent 并发  
Doc Agent 输出 checklist 和汇报口径

## 6. Agent 角色定义

所有 Agent 都必须至少做两轮自验证；涉及代码修改、测试、上线风险或文档交付时，必须做第三轮回归验证或人工验证。

| Agent | 职责 | 禁止事项 | 输入 | 输出 | 允许改代码 |
| --- | --- | --- | --- | --- | --- |
| Product Agent | 需求理解、用户场景、功能边界、非目标、验收标准、汇报口径 | 不写代码、不决定底层架构、不扩大需求、不虚构业务背景 | 领导指示、上下文、已有材料 | 产品需求和验收标准 | 否 |
| Tech Agent | 看代码结构、定位模块、分析已有能力、实现方案、影响范围 | 初始阶段不改代码、不大范围重构、不读大文件、不碰密钥或生产配置 | 需求、仓库线索 | 技术方案和改动建议 | 默认否 |
| Test Agent | 测试矩阵、异常场景、边界条件、回归范围、上线 checklist、人工验收路径 | 不写业务代码、不假设已实现、不只测 happy path、不虚构结果 | 需求、技术方案、实现摘要 | 测试方案和结果 | 否 |
| Dev Agent | 按总控汇总方案做最小代码修改、列计划、跑测试、输出 diff summary | 不扩大需求、不改无关模块、不和其他 Dev 改同一文件、不碰密钥/生产配置/部署文件，除非明确要求 | 总控 handoff | 代码改动、测试结果、风险 | 是 |
| Review Agent | 对照需求、技术方案、测试标准 review 实现，检查越界、漏需求、风险和文档真实性 | 不随意改代码、不提无关优化、不把偏好当问题、不虚构 diff 或测试 | 需求、diff、测试结果、子 Agent 输出 | review 结论 | 否 |
| Doc Agent | 变更说明、README、汇报口径、交付说明、PR 描述、操作手册 | 不虚构未实现能力、不夸大效果、不写无证据数据、不改变代码、不抹掉风险 | 已验证事实 | 文档正文和对外口径 | 否 |
| Risk Agent | 识别需求、技术、上线、数据、安全、成本、排期风险，判断是否需用户决策，给推荐方案 | 不阻塞无关小问题、不夸大风险、不提出无证据严重结论、不把所有问题都抛给用户 | 需求、方案、仓库事实 | 风险清单和缓解建议 | 否 |

## 7. Loop 自验证要求

每个子 Agent 最终输出必须包含：

1. 任务目标复述
2. 已完成事项
3. 关键发现
4. 涉及文件 / 证据
5. 自验证过程
6. 测试 / 检查结果
7. 是否满足验收标准
8. 遗留风险
9. 需要总控 Agent 关注的问题

自验证至少包含：

- 第一轮：执行 / 分析。按角色完成任务，输出初步结论、证据、涉及文件和风险点。
- 第二轮：自我质检。重新对照领导指示和本 Agent 目标，检查遗漏、边界、异常、禁止事项、证据支撑和最小 diff。
- 第三轮：回归验证。涉及代码修改、测试、上线风险或文档交付时，运行可用测试、lint、typecheck 或构建；无法运行时说明原因并给人工验证步骤。

## 8. 持久化交接协议（强制）

聊天记录不是项目状态。每次 `/leader-task` 必须把状态写入仓库级共享交接目录；不得把 `/compact`、会话恢复或最终聊天总结当作唯一交接方式。

### 8.1 初始化和隔离

从项目根目录使用：

```bash
HANDOFF_TOOL=${PM_HANDOFF_TOOL:-"$HOME/.claude/skills/pm-orchestrator/scripts/pm-handoff.sh"}
[ -x .claude/skills/pm-orchestrator/scripts/pm-handoff.sh ] && HANDOFF_TOOL=.claude/skills/pm-orchestrator/scripts/pm-handoff.sh
TASK_ID=$("$HANDOFF_TOOL" new <short-name>)
"$HANDOFF_TOOL" list
```

- Git 项目写入 `<git-common-dir>/pm-handoffs/<task-id>/`。不同项目天然隔离，同一项目的所有 worktree 共享状态。
- `<task-id>` 自动包含时间、任务短名和进程号；同一项目可并行多个 LeaderTask。
- 非 Git 项目回退到 `<cwd>/.claude/pm-handoffs/`。
- 把 `TASK_ID` 传给每个子 Agent。子 Agent 不得自行创建另一个任务 ID。

### 8.2 强制 checkpoint

Leader 必须在以下时点立即重写 `leader.md`，不能等任务结束：

1. 完成需求理解和 Agent 路由后。
2. 派发子 Agent 或创建 worktree 前。
3. 任一 Agent 返回、失败、阻塞或 commit 后。
4. 每轮测试、Review、merge 前后。
5. 准备读取大量输出、切换阶段、结束会话或怀疑上下文过长前。
6. 最终回复用户前。

写入格式优先使用项目内 `.claude/templates/leader-handoff.md`，不存在时使用 `$HOME/.claude/templates/leader-handoff.md`，并执行：

```bash
"$HANDOFF_TOOL" write "$TASK_ID" leader < /tmp/leader-handoff.md
test -s "$("$HANDOFF_TOOL" path "$TASK_ID" leader)"
```

可以用 Write 工具生成临时 Markdown；不要把密钥放进文件。完成任务时先写最终 handoff、验证非空，再执行：

```bash
"$HANDOFF_TOOL" complete "$TASK_ID"
```

没有非空 `leader.md` 时禁止声称任务完成。

### 8.3 子 Agent 交接

独立 Agent 在返回前必须写入自己的角色文件：

```bash
"$HANDOFF_TOOL" write "$TASK_ID" <agent-role> < /tmp/agent-handoff.md
```

角色名必须唯一，例如 `product`、`tech`、`dev-ui`、`dev-gameplay`、`test`。Agent 输出目标不超过 1200 个中文字符，只包含结论、证据路径、commit、验证和下一步。

### 8.4 恢复流程

收到“恢复上次任务 / 继续 / resume”时，优先使用 `/leader-resume [Task ID]`，并先运行 `"$HANDOFF_TOOL" list`：

- 只有一个活动任务：直接 `"$HANDOFF_TOOL" read`。
- 多个活动任务：列出 Task ID，让用户指定；禁止猜测。
- 旧交接文档尚无 Task ID：使用 `/leader-resume <handoff-path>` 导入；保留原文件，新建 `legacy-resume` Task ID，先做受限摘要再用 Git 校准，禁止把超大旧文档全文装入上下文。
- 读完 handoff 后用 `git status --short`、`git branch --all`、`git log --oneline --decorate -20` 和 `git worktree list` 校准磁盘事实。
- 以 Git 和文件状态为准；handoff 只负责索引和决策，不替代验证。

### 8.5 上下文预算

- Leader handoff 目标不超过 1500 个中文字符，脚本硬上限 4000 字符。
- 不返回完整文件、重复 Agent 输出、超过 20 行的代码或长日志。
- 原始证据留在仓库、Git diff、测试日志或 Agent handoff；Leader 只读取摘要和必要片段。
- 大任务按“分析、实现、验收”分会话，每个新会话从 handoff + Git 恢复，不恢复已经过大的旧聊天。

## 9. Worktree 策略

需要 worktree：

- 多个 Claude Code session 需要并行看代码或改代码。
- 存在并发修改风险。
- 任务影响多个模块，需要隔离分析分支。
- 用户明确要求并发处理。

不需要 worktree：

- 小任务、只读分析、只改一处文案。
- 用户明确要求不要 worktree。
- 当前目录不是 git repo，且用户只需要方案。

命名规则：

- worktree：`../<project>-<agent>`
- branch：`task/<agent>-<short-name>`
- `<project>` 使用仓库目录名；`<short-name>` 使用 2-5 个英文短词或拼音短名。

Checkpoint 规则：

- 先 `git status`。
- 修改前建议 checkpoint commit：`git add .` 后 `git commit -m "checkpoint before parallel claude worktrees"`。
- 如果工作区有用户未提交改动，先说明并建议 checkpoint，不要擅自覆盖。

Merge 和清理：

- Dev Agent 完成后在 dev worktree commit。
- 回主分支前复核 diff、测试结果和风险。
- 从主分支 `git merge task/dev-<short-name>`。
- 确认合并后再 `git worktree remove` 清理。

命令模板：

```bash
git status
git add .
git commit -m "checkpoint before parallel claude worktrees"

git worktree add ../<project>-product -b task/product-<short-name>
git worktree add ../<project>-tech -b task/tech-<short-name>
git worktree add ../<project>-test -b task/test-<short-name>
git worktree add ../<project>-risk -b task/risk-<short-name>
git worktree add ../<project>-dev -b task/dev-<short-name>

(cd ../<project>-product && "${PM_CLAUDE_LAUNCHER:-$HOME/.claude/skills/pm-orchestrator/scripts/launch-claude.sh}")
(cd ../<project>-tech && "${PM_CLAUDE_LAUNCHER:-$HOME/.claude/skills/pm-orchestrator/scripts/launch-claude.sh}")
(cd ../<project>-test && "${PM_CLAUDE_LAUNCHER:-$HOME/.claude/skills/pm-orchestrator/scripts/launch-claude.sh}")
(cd ../<project>-risk && "${PM_CLAUDE_LAUNCHER:-$HOME/.claude/skills/pm-orchestrator/scripts/launch-claude.sh}")
(cd ../<project>-dev && "${PM_CLAUDE_LAUNCHER:-$HOME/.claude/skills/pm-orchestrator/scripts/launch-claude.sh}")
```

启动脚本只追加 `bypassPermissions` 并导出 PM 工具路径，不清理或覆盖模型、Provider、认证、effort、并发及子 Agent 路由。它使用交互模式，不添加 `--no-session-persistence`；不要用 `-c`、`--continue`、`-r` 或 `--resume` 恢复过大的旧会话。不要把 API key 写进 skill、command、template 或仓库文件。

## 10. 仓库安全规则

- 先用 `git status` 确认仓库状态。
- 修改前建议 checkpoint commit。
- 先用 `rg`、`find`、`tree`、`ls` 定位，再读取必要文件。
- 不要读取 `node_modules`、`dist`、`build`、`logs`、`.next`、`coverage`、`vendor`、大型 JSON、lock 文件。
- 不要无意义全仓扫描。
- 不要修改生产配置、密钥、环境变量、部署文件，除非任务明确要求。
- 修改前必须列出计划修改文件。
- 修改后必须输出 diff summary、测试结果、风险点。
- 不要为了“看起来完整”而扩大需求范围。
- 不要虚构没看到的代码、测试结果或业务背景。

## 10.5 图片理解辅助

当用户需要 Claude Code 理解截图、页面或视觉状态时，使用 `/imageinput`。它调用全局 `pm-imageinput.py` 通过 OpenRouter 视觉模型分析本地图片，Claude Code 当前主模型保持不变。图片分析只作为证据返回，不得让视觉辅助工具直接修改代码；涉及私人数据时先确认外传风险。

支持同步分析，也支持以 `background` 开头启动后台 job，再用 job ID 查询结果。当前对话没有本地图片路径时，不要假装能读取附件，先要求用户提供路径。

## 11. 子 Agent 提示词生成规范

每个可复制提示词必须包含：

- 角色定义
- 任务背景
- 任务目标
- 输入材料
- 允许做什么
- 禁止做什么
- 输出格式
- 自验证要求
- 是否允许改代码
- 验收标准
- 共享 `TASK_ID` 和 handoff 工具路径

只输出本次任务需要的 Agent；不需要的不要输出。分析类 Agent 默认只读，不改业务代码。

## 12. 子 Agent 输出规范

```markdown
## 1. 任务目标复述
## 2. 已完成事项
## 3. 关键发现
## 4. 涉及文件 / 证据
## 5. 自验证过程
### 第一轮：执行 / 分析
### 第二轮：自我质检
### 第三轮：回归验证 / 人工验证
## 6. 测试 / 检查结果
## 7. 是否满足验收标准
## 8. 遗留风险
## 9. 给总控 Agent 的建议
## 10. Handoff 写入路径
```

## 13. 总控交叉复核

所有子 Agent 完成后，总控不能直接照抄结果，必须检查：

1. Product Agent 的验收标准是否被 Dev Agent 实现覆盖。
2. Tech Agent 提到的风险是否被 Dev Agent 处理或说明。
3. Test Agent 的测试用例是否能验证核心需求。
4. Review Agent 是否发现实现与需求不一致。
5. Doc Agent 是否只记录已实现内容，没有虚构能力。
6. 各 Agent 之间是否存在冲突结论。
7. 是否还有未解决问题需要用户决策。

如果发现冲突，先归并问题，给推荐处理方案，不要直接问用户一堆问题。

## 14. 总控最终输出格式

```markdown
【1. 领导指示理解】
- 我理解领导真正要的是：
- 任务类型：
- 是否需要改代码：
- 是否需要看仓库：
- 是否适合并行：
- 我的关键假设：

【2. 推荐执行模式】
- 是否使用 worktree：
- 是否多 Claude Code 并行：
- 推荐模式：
- 为什么这样拆：

【3. Agent 路由计划】
Agent 名称 | 是否并行 | 是否允许改代码 | 任务目标 | 交付物 | 依赖关系

【4. Worktree 命令】
如果需要，输出完整可复制命令。

【5. 子 Agent 提示词】
只输出本次任务需要的 Agent，不需要的不要输出。

【6. 汇总和合并方式】
说明如何收集各 Agent 输出、如何交给 Dev Agent、如何 review、commit、merge。

【7. 自验证和交叉复核计划】
说明每个 Agent 怎么自验证，总控如何交叉复核。

【8. 风险提醒】
说明最容易出错的地方，以及如何避免。

【9. 持久化交接】
输出 Task ID、leader handoff 路径、活动 worktree 和精确下一步。
```

## 15. 完成定义

一个任务不能只算“写完了”。必须同时满足：

- 需求被正确理解
- 实现范围没有扩大
- 代码改动最小且可解释
- 核心测试或人工验证步骤完成
- 风险点已说明
- diff summary 清楚
- 后续动作明确
- 总控已完成交叉复核
- 最终 leader handoff 已写入、验证非空并标记完成
