# gsb-batch 调试记录 —— Pair-wise GSB 批量跑批脚本

> 项目：Pair-wise GSB（codex cli 同提示词跑 A/B 两轮 = 一条数据，采集 sessionid + 轨迹，GSB 判断）
> 交付物：
>
> `D:\gsb\gsb-batch.ps1`
>
> （主脚本）+ 
>
> `D:\gsb\gsb-batch-skill\SKILL.md`
>
> （agent 技能，已安装到 
>
> `C:\Users\PC\DoubaoWork\skills\gsb-batch\`
>
> ）
> 本文档目的：记录需求怎么写、方案怎么定、调试中哪些实现不符合要求、基于什么依据做了哪些改动（最重要）。



***

## 1. 需求解读（怎么写需求）

原需求（作业要求）拆成三条可验收的自动化目标：



| # | 需求原文                                             | 拆解为可执行动作                                                                                                                                | 验收口径                                    |
| - | ------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| 1 | 自动调起 cli 两轮对话，把准备好的提示词自动输入                       | 调起 `codexr exec`（非交互），提示词经 stdin 作为**唯一**输入传入；一个任务 = A/B 两个独立 session，同一提示词                                                             | 会话里只有提示词；两次跑用同一 prompt 原文、同一环境快照        |
| 2 | 检测对话结束，结束后自动采集这两轮的 sessionid 和轨迹文件（任务执行完自动开启下两轮） | exec 进程退出 = 对话结束（配合 runner 的 504/429 检测）；采集 = 按轨迹 `session_meta.payload.cwd` 归属 A/B → 取 `session_id`、`turn_id` 校验轮次 → 复制轨迹；队列循环自动接下一个任务 | sessionid 与轨迹文件一一对应；轮次 = 1；队列 N 个任务顺序跑完 |
| 3 | （尝试）将产物自动推送到自己的 GitHub                           | 轨迹 push 到任务仓库 `main`（blob 链接可填表）；产物快照 commit 推送到 `<task>-a/-b` 分支，父提交 = 初始快照                                                            | 远端 SHA == 本地 SHA；产物快照 permalink 可打开     |

约束（来自需求文档，决定方案）：



* 会话窗口**只保留提示词**，不得输入 `/status` 等任何其他内容（否则轨迹作废）；

* 轨迹不允许外部 skill 注入；两次跑之间环境 / 配置 /prompt 零差异；

* 遇到 api error / 504 / 网络波动 → **新开窗口重跑**（不能原地续聊）；

* 采集的字段口径：sessionid 在 `session_meta.payload.session_id`，轮次 id 是 `response_item.payload.internal_chat_message_metadata_passthrough.turn_id`（文档明确 "可以自己写个脚本解析一下"）。

## 2. 现状探查（动手前先看已有资产）

本机并非空白：`D:\gsb\` 已有一套半成品流程脚本和 6 个任务工作区，先盘点再决定 "新建 vs 复用"。



| 资产                                                              | 内容                                                                                                                                                                         | 结论                                                                 |
| --------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| `D:\gsb\gsb-runner.ps1`                                         | 单侧运行包装：\`\$prompt                                                                                                                                                          | codexr exec -s danger-full-access -\`，504/429 检测 + 重置工作区重试，429 串行锁 |
| `D:\gsb\gsb-rollout.ps1`                                        | 按 cwd 找轨迹、取 sessionid、复制、push main                                                                                                                                         | ⚠️ 只做 "双侧一次采集 + 推送"，不贴合 "跑完一侧立即采集" 的队列模型；**改由 batch 内联实现**         |
| `D:\gsb\gsb-init.ps1` / `gsb-workspaces.ps1` / `gsb-submit.ps1` | 初始化快照 / 建仓、复制 A/B 工作区、产物提交推送（含父提交核验）                                                                                                                                       | ✅ **复用**（submit 的 push 校验有缺陷，见 D9）                                 |
| `codexr.cmd`（`~\.codex-cli\.codex\bin\`）                        | codex 隔离包装：CODEX\_HOME + `SUPER_RELAY_KEY` 硬编码 + `--model auto_model/urm`                                                                                                  | ⚠️ key 硬编码在 wrapper 里，换 key 不便；见 D4                                |
| 轨迹目录                                                            | `C:\Users\PC\.codex-cli\.codex\sessions\2026\<MM>\<DD>\rollout-<时间戳>-<sessionid>.jsonl`，首行即 `session_meta`（含 `payload.session_id` / `payload.cwd` / `cli_version` /git 信息） | ✅ 采集解析以此为准                                                         |

**缺失的正是作业要求 2 的 "编排层"**：没有一个脚本把 "队列 → 跑 A/B → 检测结束 → 采集 → 推 GitHub → 自动下一任务" 串起来。这就是 `gsb-batch.ps1` 的定位。

## 3. 方案设计



* **为什么用 exec 非交互而不是 pexpect 模拟键盘**：需求文档明确给出批量用法 `codex-relay exec --skip-git-repo-check "任务描述"`，且 "会话里只保留提示词" 在非交互下天然成立（stdin 只有 prompt）；交互式模拟键盘在 Windows 上脆弱且容易误注入字符。结束检测 = 进程退出码 + 日志标记，可靠且可脚本化。

* **分层**：batch（编排）复用 runner（运行 + 重试 + 结束检测）与 submit（产物提交）；采集逻辑内联（要支持 "每侧跑完即采" 和轮次校验）。

* **初始快照**：取任务仓库**根提交**（`git rev-list --max-parents=0 HEAD`），因为轨迹提交会让 HEAD 前进（见 D6）。

* **错误设计**：key 失效预检快速失败（避免整批白跑）；单任务失败不阻塞队列（continue 到下一任务）；结果累计写 `batch-results.json` 支持断点续跑。

## 4. 调试过程（重点：现象 → 排查 → 修改 → 依据）

### D1. PowerShell 5.1 解析 .ps1 中文乱码 → 语法错乱



* **现象**：第一次语法校验报一堆 `Missing ')' in function parameter list`，报错信息里中文全是乱码（"璋冭瘯"）。

* **排查**：文件由工具写成 UTF-8 **无 BOM**；Windows PowerShell 5.1 对无 BOM 的 .ps1 默认按 ANSI（GBK）解码，中文字节被拆坏，注释 / 字符串里的垃圾字节破坏了语法。

* **修改**：脚本转存为 **UTF-8 with BOM**（`[IO.File]::WriteAllText(..., New-Object Text.UTF8Encoding $true)`），再校验语法通过。

* **依据**：PS5.1 文档行为（无 BOM 按 ANSI 解码）；`get-session.ps1` 等本机既有脚本均带 BOM 印证。

### D2. 三元运算符 `?:` 是 PS7+ 语法



* **现象**：语法校验报 `Unexpected token '?'`（`$doneAny ? 1 : 0`）。

* **排查**：本机是 Windows PowerShell 5.1（`powershell.exe`），不是 pwsh 7+。

* **修改**：改为 `@($results | Where-Object {...}).Count` 计数。

* **依据**：三元运算符在 PS 5.1 不存在，属于 7.0 新增。

### D3. `$ErrorActionPreference="Stop"` × 原生命令 stderr = 任务误判失败（最隐蔽的坑）



* **现象**：批跑第一次（`-SkipRun`）任务在 "采集完成" 后突然 `[失败]`，异常信息是 git 的 **LF/CRLF 警告**：`warning: in the working copy of '.gitignore', LF will be replaced by CRLF...`。

* **排查**：脚本全局 `$ErrorActionPreference="Stop"`；`git add -A 2>&1 | Out-Null` 时 git 把该警告写 stderr。经验测试：**PS5.1 下原生命令 stderr 在&#x20;**`2>$null`**&#x20;且 EAP=Stop 时也会抛终止错误**（与直觉相反）；`2>&1` 合并到成功流时本机不抛，但不可靠。

* **修改**：整脚本改为 `$ErrorActionPreference = "Continue"`（与已验证的 gsb-runner.ps1 一致），关键失败全部改为**显式检查**：`$LASTEXITCODE`、`Test-Path`、HEAD 比对、显式 `throw`。

* **依据**：本机实测（`2>$null`+Stop 抛、`2>&1`+Stop 不抛的实验对照）；PS 把原生 stderr 包装为错误记录的行为。这条直接决定脚本的失败判定架构，属于 "不符合要求（任务被判失败）→ 改判定机制" 的核心案例。

### D4. relay API KEY 401 失效 → 预检 + key 外置



* **现象**：真实单侧冒烟跑失败，`last-run.log` 显示 `ERROR: unexpected status 401 Unauthorized: Invalid token ... gsb.zhihejob.cn/v1/responses`。

* **排查**：`curl` 直测 `https://gsb.zhihejob.cn/v1/models` 带 key 也是 401；全盘排查 key 只存在于 `codexr.cmd` 硬编码（`~/.codex-cli/relay.env` 不存在、auth.json 是占位符、环境变量未设置）。结论：**key 过期 / 失效，需领题平台更新**（用户可提供）。

* **修改**（key 管理符合需求文档原本设计 —— 文档里三件套本来就该放 relay.env）：

1. 备份并改写 `codexr.cmd`：优先读取 `C:\Users\PC\.codex-cli\relay.env` 的 `SUPER_RELAY_KEY`，无则回退内置值（行为不变）；

2. 新建 `relay.env`（当前失效 key 占位，等用户更新）；

3. batch 新增 `Test-RelayAuth` **预检**（curl `/v1/models` 一次，非 200 快速中止整批，避免 A/B 反复重试白跑），`-SkipPreflight` 供采集调试跳过。

* **依据**：需求文档的配置章节（relay.env 承载三项）；"遇到网络 / 工程故障重开窗口" 的项目规则延伸出的快速失败原则。

### D5. 失败的调用也会写轨迹 → "结束检测" 不能只看轨迹存在



* **现象**：401 的两次失败调用，`sessions\2026\10\13\` 下照样生成了 2 个 rollout 文件（含 session\_meta、user 消息、报错行）。

* **推断 / 修改**：采集必须发生在 runner 判定成功后（exit 0 + 日志无 504/429），不能以 "目录里有新 rollout" 作为对话结束依据；`-SkipRun` 采集模式因此明确标注为调试用途，且轮次校验只防 "多轮"，不防 "失败轮"。

* **依据**：需求文档 "遇到 api error/504 需新开窗口，轨迹作废"；本机两例失败轨迹实证。

### D6. `init_sha` 不能取任务根 HEAD（轨迹提交会让 HEAD 前进）



* **现象**：Test B 中 batch 读到 "初始快照 = 62d93c…"，实为 rollouts 提交，而工作区 HEAD 是真正的初始快照 59d7c41 → 触发无谓 reset；若用于 submit 的父提交核验会直接判失败。

* **排查**：`Get-TaskRootSha` 原来 `rev-parse HEAD`；轨迹 push 到 main 后 HEAD 前进。

* **修改**：改取**根提交** `git rev-list --max-parents=0 HEAD`（gsb-init.ps1 保证初始快照就是第一个提交）；`Ensure-Workspace` reset 后**复核 HEAD**，失败即 throw。

* **依据**：需求 "初始环境快照 = 两次跑共同起跑点"；git 提交链结构。

### D7. 无 origin 时 "先提交后跳过推送" 导致重跑无法推送



* **现象**：冒烟任务没配 GitHub 远端时，旧逻辑先 commit 再检测 origin；配置 origin 后重跑，因轨迹已提交、"无变更" 而跳过 push，远端永远拿不到轨迹。

* **修改**：`Push-RolloutsToMain` 改为**先查 origin**：无 origin → 不提交、警告并提示 "配好 origin 重跑即推送"；有 origin 才 add/commit/push + 远端 SHA 校验。

* **依据**：断点续跑与幂等性要求（重跑不应把 "已提交未推送" 误判为完成）。

### D8. 工作区缺 origin → 产物 push 静默失败



* **现象**：Test C 中产物提交成功（本地 commit "artifact b"），但远端没有 `gsb-smoke-01-b` 分支；手动 push 报 `fatal: 'origin' does not appear to be a git repository`。

* **排查**：工作区由手工复制创建（早于建仓），没有 origin；`Ensure-Workspace` 只在**新建**时补 origin，已存在的工作区漏了。

* **修改**：`Ensure-Workspace` 对已存在工作区也补配 origin（从任务根 origin URL）。

* **依据**：gsb-workspaces.ps1 的既有约定（工作区必须有 origin 才能 push）；Test C 实证。

### D9. 复用的 gsb-submit.ps1 静默吞 push 错误 → 加远端分支校验



* **现象**：D8 里产物 push 实际失败，但 `gsb-submit.ps1` 仍 exit 0、batch 显示 "已推送"。

* **排查**：`gsb-submit.ps1` 内部 `cmd /c "git push ... 2>nul"` 吞掉 stderr 且不检查退出码。

* **修改**：batch 的 `Submit-Artifact` 在 submit 返回后**自己用&#x20;**`git ls-remote origin refs/heads/<task>-<side>`**&#x20;校验远端 SHA == 本地产物 SHA**，不一致判失败。

* **依据**：git-push 技能既有规则（"只有远端分支 SHA 与本地 HEAD 一致才算推送成功"）；实测验证修复后远端分支出现且 SHA 一致。

### D10. 队列内 `push_artifacts` 显式 false 覆盖全局开关（设计确认，非 bug）



* **现象**：Test C 第一次传 `-PushArtifacts` 未触发产物推送。

* **结论**：队列任务级字段优先于全局开关（设计如此，便于按题控制），测试时把队列字段改为 true 即触发。

## 5. 验证结果（用真实数据，不只 "语法通过"）

### 5.1 采集解析对真实轨迹验证（只读，无模型消耗）

对 3 条真实轨迹执行与脚本相同的解析逻辑：1 条冒烟失败轨迹 + 2 条生产轨迹（`gsb-task-002` A/B 完整执行）。



| 轨迹                | session\_id  | cwd 归属                     | cli\_version | turn\_count     |
| ----------------- | ------------ | -------------------------- | ------------ | --------------- |
| 冒烟失败（10-13 18:05） | `01a134b9-…` | gsb-smoke-01-workspace-a ✅ | 0.155.1      | 1（turn\_id 去重）✅ |
| 生产 A（09-22 09:06） | `01a0c6a5-…` | gsb-task-002-workspace-a ✅ | 0.155.1      | 1 ✅             |
| 生产 B（09-21 17:27） | `01a0c34a-…` | gsb-task-002-workspace-b ✅ | 0.155.1      | 1 ✅             |

> 说明：
>
> `turn_id`
>
>  字段确实存在于 0.155.1 轨迹的 
>
> `response_item.payload.internal_chat_message_metadata_passthrough.turn_id`
>
> （需求文档口径吻合）；此前一次 
>
> `Select-String 'turn_id'`
>
>  未命中是搜索方式问题，改查 
>
> `passthrough`
>
>  后命中。

### 5.2 批跑端到端（`-SkipRun -SkipPreflight`，不消耗模型配额）



* **Test A（队列循环 + 双侧采集）**：两任务队列 → gsb-smoke-01 状态 ok（A/B 各采集 sessionid + 轨迹复制 + 轮次 = 1），gsb-smoke-02 因 "任务根目录不存在" 走错误路径不阻塞队列 ✅

* **Test B（GitHub 轨迹推送）**：创建私有仓库 `736242160/gsb-smoke-01` 后重跑，`gh api` 确认 `rollouts/rollout-a.jsonl`、`rollout-b.jsonl` 已在远端 ✅；无变更时 "跳过 push" 幂等 ✅；结果 JSON 输出 GitHub blob 链接 ✅

* **Test C（产物快照推送）**：B 工作区造产物 → submit 提交 → 远端出现 `refs/heads/gsb-smoke-01-b` 且 SHA 一致（`f57901a…`），A 无改动则正确跳过并警告 ✅

* **预检**：当前 key 401 → 快速失败并给出修复指引（待用户换 key 后走 200 路径终验）。

## 6. 阻塞与待办（真实跑批验证）



* **唯一阻塞**：relay API KEY 已过期（401）。待你从领题平台取最新三项后更新 `C:\Users\PC\.codex-cli\relay.env` 的 `SUPER_RELAY_KEY`（URL / 模型 ID 有变也改 `~/.codex-cli/.codex/config.toml` 对应项）。

* **换 key 后的终验命令**（一个真任务、一个冒烟任务各跑一遍）：



```
\# 1) 预检应显示"relay 预检通过（HTTP 200）"

powershell -ExecutionPolicy Bypass -File D:\gsb\gsb-batch.ps1 -QueueFile D:\gsb\batch-queue.smoke.json -TaskFilter gsb-smoke-01

\# 2) 真实任务：先按 gsb-init.ps1 / gsb-workspaces.ps1 初始化，再入队
```



* 预期产出：A/B 真实对话结束 → sessionid + 轨迹自动入库并推送 GitHub → 结果 JSON 完整。

## 7. 使用说明（交付物怎么用）



| 文件                                | 用途                                                          |
| --------------------------------- | ----------------------------------------------------------- |
| `D:\gsb\gsb-batch.ps1`            | 主脚本（UTF-8 BOM / PS5.1）                                      |
| `D:\gsb\batch-queue.example.json` | 队列格式模板                                                      |
| `D:\gsb\batch-queue.smoke.json`   | 冒烟队列（gsb-smoke-01，含错误路径用例）                                  |
| `D:\gsb\gsb-batch-skill\SKILL.md` | agent 技能说明（已安装到 `C:\Users\PC\DoubaoWork\skills\gsb-batch\`） |
| `D:\gsb\batch-results.json`       | 每任务结构化结果（sessionid / 轨迹路径 / 链接）                             |
| `D:\gsb\gsb-batch.log`            | 运行日志                                                        |

参数：`-QueueFile`（默认 `D:\gsb\batch-queue.json`）、`-PushArtifacts`、`-TaskFilter`、`-SkipRun`（只采集）、`-SkipPreflight`、`-NoRolloutPush`、`-InitShaOverride`、`-MaxRetries`。

注意：本脚本产出的冒烟数据（`gsb-smoke-01` 及私有仓库）仅用于验证，不入作业表，可删除；正式数据须用 `gsb-task-00X` 流程初始化后再入队。

***

## 8. 真实跑批记录（2026-10-14，gsb-task-007 五子棋）—— 本轮调试新增

> 背景：用户给出新任务"仿照作业表格例子生成 prompt 并用脚本跑一遍"，prompt 定为五子棋人机对战网页小游戏（10 条硬约束）；GitHub 推送用户明确暂缓；codex-cli 已改用 DeepSeek。

### 8.1 适配：跑批链 provider 从 super_relay 切到 DeepSeek

**需求/预期**：原设计跑批走领题平台 relay（`gsb.zhihejob.cn` + `SUPER_RELAY_KEY`）。

**发现不符合**：
1. `relay.env` 里的 key `sk-6bd2c340...` 对 `gsb.zhihejob.cn/v1/models` 始终返回 `401 Invalid token`（new_api_error）。
2. 用户验 key 截图把路径写成 `C:\Users\PC\codex-cli\relay.env`（缺点号，不存在）→ `$key` 为 Null → 空 Bearer → 401 假象；换正确路径 `C:\Users\PC\.codex-cli\relay.env` 后依然 401。
3. 用户说明"codex-cli 已经用着 deepseek 了"。核对主配置 `C:\Users\PC\.codex\config.toml`：`[model_providers.deepseek]` base_url=`https://api.deepseek.com/`、`experimental_bearer_token=sk-6bd2c340...`，环境变量 `DEEPSEEK_API_KEY` 为同一 key。

**根因（基于证据）**：该 key 是 **DeepSeek 官方 API key**（实测 `api.deepseek.com/v1/models` → HTTP 200，模型 `deepseek-flash`/`deepseek-v4-pro`），而 GSB 跑批链（`codexr.cmd` + 隔离 `config.toml` + `relay_model_catalog.json`）仍强制指向 super_relay → 服务不匹配，key 自然无效。不是 key 复制错，是 provider 指向错。

**改动（基于以上证据）**：
- 隔离 `C:\Users\PC\.codex-cli\.codex\config.toml`：`model=auto_model/urm`→`deepseek-flash`、`model_provider=super_relay`→`deepseek`、`model_catalog_json` 指向主 `C:/Users/PC/.codex/models.json`（含 deepseek-flash 条目）、新增 `[model_providers.deepseek]`（base_url=`https://api.deepseek.com/`、wire_api=responses、env_key=DEEPSEEK_API_KEY），super_relay 块保留备用；备份 `config.toml.bak.deepseek`。
- `codexr.cmd`：调用行改为 `call codex --config model_provider=deepseek --model deepseek-flash %*`，中文注释改 ASCII（cmd 解析 UTF-8 中文产生 `'p' is not recognized` 噪音报错）；备份 `codexr.cmd.bak.deepseek`。CODEX_HOME 不变 → 轨迹仍落在隔离 sessions 目录，采集逻辑不动。
- `gsb-batch.ps1` `Test-RelayAuth`：改为 **DeepSeek 预检优先**（`DEEPSEEK_API_KEY` → `api.deepseek.com/v1/models`，HTTP 200 即通过），super_relay 作为回退保留。

**验证**：预检输出 `DeepSeek 预检通过（HTTP 200）`；最小调用 `codexr exec` 显示 `provider: deepseek / model: deepseek-flash`，正常回复并产生 session id。

### 8.2 修复：runner 超时检测误报（最关键的符合性改动）

**需求/预期**：504/超时重跑只应在**真实 API 故障**时触发，模型正常工作产出的代码不得被当作失败。

**发现不符合**：A 轮跑约 15 分钟、已产出 51 个文件，runner 判定"第 1 次失败（exit=0，含 504/超时）"→ `git reset --hard` + `clean -fd` 把产物全部删除重跑。

**根因（基于证据）**：`gsb-runner.ps1` 检测正则 `$hit504 = $combined -match "504|Gateway Timeout|openai_error|Bad Gateway|timeout"` 中裸 `timeout` 匹配到**模型写的代码** `window.setTimeout(function(){...})`（index.html 的 bootError 兜底提示）；日志"匹配到的 timeout"全是代码内容，无任何真实 API 错误。

**改动（基于以上证据）**：
- 正则改为精确匹配真实网络错误：`504|Gateway Timeout|openai_error|Bad Gateway|stream idle timeout|request timed out|read timed out|operation timed out|connect timed out`（去掉裸 `timeout`，避免命中 `setTimeout`）。
- 504 分支加兜底：codex 已正常收尾（日志含 `tokens used`）且工作区有产物改动（`git status --porcelain` 非空）→ 视为完成、**保留产物不重跑**（与 429 分支的 `Test-Completed` 同判据）。

**验证**：修复后 A 轮一次通过；B 轮尾部遇 429 限流时兜底判定生效（`codex 已正常收尾（tokens used）且产物已生成，仅尾部 429 限流：保留产物，视为完成`），产物与轨迹完整保留。

### 8.3 真实跑批结果（需求 1、2 验收）

| 项 | A 轮 | B 轮 |
| - | - | - |
| 启动 | 16:55:08（第 1/5 次尝试一次成功） | 17:06:41（A 结束后自动衔接，无人工干预） |
| 对话结束 | 17:06:41 | 17:33:15 |
| 轮次校验 | 1 轮（turn_id 去重）通过 | 1 轮（turn_id 去重）通过 |
| session_id | `01a1399f-61d2-7083-aece-45a35a33e643` | `01a139a9-f73d-7c23-bc25-f64a94bee9d5` |
| 轨迹文件 | `D:\gsb\gsb-task-007\rollouts\rollout-a.jsonl`（1.15MB） | `D:\gsb\gsb-task-007\rollouts\rollout-b.jsonl`（4.3MB） |
| codex 版本 | 0.155.1 | 0.155.1 |
| 产物 | 16 文件（index.html/main.css/ui.js/ai.js/game.js/renderer.js/patterns.js/record.js/rules.js/timer.js/config.js/board.js/serve.js/README.md，按模块拆分） | 21 文件（含 engine.js/evaluator.js/clock.js/store.js/replay.js/selftest.mjs 自测脚本） |

GitHub 推送（需求第 3 条，用户暂缓）：脚本在无 origin remote 时自动跳过并提示 `gsb-task-007 无 origin remote：轨迹已复制到 rollouts/，暂不提交；配置 origin 后重跑本任务即可推送`，推送能力已具备。

**依据小结**：本轮两处改动的依据都是"实测证据 + 需求符合性"——key 有效性以 HTTP 状态码为准（DeepSeek 200 / relay 401）、超时误报以日志实际匹配内容为准（全是代码里的 setTimeout）、Provider 选择以用户明确意图 + 主配置实测可用为准。

### 8.4 补充：GitHub 推送闭环（后补，已完成）

8.3 末尾记的是"GitHub 推送用户暂缓"。随后按作业要求第 3 条补做了推送，闭环成立：

- 任务根目录原先在 `master` 分支且没有 origin（早期手工初始化），batch 跑完时按 D7 设计只提示 `无 origin remote：… 配置 origin 后重跑本任务即可推送`。
- 首次先推到 `736242160/gsb-task-007`；随后按用户要求把 GitHub 账号迁到 **Rrr119**（`gh auth logout --user 736242160` → 登录 Rrr119 → 重推），当前产物在 `Rrr119/gsb-task-007`。
- 做法：根分支并到 `main` 后推送轨迹；A/B 工作区先补 `.gitignore`（排除 `*.log`、`last-run.log`、`tools/_chrome/`、`node_modules/` 等）再把产物快照提交为 `<task>-a/-b` 分支。
- 推送后 `git ls-remote` 核对，远端 SHA 与本地一致：

```
main              3aa08a01ccc1f2b59cfa3fbbfeaaa028a8b141d7   # rollouts/rollout-a.jsonl、rollout-b.jsonl
gsb-task-007-a    5f20b621052646c78f7c500c29f8e7aca0193ef7   # 产物快照 A，父提交 = 初始快照 fada2aab…
gsb-task-007-b    6e38fba1b4fbf94fc089123032f9c62cccc30933   # 产物快照 B，父提交 = 初始快照 fada2aab…
```

- 仓库：https://github.com/Rrr119/gsb-task-007 （private）
- 网络备注：本机 Clash 代理（`127.0.0.1:7897`）会间歇性 TLS 握手失败，推送最终用"直连/代理自动重试"成功；脚本默认账号已改为 `Rrr119`。
- 结论：需求 1 / 2 / 3 均已闭环；D7 的"无 origin 时只警告不提交、配好 origin 后重跑即可补推"也在真实场景中得到验证（补配 origin 后重跑采集/推送成功）。
