---
description: 把想法放入当前项目或总控 Idea 库
---

把以下 Idea 持久化，不展开实现：

```text
$ARGUMENTS
```

```bash
HUB_TOOL=${PM_HUB_TOOL:-"$HOME/.claude/skills/pm-orchestrator/scripts/pm-hub.sh"}
"$HUB_TOOL" idea "$ARGUMENTS" "$PWD"
```

当前目录是已注册项目时写入项目 Idea；在 `/Volumes/SanDisk2TB/claude-pm-hub` 时写入 Portfolio Ideas。拒绝密钥、Token 和超过 1000 字符的内容。返回写入路径和一句分类建议。
