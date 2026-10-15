# gsb-batch — Pair-wise GSB 批量跑批脚本

按《Pair-wise GSB 项目》需求实现：自动调起 codex CLI 以同一提示词跑 A/B 两轮，检测对话结束、自动采集 sessionid + 轨迹文件，并自动开启下一轮；产物可自动推送到 GitHub。

## 三条需求闭环

| # | 需求 | 实现 |
| - | - | - |
| 1 | 自动调起 CLI 两轮对话，自动输入提示词 | `codexr exec` 非交互调用，提示词经 stdin 作为唯一输入；一个任务 = A/B 两个独立 session |
| 2 | 检测对话结束，采集 sessionid + 轨迹，自动开下轮 | 进程退出 = 对话结束（runner 检测 504/429）；按轨迹 `session_meta.payload.cwd` 归属 A/B，取 `session_id`、`turn_id` 校验轮次，复制轨迹；队列循环自动接下一任务 |
| 3 | 产物推送到 GitHub | 轨迹 push 任务仓库 main；产物快照 commit 推 `<task>-a/-b` 分支，父提交 = 初始快照；远端 SHA 校验 |

## 目录结构

```
gsb-batch.ps1                 主脚本（队列 → A/B 跑 → 采集 → 自动下一任务；UTF-8 BOM / PS5.1）
gsb-runner.ps1                配套运行包装（504/429 检测与重试，勿改）
gsb-batch-调试记录.md           调试过程记录（最重要交付物：D1~D10 + 真实跑批 §8 记录）
GSB跑批操作指引.md              一步步操作教程（适配 DeepSeek）
batch-queue.example.json       队列格式模板
gsb-task-007-prompt.md         五子棋任务 prompt 示例
skills/gsb-batch/SKILL.md      agent 技能说明（已安装到用户 skills 目录）
```

## 环境要求（已在本机配置）

- codex CLI 0.155.1（Windows PowerShell 5.1）
- DeepSeek API key（`DEEPSEEK_API_KEY` 环境变量），跑批链已适配 provider=deepseek / model=deepseek-flash
- 原领题平台 relay（super_relay）作为回退保留，配置方式见调试记录 §8.1

## 快速开始

```powershell
# 1) 建任务目录并放提示词（如 D:\gsb\gsb-task-008\prompt.md）

# 2) 初始化初始快照
cd D:\gsb\gsb-task-008
git init && git add -A && git commit -m "initial snapshot"

# 3) 编辑队列 D:\gsb\batch-queue.json（格式见 batch-queue.example.json）

# 4) 跑批（全自动，无人值守）
powershell -ExecutionPolicy Bypass -File D:\gsb\gsb-batch.ps1 -QueueFile D:\gsb\batch-queue.json

# 5) 结果：D:\gsb\batch-results.json（sessionid）+ 任务目录 rollouts\ 下轨迹
```

## 验证

- gsb-task-007（五子棋人机对战）真实跑批：A/B 轮次均 = 1，sessionid 与轨迹完整采集（调试记录 §8.3）
- GitHub 推送闭环：`Rrr119/gsb-task-007`，main（轨迹）+ `-a`/`-b` 分支（产物快照），远端 SHA 与本地一致（§8.4）

> 说明：文中出现的 API key 仅为部分展示或占位，实际 key 通过环境变量注入，本仓库不含任何真实密钥。
