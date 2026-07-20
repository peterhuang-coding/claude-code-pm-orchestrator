# PM 总控工作流说明

这套 `.claude` 配置用于把领导指示或模糊需求，变成可执行的多 Agent 工作方案。它适合产品经理使用：你只需要贴需求，总控 Agent 会判断要不要看代码、要不要改代码、要不要并发、要不要创建 git worktree，并生成子 Agent 提示词和验收方式。

## 什么时候用 `/leader-task`

当你拿到一段领导指示、产品想法、Bug 描述或交付要求，还没有拆成研发任务时使用。它会输出需求理解、路由计划、worktree 命令、子 Agent 提示词、汇总方式和风险提醒，并在每个阶段把状态写入 Git 公共目录。

每个项目的 handoff 位于自己的 `<git-common-dir>/pm-handoffs/`。多个项目互不影响；同一项目的 worktree 共享状态，并按唯一 Task ID 隔离并发任务。

## 什么时候用 `/goal`

新产品、新功能、玩法改造、对标竞品或需要长时间自动化研发时，先运行 `/goal <目标>`。它会基于公开资料找推荐对标产品，整理目标、范围、非目标、验收标准和风险，然后停在 `awaiting-approval`。你确认后运行 `/goal approve` 即可批准当前项目最近的有效 Goal；也可以使用 `/goal approve <Goal-ID>` 指定目标，之后才允许进入实现或 `pm-loop.sh`。

## 什么时候用 `/pm-route`

当你只想“先拆活”，还不想执行、也不想改代码时使用。它只做任务分类和 Agent 路由，不创建文件、不改代码。

## 什么时候用 `/pm-worktrees`

当你已经决定要多个 Claude Code session 并行分析或隔离实现时使用。它会生成 checkpoint、worktree、启动 Claude、查看 diff、commit、merge 和清理命令。

## 什么时候用 `/pm-review`

当你已经收集到 Product / Tech / Test / Dev / Review / Doc / Risk 等子 Agent 输出后使用。它会做总控交叉复核，判断通过、不通过或有条件通过。

## 怎么和 git worktree 配合

推荐先在主仓库确认 `git status`，必要时做 checkpoint commit。分析 Agent 可以放到不同 worktree 里并发看代码；Dev Agent 默认只在一个 dev worktree 里单点实现；实现后再让 Review / Test / Doc 并发验收。不要让多个 Dev Agent 同时改同一批文件。

## 图片理解

在 Claude Code 中使用 `/imageinput /path/to/screenshot.png 分析页面结构、按钮和当前状态`。主模型仍然走 DeepSeek；命令通过 `pm-imageinput.py` 把本地图片发送给 OpenRouter 视觉模型，再把有限文本分析带回当前任务。默认模型是 `google/gemini-3-flash-preview`，可通过 `OPENROUTER_VISION_MODEL` 覆盖。

先在 shell 中配置本机私有 key，不要写入仓库：

```bash
export OPENROUTER_API_KEY="你的 OpenRouter key"
```

也可以把这行加入 `~/.zshrc`。图片会离开本机发送给 OpenRouter；涉及私人后台、密钥或未公开资料时不要调用。

## 推荐工作流

1. `/leader-task` 贴领导指示。
2. 按输出创建 worktree。
3. 分别启动子 Claude。
4. 收集子 Agent 输出。
5. Dev Agent 单点实现。
6. Review / Test / Doc 并发验收。
7. 总控交叉复核。
8. 总控写入最终 handoff 并标记任务完成。

长时间无人值守时使用已批准 Goal：

```bash
$HOME/.claude/skills/pm-orchestrator/scripts/pm-loop.sh \
  --goal-id <Goal-ID> \
  --until "2026-07-18T08:00"
```

## 会话爆掉后怎么恢复

在原项目或任一关联 worktree 根目录新开 Claude Code，不要 resume 已超限的旧聊天，然后执行：

```text
/leader-resume
```

只有一个活动任务时自动恢复；有多个时会先列出 Task ID，再执行 `/leader-resume <Task ID>`。恢复结果会与 Git status、branch、log 和 worktree list 交叉校准。

第一次升级到新版 Skill、手里只有旧交接文档时：

```text
/leader-resume path/to/旧交接.md
```

它会保留旧文件，创建新的持久化 Task ID，并在受限读取后从 Git/worktree 状态继续。

也可以使用：

```text
/pm-handoff 列表
/pm-handoff 查看 <Task ID>
```

## 每次启动 Claude Code

先从技能仓库安装一次（不会修改 `~/.claude/settings.json` 或凭据）：

```bash
/Volumes/SanDisk2TB/claude-code-pm-orchestrator/.claude/skills/pm-orchestrator/scripts/install-global.sh
```

之后在任意项目根目录执行：

```bash
$HOME/.claude/skills/pm-orchestrator/scripts/launch-claude-deepseek.sh
```

脚本会清理冲突的认证/effort 和子 Agent 模型变量，把主模型设为 DeepSeek `deepseek-v4-pro`；子 Agent 不单独指定模型，继承 Claude Code 当前默认值。它用于新的交互会话，不会恢复旧聊天；默认通过 `https://api.deepseek.com/anthropic` 访问 Anthropic 兼容接口，可用 `DEEPSEEK_BASE_URL` 和 `DEEPSEEK_MODEL` 覆盖。

## 常见注意事项

- 不要多个 Agent 在同一个目录里改代码。
- 不要让分析 Agent 改代码。
- 不要跳过 checkpoint。
- 不要让 AI 修改密钥、环境变量或生产配置。
- 小任务不要强行并发。
- 不要把未验证的猜测写成事实。
- 不要把完整文件、长日志、重复 Agent 输出或密钥写入 handoff。

## 快速测试示例

```text
/leader-task 领导让我把某个功能需求拆成研发可执行方案，并给出风险和验收标准
```
