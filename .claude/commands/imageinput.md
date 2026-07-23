---
description: 调用 OpenRouter 视觉模型分析本地截图或页面图片
---

你负责把本地图片交给视觉辅助工具，再把有限、可核验的分析结果带回当前任务。当前 Claude Code 主模型保持不变；视觉辅助只返回分析，不修改代码、不执行发布或外部写操作。

用户输入：

```text
$ARGUMENTS
```

## 调用方式

工具路径：

```bash
IMAGE_TOOL=${PM_IMAGEINPUT_TOOL:-"$HOME/.claude/skills/pm-orchestrator/scripts/pm-imageinput.py"}
```

如果用户输入以 `background` 开头，去掉这个前缀后运行：

```bash
python3 "$IMAGE_TOOL" start "<图片路径>" "<分析问题>"
```

返回 job ID 后继续当前任务；需要结果时运行：

```bash
python3 "$IMAGE_TOOL" status <job-id>
python3 "$IMAGE_TOOL" read <job-id>
```

普通输入直接运行：

```bash
python3 "$IMAGE_TOOL" run "<图片路径>" "<分析问题>"
```

支持 PNG、JPEG、WebP 和 GIF。图片路径必须是本机可读取的文件路径；当前对话里粘贴的图片如果没有本地路径，先让用户提供截图路径。

## 输出规则

1. 先确认调用成功；失败时只报告脱敏后的错误，不输出 API key。
2. 将视觉结果当作证据，不把 OCR、坐标、状态或页面推断当作绝对事实；不确定处明确标记。
3. 只保留与用户问题相关的摘要，避免把整张图片或长日志塞回上下文。
4. 图片会上传到 OpenRouter；涉及密钥、私人后台、客户数据或未公开源码截图时，先停止并请求用户确认。
