<#
.SYNOPSIS
  GSB 自动重连跑批包装器：遇 504/openai_error 自动重置工作区并重跑，最多重试 N 次。
  429 限流处理：提示"建议暂停约 1 分钟"并退避 60 秒；限流后 A/B 的重试通过全局锁串行，
  避免并发请求加剧限流；若 codex 已正常收尾（日志含 tokens used）且工作区已生成产物，
  视为任务已完成（仅尾部 429），保留产物直接退出，不再重置重跑。
.USAGE
  .\gsb-runner.ps1 -Workspace "D:\gsb\<TASK>-workspace-a" -InitSha "<初始快照SHA>" -PromptFile "D:\gsb\<TASK>\prompt.md" [-MaxRetries 5]
#>
param(
  [Parameter(Mandatory = $true)][string]$Workspace,
  [Parameter(Mandatory = $true)][string]$InitSha,
  [Parameter(Mandatory = $true)][string]$PromptFile,
  [int]$MaxRetries = 5,
  [int]$RetryDelaySec = 8,
  [int]$RateLimitDelaySec = 60
)

$ErrorActionPreference = "Continue"
Set-Location $Workspace
$prompt = Get-Content $PromptFile -Raw -Encoding UTF8
$log = "$Workspace\last-run.log"

# 全局串行锁：429 限流后，A/B 的重试通过该锁串行，避免双方同时请求 API 加剧限流
$lockPath = "D:\gsb\.gsb-retry-lock"

function Acquire-Lock {
  for ($w = 0; $w -lt 24; $w++) {
    try {
      New-Item -ItemType File -Path $lockPath -ErrorAction Stop | Out-Null
      return $true
    } catch {
      Start-Sleep -Seconds 5
    }
  }
  Write-Host "===== 获取串行锁超时（2 分钟），继续重试（不再串行） =====" -ForegroundColor Yellow
  return $false
}

function Release-Lock {
  Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
}

# 清理过期锁（进程异常退出可能残留；超过 10 分钟视为过期）
if (Test-Path $lockPath) {
  $lockAgeMin = ((Get-Date) - (Get-Item $lockPath).LastWriteTime).TotalMinutes
  if ($lockAgeMin -gt 10) { Remove-Item $lockPath -Force -ErrorAction SilentlyContinue }
}

# 判定"任务已完成，仅尾部 429"：codex 会话正常收尾（tokens used）且工作区已有产物改动
function Test-Completed {
  param($LogPath)
  $c = Get-Content $LogPath -Raw -Encoding UTF8
  if ($c -notmatch "tokens used") { return $false }
  $dirty = git status --porcelain 2>$null
  if (-not $dirty) { return $false }
  return $true
}

$lockHeld = $false
for ($i = 1; $i -le $MaxRetries; $i++) {
  $modeTag = if ($lockHeld) { "[持锁-串行]" } else { "[并行]" }
  Write-Host "`n===== 第 $i / $MaxRetries 次尝试  $([DateTime]::Now.ToString('HH:mm:ss')) $modeTag ====="

  # 每次都干净起跑：重置到初始快照 + 清理未跟踪文件
  git reset --hard $InitSha 2>&1 | Out-Null
  git clean -fd 2>&1 | Out-Null

  # 非交互一次性执行：提示词经 stdin 传入（-），不进入交互循环。
  # 输出只写入日志文件（不回显到终端），保持 prompt 终端窗口纯净；
  # 429/504 检测均读取该日志文件，与终端完全独立。
  $prompt | codexr exec -s danger-full-access - 2>&1 | Out-File -FilePath $log -Encoding UTF8
  $exit = $LASTEXITCODE

  $combined = (Get-Content $log -Raw -Encoding UTF8)
  # D11 修复：裸 "timeout" 会把模型代码里的 setTimeout 误判为 API 超时（2026-10-14 五子棋任务实测误报）
  $hit504 = $combined -match "504|Gateway Timeout|openai_error|Bad Gateway|stream idle timeout|request timed out|read timed out|operation timed out|connect timed out"
  $hit429 = $combined -match "429"

  if ($exit -eq 0 -and -not $hit504) {
    Write-Host "`n===== 成功：codex 正常结束，无 504 =====" -ForegroundColor Green
    if ($lockHeld) { Release-Lock }
    exit 0
  }

  if ($hit429) {
    if (Test-Completed $log) {
      Write-Host "`n===== codex 已正常收尾（tokens used）且产物已生成，仅尾部 429 限流：保留产物，视为完成 =====" -ForegroundColor Green
      if ($lockHeld) { Release-Lock }
      exit 0
    }
    Write-Host "`n===== 第 $i 次失败：429 限流，建议暂停约 1 分钟；$RateLimitDelaySec 秒后重试 =====" -ForegroundColor Yellow
    if (-not $lockHeld) { $lockHeld = Acquire-Lock }
    Start-Sleep -Seconds $RateLimitDelaySec
  } else {
    # D11 兜底：即使日志含 504/超时字样，若 codex 已正常收尾（tokens used）且产物已生成，保留产物视为完成
    if (Test-Completed $log) {
      Write-Host "`n===== codex 已正常收尾（tokens used）且产物已生成：视为完成，保留产物 =====" -ForegroundColor Green
      if ($lockHeld) { Release-Lock }
      exit 0
    }
    Write-Host "`n===== 第 $i 次失败（exit=$exit，含 504/超时），$RetryDelaySec 秒后重置重跑 =====" -ForegroundColor Yellow
    if ($lockHeld) { Release-Lock; $lockHeld = $false }
    Start-Sleep -Seconds $RetryDelaySec
  }
}

if ($lockHeld) { Release-Lock }
Write-Host "`n===== 达到最大重试次数 $MaxRetries，仍失败，请人工检查 =====" -ForegroundColor Red
exit 1
