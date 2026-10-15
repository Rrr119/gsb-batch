# GSB 跑批操作指引（适配 DeepSeek 版）

> 配套文件（都在桌面）：
> - `gsb-batch.ps1` — 主脚本（队列→A/B 跑→采集→自动下一任务）
> - `gsb-runner.ps1` — 配套运行包装（504/429 重试，勿改）
> - `gsb-batch-调试记录.md` — 调试记录（最重要的交付物）
> - `gsb-task-007-prompt.md` — 五子棋任务 prompt 示例

---

## 0. 一键速查：我要做什么？

| 想做的事 | 看哪节 |
| - | - |
| 第一次用，确认环境 OK | §1 环境检查（一次性） |
| 跑一个新任务（A/B 两轮） | §2 新任务完整流程 |
| 只采集已有的轨迹（不耗配额） | §3 调试模式 |
| 推送到 GitHub | §4 配置 GitHub |
| 报错了 | §5 常见问题 |

---

## 1. 环境检查（一次性，本机已配好，确认即可）

打开 PowerShell，依次执行：

```powershell
codex --version          # 应显示 0.155.1
$env:DEEPSEEK_API_KEY    # 应显示 sk-6bd2c340...（已写入系统环境变量）
```

确认两个关键配置（**不要改动**）：
- 隔离配置 `C:\Users\PC\.codex-cli\.codex\config.toml` → provider=deepseek、model=deepseek-flash
- `codexr.cmd` → 调用行 `call codex --config model_provider=deepseek --model deepseek-flash %*`

> 备注：原 GSB 需求走领题平台 relay（gsb.zhihejob.cn），但你的 key 是 DeepSeek 官方 key（实测 api.deepseek.com HTTP 200），已整体切换到 DeepSeek 模式。若日后领题平台给了有效 relay key，改回方式见调试记录 §8.1。

---

## 2. 新任务完整流程（跑 A/B 两轮 + 自动采集）

### 第 1 步：准备任务目录和提示词

```powershell
mkdir D:\gsb\gsb-task-008      # 任务名自取，格式 gsb-task-XXX
# 把要跑的 prompt 存成（用记事本/WPS 编辑，UTF-8 保存）：
#   D:\gsb\gsb-task-008\prompt.md
```

### 第 2 步：初始化任务（打初始快照）

```powershell
cd D:\gsb\gsb-task-008
git init
git add -A
git commit -m "initial snapshot"
git rev-list --max-parents=0 HEAD     # 记下这串 SHA，它就是"初始环境快照"
```

### 第 3 步：编辑队列文件 `D:\gsb\batch-queue.json`

用记事本打开，改成（一个任务一条，可放多个任务顺序跑）：

```json
{
  "github_user": "Rrr119",
  "push_artifacts": false,
  "tasks": [
    {
      "task": "gsb-task-008",
      "prompt_file": "D:\\gsb\\gsb-task-008\\prompt.md",
      "push_artifacts": false
    }
  ]
}
```

### 第 4 步：跑！

```powershell
powershell -ExecutionPolicy Bypass -File D:\gsb\gsb-batch.ps1 -QueueFile D:\gsb\batch-queue.json
```

脚本自动完成（无需任何人工操作）：
1. 预检 DeepSeek key（HTTP 200 才继续）
2. 创建 A/B 两个工作区（同一初始快照）
3. **A 轮**：调起 codex CLI，prompt 经 stdin 自动输入
4. 检测 A 轮对话结束 → **自动采集 sessionid + 轨迹** → **自动开 B 轮**
5. B 轮同上
6. 写结果

### 第 5 步：看结果

| 看什么 | 位置 |
| - | - |
| A/B 轨迹文件 | `D:\gsb\gsb-task-008\rollouts\rollout-a.jsonl` / `rollout-b.jsonl` |
| sessionid + 校验结果 | `D:\gsb\batch-results.json` |
| A 轮代码产物 | `D:\gsb\gsb-task-008-workspace-a\` |
| B 轮代码产物 | `D:\gsb\gsb-task-008-workspace-b\` |
| 运行日志 | `D:\gsb\gsb-batch.log`（每轮详细日志在各自工作区 `last-run.log`） |

---

## 3. 调试模式（不耗模型配额）

已有轨迹、只想测采集/不跑模型时：

```powershell
powershell -ExecutionPolicy Bypass -File D:\gsb\gsb-batch.ps1 -QueueFile D:\gsb\batch-queue.json -SkipRun -SkipPreflight
```

- `-SkipRun`：不调模型，只按已有轨迹采集
- `-SkipPreflight`：跳过 key 预检

---

## 4. 配置 GitHub 推送（需求第 3 条，可选）

1. 在 GitHub（你的账号 Rrr119）新建**空仓库**，如 `gsb-task-008`
2. 给任务仓库配远端：

```powershell
cd D:\gsb\gsb-task-008
git remote add origin https://github.com/Rrr119/gsb-task-008.git
```

3. 队列里改 `"push_artifacts": true`、`"github_user": "Rrr119"`
4. 重新跑该任务 → 轨迹推到 main（blob 链接可填表），产物快照推到 `-a`/`-b` 分支

> 推送失败排查：`gh auth status` 确认登录的是 Rrr119（本机早期 gh 登录过 736242160，注意切换）。

---

## 5. 常见问题

| 现象 | 处理 |
| - | - |
| 预检 401 | 检查 `$env:DEEPSEEK_API_KEY`；手动验证：`curl.exe -s https://api.deepseek.com/v1/models -H "Authorization: Bearer $env:DEEPSEEK_API_KEY"` |
| A/B 轮报 504/超时 | 脚本自动重置重跑，最多 5 次；真重试后仍失败看 `last-run.log` 尾部 |
| 结果里 GitHub 链接打不开 | 占位链接（未配 origin/未推送），配好远端重跑才有真链接 |
| 想换模型 | 改 `codexr.cmd` 的 `--model` 和隔离 config 的 `model`/`model_catalog_json`（当前 deepseek-flash 可用；`deepseek-v4-pro` 也可） |
| 队列跑一半中断 | 结果已写入 `batch-results.json`，直接重跑命令即可断点续跑（已完成任务幂等跳过） |
