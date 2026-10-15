---
name: gsb-batch
description: Pair-wise GSB 项目批量跑批：自动调起 codexr CLI 对队列中的每个任务跑 A/B 两轮、自动输入提示词、检测对话结束、采集 sessionid 与轨迹文件、推送到 GitHub，任务完成后自动开启下一任务的两轮。用户要求"跑批/批量跑 GSB/自动跑 A B 两轮/采集 sessionid 轨迹/推送产物到 GitHub"时使用；也用于采集调试（-SkipRun）。
---

# GSB Batch Runner（Pair-wise GSB 批量跑批）

## 触发场景

- 用户给出多个 GSB 任务的提示词/队列，要求自动跑 A/B 两轮并采集 sessionid + 轨迹。
- 用户要求"任务执行完自动开下一轮/下两轮/跑完整批"。
- 用户要求把轨迹/产物推到自己的 GitHub（**Rrr119** 账号，任务仓库已设为 public）。

## 前置条件（一次性的，已就绪）

- `codexr` 可用（`C:\Users\PC\.codex-cli\.codex\bin\codexr.cmd`，隔离 CODEX_HOME + **DeepSeek provider**）。
- **模型 Provider（DeepSeek）**：隔离配置 `C:\Users\PC\.codex-cli\.codex\config.toml` 使用 `model=deepseek-flash`、`model_provider=deepseek`；API key 在系统环境变量 `DEEPSEEK_API_KEY`（或主配置 `C:\Users\PC\.codex\config.toml` 的 `[model_providers.deepseek].experimental_bearer_token`）。脚本启动预检为 **DeepSeek 优先**（`api.deepseek.com/v1/models` 返回 HTTP 200 即通过），super_relay 作为回退保留。
- 队列中每个任务需已初始化：`D:\gsb\<task>\` 是 git 仓库、根提交为初始环境快照、`prompt.md` 为提示词原文、可选 `origin`（GitHub 仓库，**gh 已登录 `Rrr119`**）。
- 工作区 `D:\gsb\<task>-workspace-a/b` 可自动创建/补配 origin。

## 核心脚本

`D:\gsb\gsb-batch.ps1`（PowerShell，UTF-8 BOM，PS5.1 兼容）
队列文件：`D:\gsb\batch-queue.json`（格式见 `D:\gsb\batch-queue.example.json`）

## 使用

```powershell
# 标准跑批（预检 DeepSeek → 逐任务 A/B 跑 → 采集 → 轨迹推 main → 自动下一任务）
powershell -ExecutionPolicy Bypass -File D:\gsb\gsb-batch.ps1 -QueueFile D:\gsb\batch-queue.json

# 同时推送产物快照分支（需求3；队列任务可单独开关 push_artifacts）
powershell -ExecutionPolicy Bypass -File D:\gsb\gsb-batch.ps1 -QueueFile D:\gsb\batch-queue.json -PushArtifacts

# 只跑单个任务
powershell -ExecutionPolicy Bypass -File D:\gsb\gsb-batch.ps1 -QueueFile D:\gsb\batch-queue.json -TaskFilter gsb-task-007

# 采集调试：跳过 CLI 运行，仅对已有轨迹做采集/校验（不消耗模型配额）
powershell -ExecutionPolicy Bypass -File D:\gsb\gsb-batch.ps1 -QueueFile D:\gsb\batch-queue.json -SkipRun -SkipPreflight -TaskFilter gsb-task-007
```

## 每任务流程（自动衔接下一任务）

1. 解析队列 → 取任务根提交作为初始快照（`git rev-list --max-parents=0 HEAD`）。
2. 确保工作区 a/b 存在（缺则从任务根复制并建分支 `<task>-a/-b`，补配 origin）。
3. A 轮：`gsb-runner.ps1` 调起 `codexr exec`（提示词经 stdin 自动输入，会话只有提示词），退出即"对话结束"；504/429 自动重置重跑。
4. 采集 A：按轨迹首行 `session_meta.payload.cwd` 归属工作区，取最新 `rollout-*.jsonl`，解析 `session_id`、`cli_version`、轮次（`response_item.payload.internal_chat_message_metadata_passthrough.turn_id` 去重，应=1），复制到 `rollouts\rollout-a.jsonl`。
5. B 轮与采集 B 同上。
6. 轨迹提交并推送 `main`，校验远端 SHA==本地 HEAD；输出 GitHub blob 链接。
7. 可选：`gsb-submit.ps1` 提交产物快照到分支并推送，校验远端分支 SHA。
8. 结果累计写入 `D:\gsb\batch-results.json`，然后自动开始下一任务。

## 关键设计点（调试结论，勿回退）

- 批量脚本 `$ErrorActionPreference = "Continue"`：PS5.1 下原生命令 stderr（如 git 的 LF/CRLF 警告）在 `Stop` 模式下会变成终止错误导致任务误判失败。
- 结束检测 = runner 退出码 + 日志无 504/429；**不能只看轨迹文件存在**（失败的调用也会写 session_meta + 轨迹）。
- `init_sha` 取任务仓库根提交，不能取 HEAD（轨迹提交会前进 HEAD）。
- 产物/轨迹推送后必须用 `git ls-remote` 校验远端 SHA；被复用的 `gsb-submit.ps1` 内部 `2>nul` 静默推送，可能推失败仍 exit 0。
- **超时检测正则必须精确匹配真实网络错误**（`504|Gateway Timeout|openai_error|Bad Gateway|stream idle timeout|request timed out|read timed out|operation timed out|connect timed out`），**不能含裸 `timeout`**：模型代码里的 `window.setTimeout(...)` 会被误判为超时，导致已跑完 15 分钟、51 个文件的产物被 reset 删除重跑。504 分支另加兜底：codex 已正常收尾（日志含 `tokens used`）且工作区有产物改动 → 保留产物视为完成。
- **账号一致性**：队列 `batch-queue.json` 的 `github_user`、gh 登录态（`gh auth status`）、origin URL、结果链接四处必须一致指向同一账号（本项目为 `Rrr119`），否则产物会推到别的账号。

## 常见问题

- 预检失败：DeepSeek 预检 HTTP≠200 → 检查 `DEEPSEEK_API_KEY` 是否有效（用 `api.deepseek.com/v1/models` 实测，不要测 relay 域名）；super_relay 回退仍 401 → relay key 失效。
- "任务根目录不存在" → 队列引用了未初始化的任务，先跑 gsb-init.ps1。
- 轨迹 raw 链接 404 → 仓库是私有的，未登录 GitHub 访问会 404，属正常；任务仓库按要求设为 public 后可直接访问，gh api 可确认文件存在。
- 产物出现在别的账号 → 检查 `gh auth status` 登录账号、`batch-queue.json` 的 `github_user`、origin URL 是否都指向同一账号。
- 冒烟测试产物：`D:\gsb\gsb-smoke-01`（含历史验证仓库 `736242160/gsb-smoke-01`，属旧账号遗留，仅验证用），可删除；正式数据用 `gsb-task-00X` 流程初始化后再入队。
