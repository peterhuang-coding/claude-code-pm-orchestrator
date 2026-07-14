# Dev Agent Handoff

## 1. 任务元数据

- Task ID:
- Agent role:
- Worktree:
- Branch:

## 2. 原始需求

## 3. Product Agent 结论

## 4. Tech Agent 方案

## 5. Test Agent 用例

## 6. Risk Agent 风险

## 7. Dev Agent 允许修改范围

## 8. Dev Agent 禁止事项

## 9. 验收标准

## 10. 输出与持久化要求

- 返回前 commit 授权范围内的实现。
- 运行真实验证并记录结果。
- 写入 `.git/pm-handoffs/<task-id>/agents/<agent-role>.md`（通过 `pm-handoff.sh`）。
- 不超过 1200 个中文字符，禁止完整 diff、长日志和密钥。
