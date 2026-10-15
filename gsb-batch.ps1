<#
.SYNOPSIS
  GSB Pair-wise 批量自动跑批脚本（对应作业要求 1/2/3）
  队列读取 -> 每个任务自动调起 codexr CLI 跑 A/B 两轮（提示词经 stdin 自动输入）
  -> 检测对话结束 -> 自动采集两轮 sessionid + 轨迹文件
  -> 推送到 GitHub（轨迹 push main；产物快照 push 分支，可选）
  -> 任务完成后自动开启队列中下一个任务的两轮

.USAGE
  .\gsb-batch.ps1 -QueueFile "D:\gsb\batch-queue.json" [-PushArtifacts] [-TaskFilter <task>]
.EXAMPLE
  .\gsb-batch.ps1                                  # 使用默认队列文件
  .\gsb-batch.ps1 -PushArtifacts                   # 同时推送产物快照分支
  .\gsb-batch.ps1 -TaskFilter gsb-smoke-01 -SkipRun  # 跳过运行，仅按已有轨迹做采集（调试/重试）
.NOTES
  依赖：D:\gsb\gsb-runner.ps1（单侧运行+结束检测+504/429 重试）、D:\gsb\gsb-submit.ps1（产物提交推送）
         codexr（codex 隔离包装，C:\Users\PC\.codex-cli\.codex\bin\codexr.cmd）
  队列 JSON 示例见 D:\gsb\batch-queue.example.json
#>
param(
  [string]$QueueFile = "D:\gsb\batch-queue.json",
  [string]$GithubUser = "Rrr119",
  [string]$TaskFilter = "",
  [switch]$PushArtifacts,     # 全局开启产物快照推送（队列里也可按任务覆盖）
  [switch]$SkipRun,           # 调试：不调起 CLI，只对已有轨迹做采集
  [switch]$NoRolloutPush,     # 调试：不把轨迹 push 到 GitHub main
  [int]$MaxRetries = 5,
  [string]$InitShaOverride = "",   # 调试：覆盖初始快照（默认取任务仓库根提交）
  [switch]$SkipPreflight          # 调试：跳过 relay 鉴权预检（配合 -SkipRun 使用）
)

# 注意：此处必须用 Continue 而非 Stop —— PS5.1 下原生命令（git/curl）写 stderr 时，
# EAP=Stop + 2>$null/2>&1 会把 LF/CRLF 这类警告变成终止错误，导致任务误判失败（调试中发现）。
# 关键失败靠显式检查（$LASTEXITCODE / Test-Path / HEAD 比对）+ 显式 throw 兜底。
$ErrorActionPreference = "Continue"
$runner = "D:\gsb\gsb-runner.ps1"
$submit = "D:\gsb\gsb-submit.ps1"
$sessRoot = "C:\Users\PC\.codex-cli\.codex\sessions"
$resultsFile = "D:\gsb\batch-results.json"
$logFile = "D:\gsb\gsb-batch.log"

# ---------- 日志 ----------
function Write-Log {
  param([string]$Msg, [string]$Color = "Gray")
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $line = "[$ts] $Msg"
  Add-Content -Path $logFile -Value $line -Encoding UTF8
  Write-Host $line -ForegroundColor $Color
}
function Write-Ok   { param([string]$M) Write-Log $M "Green" }
function Write-Warn { param([string]$M) Write-Log $M "Yellow" }
function Write-Err  { param([string]$M) Write-Log $M "Red" }

# relay 鉴权预检：key 失效时快速失败，避免整批白跑（调试发现 401 后新增）
function Test-RelayAuth {
  # 1) DeepSeek 模式优先（用户当前 codex 配置）：DEEPSEEK_API_KEY -> api.deepseek.com
  $dsKey = $env:DEEPSEEK_API_KEY
  if ($dsKey) {
    Write-Log "预检：检查 DeepSeek (api.deepseek.com/v1/models) 鉴权..."
    try { $code = curl.exe -s -o NUL -w "%{http_code}" --max-time 20 "https://api.deepseek.com/v1/models" -H "Authorization: Bearer $($dsKey.Trim())" 2>$null } catch { $code = "ERR" }
    if ($code -eq "200") { Write-Ok "DeepSeek 预检通过（HTTP 200）"; return $true }
    Write-Err "DeepSeek 预检失败：HTTP=$code（key 无效或额度不足）"
  }
  # 2) 回退：super_relay（gsb.zhihejob.cn + relay.env）
  $envFile = "C:\Users\PC\.codex-cli\relay.env"
  $key = ""
  if (Test-Path $envFile) {
    $envText = Get-Content $envFile -Raw -Encoding ASCII
    if ($envText -match 'SUPER_RELAY_KEY=([^\r\n]+)') { $key = $Matches[1].Trim().Trim('"') }
  }
  if (-not $key) { Write-Err "无可用 key（DEEPSEEK_API_KEY 与 relay.env 均无）"; return $false }
  Write-Log "预检：检查 https://gsb.zhihejob.cn/v1/models 鉴权..."
  try { $code = curl.exe -s -o NUL -w "%{http_code}" --max-time 20 "https://gsb.zhihejob.cn/v1/models" -H "Authorization: Bearer $key" 2>$null } catch { $code = "ERR" }
  if ($code -eq "200") { Write-Ok "relay 预检通过（HTTP 200）"; return $true }
  Write-Err "relay 预检失败：HTTP=$code（也请确认是否改用 DeepSeek 模式）"
  return $false
}

Write-Log "===== gsb-batch 启动  queue=$QueueFile  skipRun=$SkipRun  pushArtifacts=$PushArtifacts =====" "Cyan"

if (-not (Test-Path $QueueFile)) { Write-Err "队列文件不存在: $QueueFile"; exit 1 }
$queue = Get-Content $QueueFile -Raw -Encoding UTF8 | ConvertFrom-Json
if ($queue.github_user) { $GithubUser = $queue.github_user }
if ($queue.push_artifacts) { $PushArtifacts = $true }
$tasks = @($queue.tasks)
if ($tasks.Count -eq 0) { Write-Err "队列为空"; exit 1 }
if ($TaskFilter) { $tasks = @($tasks | Where-Object { $_.task -eq $TaskFilter }) }
if ($tasks.Count -eq 0) { Write-Err "TaskFilter 未匹配到任何任务: $TaskFilter"; exit 1 }

# 预检：真实运行前确认 relay 可用（-SkipRun 采集模式不需要模型，可跳过）
if (-not $SkipRun -and -not $SkipPreflight) {
  if (-not (Test-RelayAuth)) { Write-Err "预检未通过，中止整个批次（避免 A/B 反复重试白跑）"; exit 1 }
}

# ---------- 结果文件（断点续跑用） ----------
$results = @()
if (Test-Path $resultsFile) {
  try { $results = @((Get-Content $resultsFile -Raw -Encoding UTF8 | ConvertFrom-Json)) } catch { $results = @() }
}

# ---------- 工具函数 ----------
# 初始快照 = 任务仓库根提交（gsb-init.ps1 把初始快照作为首个提交；HEAD 会随轨迹提交前进，不能直接取 HEAD）
function Get-TaskRootSha {
  param([string]$Root)
  $sha = git -C $Root rev-list --max-parents=0 HEAD 2>$null | Select-Object -Last 1
  if (-not $sha) { throw "任务根目录 $Root 不是 git 仓库（请先完成初始快照提交）" }
  return $sha.Trim()
}

# 工作区不存在时，从任务根目录复制创建（物理隔离），并建分支 <task>-a/-b；已存在时补配 origin
function Ensure-Workspace {
  param([string]$TaskName, [string]$Side, [string]$Root, [string]$InitSha)
  $ws = "D:\gsb\$TaskName-workspace-$Side"
  if (Test-Path "$ws\.git") {
    $head = git -C $ws rev-parse HEAD 2>$null
    if ($head.Trim() -ne $InitSha) {
      Write-Warn "工作区 $ws HEAD($head) != 初始快照($InitSha)，将 reset 到初始快照"
      git -C $ws reset --hard $InitSha 2>$null | Out-Null
      git -C $ws clean -fd 2>$null | Out-Null
      $head2 = git -C $ws rev-parse HEAD 2>$null
      if ($head2.Trim() -ne $InitSha) { throw "工作区 $ws reset 到初始快照失败（HEAD=$($head2.Trim())）" }
    }
    # 补配 origin（手工复制等工作区可能没有；没有 origin 会导致产物 push 静默失败）
    $originUrl = git -C $Root remote get-url origin 2>$null
    if ($originUrl -and -not (git -C $ws remote 2>$null)) { git -C $ws remote add origin $originUrl }
    return $ws
  }
  Write-Log "创建工作区 $ws（从 $Root 复制）"
  Copy-Item -Recurse -Force $Root $ws
  git -C $ws checkout -q -b "$TaskName-$Side" 2>$null
  $originUrl = git -C $Root remote get-url origin 2>$null
  if ($originUrl -and -not (git -C $ws remote 2>$null)) { git -C $ws remote add origin $originUrl }
  $head = git -C $ws rev-parse HEAD 2>$null
  if ($head.Trim() -ne $InitSha) { throw "新工作区 $ws HEAD != 初始快照，中止" }
  Write-Ok "工作区 $ws 就绪  HEAD=$($head.Trim())"
  return $ws
}

# 按 cwd 归属找该侧最新轨迹文件（轮询等待写入落盘）
function Find-RolloutForSide {
  param([string]$TaskName, [string]$Side)
  $needle = "$TaskName-workspace-$Side"
  for ($i = 0; $i -lt 6; $i++) {
    $hit = Get-ChildItem $sessRoot -Recurse -Filter "rollout-*.jsonl" -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending |
      Where-Object {
        try { $m = Get-Content $_.FullName -TotalCount 1 -Encoding UTF8 | ConvertFrom-Json; $m.payload.cwd -like "*$needle*" } catch { $false }
      } | Select-Object -First 1
    if ($hit) { return $hit }
    if ($i -lt 5) { Write-Log "未找到 $needle 的轨迹，等待 5s（进程退出后文件可能未落盘）..."; Start-Sleep -Seconds 5 }
  }
  return $null
}

# 从轨迹解析 sessionid / 轮次 / 版本
function Get-SessionInfo {
  param([string]$RolloutPath)
  $meta = Get-Content $RolloutPath -TotalCount 1 -Encoding UTF8 | ConvertFrom-Json
  $sid = $meta.payload.session_id
  $ver = $meta.payload.cli_version
  $cwd = $meta.payload.cwd
  # 轮次：所有 response_item 的 internal_chat_message_metadata_passthrough.turn_id 去重
  $turnIds = @{}
  $userMsgs = 0
  Get-Content $RolloutPath -Encoding UTF8 | ForEach-Object {
    try { $o = $_ | ConvertFrom-Json } catch { return }
    if ($o.type -ne 'response_item') { return }
    $tid = $o.payload.internal_chat_message_metadata_passthrough.turn_id
    if ($tid) { $turnIds[$tid] = $true }
    if ($o.payload.type -eq 'message' -and $o.payload.role -eq 'user') { $userMsgs++ }
  }
  $turnCount = $turnIds.Count
  $method = "turn_id 去重"
  if ($turnCount -eq 0) { $turnCount = $userMsgs; $method = "user 消息数（无 turn_id 字段）" }
  return [PSCustomObject]@{ session_id = $sid; cli_version = $ver; cwd = $cwd; turn_count = $turnCount; turn_method = $method }
}

# 单侧运行（调起 codexr，自动输入提示词；结束检测在 runner 内：exit 0 + 无 504 + 轨迹落盘）
function Invoke-OneSide {
  param([string]$TaskName, [string]$Side, [string]$Workspace, [string]$InitSha, [string]$PromptFile)
  $tag = "任务 $TaskName / 第 $(if($Side -eq 'a'){'A'}else{'B'}) 轮"
  if ($SkipRun) { Write-Log "$tag [SkipRun] 跳过 CLI 运行，仅采集已有轨迹"; return $true }
  Write-Log "$tag 调起 codexr CLI（提示词经 stdin 自动输入）..."
  & $runner -Workspace $Workspace -InitSha $InitSha -PromptFile $PromptFile -MaxRetries $MaxRetries
  if ($LASTEXITCODE -ne 0) { Write-Err "$tag 运行失败（runner exit=$LASTEXITCODE）"; return $false }
  Write-Ok "$tag 对话结束（codex 正常退出）"
  return $true
}

# 单侧采集：定位轨迹、解析 sessionid、校验轮次、复制到 rollouts/
function Collect-OneSide {
  param([string]$TaskName, [string]$Side, [string]$RolloutsDir)
  $tag = "任务 $TaskName / 第 $(if($Side -eq 'a'){'A'}else{'B'}) 轮"
  $hit = Find-RolloutForSide -TaskName $TaskName -Side $Side
  if (-not $hit) { throw "$tag 未找到归属轨迹文件（对话结束但无轨迹 = 异常）" }
  $info = Get-SessionInfo -RolloutPath $hit.FullName
  if ($info.turn_count -ne 1) {
    Write-Warn "$tag 轮次校验异常：turn_count=$($info.turn_count)（$($info.turn_method)），正常应为 1（仅提示词一轮）"
  } else {
    Write-Ok "$tag 轮次校验通过：1 轮（$($info.turn_method)）"
  }
  $dest = "$RolloutsDir\rollout-$Side.jsonl"
  Copy-Item $hit.FullName $dest -Force
  Write-Ok "$tag 采集完成 session_id=$($info.session_id) 版本=$($info.cli_version) 轨迹→$dest"
  return [PSCustomObject]@{
    side = $Side
    session_id = $info.session_id
    cli_version = $info.cli_version
    turn_count = $info.turn_count
    rollout_src = $hit.FullName
    rollout_dest = $dest
  }
}

# 轨迹 push 到 GitHub main（校验远端 SHA == 本地 HEAD）
function Push-RolloutsToMain {
  param([string]$TaskName, [string]$Root)
  Set-Location $Root
  $origin = git remote 2>$null
  if (-not $origin) {
    Write-Warn "$TaskName 无 origin remote：轨迹已复制到 rollouts/，暂不提交；配置 origin 后重跑本任务即可推送"
    return $true
  }
  git add -A 2>$null | Out-Null
  $dirty = git status --porcelain 2>$null
  if (-not $dirty) { Write-Warn "$TaskName 轨迹无变更（可能已推送），跳过 push"; return $true }
  git commit -m "chore: rollout files rollout-a/b" 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { Write-Warn "$TaskName 轨迹 commit 失败（exit=$LASTEXITCODE）"; return $false }
  git push origin main 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { Write-Warn "$TaskName 轨迹 push 失败（exit=$LASTEXITCODE），稍后可重跑采集"; return $false }
  $local = git rev-parse HEAD
  $remote = git ls-remote origin refs/heads/main 2>$null
  if ($remote -match $local) { Write-Ok "$TaskName 轨迹已推送 main，远端 SHA 一致: $local" ; return $true }
  Write-Err "$TaskName 轨迹推送后远端 SHA 不一致（local=$local remote=$remote）"
  return $false
}

# 产物快照提交并推送（复用 gsb-submit.ps1：验证 + 父提交核验）
function Submit-Artifact {
  param([string]$TaskName, [string]$Side, [string]$InitSha, [string]$VerifyCmd)
  $ws = "D:\gsb\$TaskName-workspace-$Side"
  $tag = "任务 $TaskName / 第 $(if($Side -eq 'a'){'A'}else{'B'}) 轮产物"
  $dirty = git -C $ws status --porcelain 2>$null
  if (-not $dirty) { Write-Warn "$tag 工作区无改动，跳过产物提交（冒烟题常见）"; return $false }
  & $submit -TaskName $TaskName -Side $Side -InitSha $InitSha -VerifyCommand $VerifyCmd -GithubUser $GithubUser
  if ($LASTEXITCODE -ne 0) { Write-Err "$tag 提交推送失败"; return $false }
  # 校验远端分支确实有产物提交（gsb-submit.ps1 内部用 2>nul 静默 push，可能推失败但 exit 0）
  $localArt = git -C $ws rev-parse HEAD
  $remoteArt = git -C $ws ls-remote origin "refs/heads/$TaskName-$Side" 2>$null
  if ($remoteArt -notmatch $localArt) {
    Write-Err "$tag 远端分支校验失败：local=$localArt remote=[$remoteArt]（push 可能静默失败）"
    return $false
  }
  Write-Ok "$tag 已推送（远端 SHA 一致: $localArt）"
  return $true
}

# ---------- 主循环：自动开启下一任务的两轮 ----------
foreach ($t in $tasks) {
  $task = $t.task
  $promptFile = $t.prompt_file
  $verifyA = if ($t.verify_a) { $t.verify_a } else { "" }
  $verifyB = if ($t.verify_b) { $t.verify_b } else { "" }
  $pushThis = if ($null -ne $t.push_artifacts) { $t.push_artifacts } else { $PushArtifacts }

  Write-Log "`n========== [开始] $task ==========" "Cyan"
  $root = "D:\gsb\$task"
  if (-not (Test-Path $root)) { Write-Err "$task 任务根目录不存在: $root"; continue }
  if (-not (Test-Path $promptFile)) { Write-Err "$task 提示词文件不存在: $promptFile"; continue }
  $initSha = if ($InitShaOverride) { $InitShaOverride } else { Get-TaskRootSha $root }
  Write-Log "$task 初始快照=$initSha  提示词=$promptFile"
  $rolloutsDir = "$root\rollouts"
  New-Item -ItemType Directory -Force -Path $rolloutsDir | Out-Null

  $entry = [PSCustomObject]@{ task = $task; init_sha = $initSha; status = "failed"; sides = @(); links = @{} }
  try {
    # 1) 工作区就绪
    $wsA = Ensure-Workspace -TaskName $task -Side a -Root $root -InitSha $initSha
    $wsB = Ensure-Workspace -TaskName $task -Side b -Root $root -InitSha $initSha

    # 2) 跑 A -> 结束检测 -> 采集 A
    if (Invoke-OneSide -TaskName $task -Side a -Workspace $wsA -InitSha $initSha -PromptFile $promptFile) {
      $infoA = Collect-OneSide -TaskName $task -Side a -RolloutsDir $rolloutsDir
      $entry.sides += $infoA
    } else { continue }

    # 3) 跑 B -> 结束检测 -> 采集 B
    if (Invoke-OneSide -TaskName $task -Side b -Workspace $wsB -InitSha $initSha -PromptFile $promptFile) {
      $infoB = Collect-OneSide -TaskName $task -Side b -RolloutsDir $rolloutsDir
      $entry.sides += $infoB
    } else { continue }

    # 4) 轨迹推送 main（需求3 的一部分；GitHub 链接用于填写表格）
    if (-not $NoRolloutPush) {
      if (Push-RolloutsToMain -TaskName $task -Root $root) {
        $entry.links.rollout_a = "https://github.com/$GithubUser/$task/blob/main/rollouts/rollout-a.jsonl"
        $entry.links.rollout_b = "https://github.com/$GithubUser/$task/blob/main/rollouts/rollout-b.jsonl"
      }
    }

    # 5) 产物快照推送（需求3 可选）
    if ($pushThis) {
      $okA = Submit-Artifact -TaskName $task -Side a -InitSha $initSha -VerifyCmd $verifyA
      $okB = Submit-Artifact -TaskName $task -Side b -InitSha $initSha -VerifyCmd $verifyB
      $entry | Add-Member -NotePropertyName artifact_pushed -NotePropertyValue ($okA -and $okB) -Force
    }

    $entry.status = "ok"
    Write-Ok "`n========== [完成] $task  状态=ok =========="
  } catch {
    Write-Err "`n========== [失败] $task  $_ =========="
  }

  # 结果累计写盘（支持断点续跑）
  $results = @($results | Where-Object { $_.task -ne $task })
  $results += $entry
  $results | ConvertTo-Json -Depth 6 | Set-Content $resultsFile -Encoding UTF8
}

$okCount = @($results | Where-Object { $_.status -eq 'ok' }).Count
Write-Log "`n===== gsb-batch 结束：共 $($tasks.Count) 个任务，本批次完成 $okCount 个 =====" "Cyan"
