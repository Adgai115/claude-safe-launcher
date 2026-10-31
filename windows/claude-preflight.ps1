param(
  [switch]$Force,
  [switch]$NoPause,
  [switch]$NoLaunch,
  [switch]$Relearn,
  [switch]$TestMode,
  [switch]$DryRun,
  [switch]$FixEnv,
  [switch]$Yes,
  [switch]$UndoFix,
  [string]$UndoId,
  [switch]$ListFixes,
  [string[]]$FixVarPattern,
  [int]$FailAtIndex = 0,
  [switch]$ExportIssues,
  [switch]$HideIp,
  [switch]$ApplySettings,
  [ValidateSet('quick','full')][string]$CheckMode = 'quick',
  [string]$ResultPath,
  [string]$RunId
)
<#
  Claude 桌面版 只读检查 + 显式设置（v3.4.0）
  用法: powershell -NoProfile -ExecutionPolicy Bypass -File claude-preflight.ps1 [选项]
  -ApplySettings : 显式应用预设时区/节点；默认检查不修改系统设置
  -CheckMode quick|full : 快速检查（默认）或完整诊断
  -ResultPath / -RunId : 面板使用的完整结果文件与会话标识
  -Force    : 兼容保留；不会跳过风险阻断
  -NoPause  : 结束时不等待按键；单独使用时不提示也不自动修复
  -NoLaunch : 只检查，不启动/不切换 Claude，也不启动后台监控（测试用）
  -Relearn  : 忘掉记住的出口 IP / 节点 / 时区，按当前环境重新记住
  -FixVarPattern <通配符...> : 限定要检测/修复的用户级变量名（默认 ANTHROPIC_* 列表）
  -FixEnv   : 一键清除匹配的用户级中转变量；先列出变量名和动作（不显示值）并问 y/N，回答 y 才修改（v3.3.0 起）
  -Yes      : 配合 -FixEnv 跳过 y/N 确认，直接修复（脚本/无人值守用）
  -DryRun   : 只列出将要修改的变量名和动作，不写系统、不写备份
  -UndoFix [-UndoId <id>] : 撤销一次修复（默认最近一次）；冲突时 -NoPause 跳过并返回非 0
  -ListFixes : 列出可撤销操作（脱敏）
  -TestMode : 仅允许操作 CSL_TEST_ 前缀变量；测试请配合 -FixVarPattern 'CSL_TEST_ANTHROPIC_*'
  -FailAtIndex <n> : （仅 -TestMode）使第 n 个变量变更抛错，用于验证整单回滚；非 TestMode 警告并忽略
  -ExportIssues : 检查结束后打印可复制的「问题说明」（脱敏四段结构）；建议配合 -NoLaunch -NoPause
  -HideIp : 与 -ExportIssues 同用时，出口 IP / WebRTC IP 也脱敏，并省略 IP 提示行
  配置文件  : 同目录 preflight.json（可用 fixVarPatterns；controllerSecret 不会被打印）
  依赖      : 同目录 claude-common.ps1、claude-envfix.ps1、claude-issueexport.ps1、claude-monitor.ps1
#>
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'claude-common.ps1')
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'claude-envfix.ps1')
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'claude-issueexport.ps1')
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'claude-diagnostics.ps1')
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'claude-risk.ps1')
$ErrorActionPreference = 'Stop'
$script:CslAllowConfigWrite = [bool]($ApplySettings -or $Relearn)
$script:CslDeferConfigWrite = $true
$script:CslPendingLearned = @{}
$script:Stages = New-Object 'System.Collections.Generic.List[string]'
$script:CheckEvents = New-Object 'System.Collections.Generic.List[object]'
$script:RiskChecks = @{}
$script:LaunchBlocks = New-Object 'System.Collections.Generic.List[string]'
trap {
  Write-Host '  [失败] 检查异常中止，未完成全部项目。请重新检查。' -ForegroundColor Red
  try { Write-CslCheckReport -Path $ResultPath -RunId $RunId -Complete $false -Result 'ERROR' -Score $null -ExitCode 2 -Stages @($script:Stages.ToArray()) -Mode $CheckMode } catch {}
  try { Write-Log ('ERROR | incomplete | line=' + $_.InvocationInfo.ScriptLineNumber) } catch {}
  exit 2
}
if ($TestMode -and $ApplySettings) { throw '测试模式禁止应用系统设置' }
try { $Host.UI.RawUI.WindowTitle = 'Claude 安全启动 - 启动前检查' } catch {}
$cfg = Load-Config
if ($ApplySettings -and $Relearn) { throw '应用预设与重新记录环境必须分别执行' }
if ($ApplySettings -and (-not $cfg.timezone -or -not $cfg.expectedNode -or -not $cfg.expectedIp)) {
  throw '修复标准不完整，请先核对并记住正确的节点、出口和时区'
}
if ($Relearn) {
  $currentZone = (Get-TimeZone).Id
  Save-Learned $cfg @{ expectedIp = ''; expectedLoc = ''; expectedNode = ''; timezone = $currentZone; expectedTzIana = [string](Convert-WindowsToIana $currentZone) }
}

$script:DoUndoFix = [bool]$UndoFix
$script:UndoFixId = $(if ($UndoId) { $UndoId } else { $null })

$script:FixPatterns = Get-CslFixVarPatterns -Cfg $cfg -FixVarPattern $FixVarPattern
$script:EnvFixSettings = Get-CslEnvFixSettings $cfg

# 撤销冲突提示：跳过 $null / 空值（PS 5.1 下 @($null) 会产生一个 $null 元素）
function Get-CslUndoConflictMessages($Conflicts) {
  $out = @()
  foreach ($c in @($Conflicts)) {
    if ($null -eq $c) { continue }
    $msg = if ($c -is [string]) { $c } elseif ($c -is [System.Collections.IDictionary]) { if ($c.Contains('message') -and $c['message']) { [string]$c['message'] } else { [string]$c['name'] } } elseif ($c.PSObject.Properties['message']) { [string]$c.message } else { [string]$c }
    if ([string]::IsNullOrWhiteSpace($msg)) { continue }
    $out += $msg
  }
  return $out
}
function Write-CslUndoConflicts($Conflicts) {
  foreach ($m in @(Get-CslUndoConflictMessages $Conflicts)) { Write-Host ("  [警告] {0}" -f $m) -ForegroundColor Yellow }
}

# -ListFixes 输出：只列变量名和动作/状态，不出现任何值（打码也不行）
function Write-CslEnvFixList($List) {
  Write-Host '可撤销的环境变量修复（只列变量名和动作）:' -ForegroundColor Cyan
  $list = @($List | Where-Object { $null -ne $_ })
  if ($list.Count -eq 0) { Write-Host '  （无）' -ForegroundColor DarkGray }
  foreach ($it in $list) {
    $st = $(if ($it.corrupt) { "损坏（不会自动清理）: $($it.path)" } elseif ($it.undone) { '已撤销' } elseif ($it.partiallyUndone) { '部分已撤销（其余可撤销）' } else { '可撤销' })
    Write-Host ("  [{0}] {1}  {2}" -f $it.id, $it.ts, $st)
    foreach ($v in $it.vars) {
      Write-Host ("    - {0}: {1}（{2}）" -f $v.name, $v.action, $(if ($it.undone -or $v.undone) { '已撤销' } else { '可撤销' }))
    }
  }
}

# ----- CLI：列出 / 撤销 / 仅修复（可在完整检查前短路） -----
if ($ListFixes) {
  Write-CslEnvFixList @(Get-CslEnvFixList)
  if (-not $NoPause) { try { Read-Host '按回车退出' | Out-Null } catch {} }
  exit 0
}

if ($script:DoUndoFix) {
  Write-Host '撤销环境变量修复…' -ForegroundColor Cyan
  $undo = Invoke-CslEnvUndo -Id $script:UndoFixId -NoPause:$NoPause -TestMode:$TestMode -FailAtIndex $FailAtIndex
  if ($undo.alreadyUndone) {
    Write-Host ("  [信息] already undone（{0}）" -f $undo.id) -ForegroundColor Gray
  }
  if ($undo.restored) {
    foreach ($r in $undo.restored) { Write-Host ("  [修复] 已恢复 {0}" -f $r.name) -ForegroundColor Yellow }
  }
  Write-CslUndoConflicts $undo.conflicts
  if (-not $undo.ok -and $undo.error) { Write-Host ("  [失败] {0}" -f $undo.error) -ForegroundColor Red }
  if ($undo.hint) { Write-Host ("  [信息] {0}" -f $undo.hint) -ForegroundColor Gray }
  if (-not $NoPause) { try { Read-Host '按回车退出' | Out-Null } catch {} }
  exit $(if ($null -ne $undo.exitCode) { $undo.exitCode } else { 1 })
}

# 确认名单 / 预览：只显示变量名和动作，不显示值（含打码值）
function Write-CslEnvFixPlan($Plan) {
  foreach ($row in @($Plan)) {
    if ($null -eq $row) { continue }
    switch ([string]$row.action) {
      'skip-admin' { Write-Host ("  [提示] {0} 仅 Machine 级存在：需要管理员手动处理" -f $row.name) -ForegroundColor DarkGray }
      'keep'       { Write-Host ("  [信息] 保留 User {0}（envFixKeep）" -f $row.name) -ForegroundColor Gray }
      default      { Write-Host ("  [信息] 将清除 User {0}" -f $row.name) -ForegroundColor Gray }
    }
  }
}

if ($FixEnv) {
  Write-Host '一键修复用户级中转环境变量…' -ForegroundColor Cyan
  $pauseExit = { param($code) if (-not $NoPause) { try { Read-Host '按回车退出' | Out-Null } catch {} }; exit $code }
  if (-not $script:EnvFixSettings.enabled) {
    Write-Host '  [信息] 一键修复已在 preflight.json 关闭（envFixEnabled=false），未做任何修改' -ForegroundColor Gray
    & $pauseExit 1
  }
  $keep = @($script:EnvFixSettings.keep)
  if ($DryRun) { Write-Host '  [信息] DryRun：只预览，不修改' -ForegroundColor Gray }
  $preview = Invoke-CslEnvFix -Patterns $script:FixPatterns -TestMode:$TestMode -DryRun -Keep $keep
  if (-not $preview.ok) {
    Write-Host ("  [失败] {0}" -f $preview.error) -ForegroundColor Red
    & $pauseExit $(if ($null -ne $preview.exitCode) { $preview.exitCode } else { 1 })
  }
  Write-CslEnvFixPlan $preview.plan
  if ($DryRun) { & $pauseExit 0 }
  $removeCount = @(@($preview.plan) | Where-Object { $null -ne $_ -and $_.action -eq 'remove' }).Count
  if ($removeCount -eq 0) {
    Write-Host '  [信息] 没有可清除的用户级变量' -ForegroundColor Gray
    & $pauseExit 0
  }
  # v3.3.0 起 -FixEnv 先确认；-NoPause 也会问（读不到输入 = 不同意）。脚本请加 -Yes
  if (-not (Test-CslFixConfirmed -Yes:$Yes -ReadAnswer { Read-Host '  确认删除以上用户级变量？(y/N)' })) {
    Write-Host '  [信息] 已取消，未做任何修改（无人值守请加 -Yes）' -ForegroundColor Gray
    & $pauseExit 1
  }
  $fix = Invoke-CslEnvFix -Patterns $script:FixPatterns -TestMode:$TestMode -FailAtIndex $FailAtIndex -Keep $keep
  if (-not $fix.ok) {
    Write-Host ("  [失败] {0}" -f $fix.error) -ForegroundColor Red
    & $pauseExit $(if ($null -ne $fix.exitCode) { $fix.exitCode } else { 1 })
  }
  foreach ($a in @($fix.applied)) {
    if ($null -eq $a) { continue }
    Write-Host ("  [修复] 已删除用户级 {0}" -f $a.name) -ForegroundColor Yellow
  }
  if ($fix.id) { Write-Host ("  [信息] 备份 id={0}（可用 -UndoFix 撤销）" -f $fix.id) -ForegroundColor Gray }
  if ($fix.hint) { Write-Host ("  [信息] {0}" -f $fix.hint) -ForegroundColor Gray }
  & $pauseExit $(if ($null -ne $fix.exitCode) { $fix.exitCode } else { 0 })
}


# ---------- 输出与评分 ----------
# FAIL = 必须修（默认扣 25）  WARN = 建议修（默认扣 8）  NOTE = 不用管（0 分）
$script:Items = New-Object System.Collections.ArrayList
$script:CurrentHead = ''
$script:CslProgressSequence=0
$script:CslLastProgressUtc=[datetime]::MinValue
function Write-CslProgress([switch]$ForceWrite) {
  if(-not $ResultPath -or (-not $ForceWrite -and ([datetime]::UtcNow-$script:CslLastProgressUtc).TotalMilliseconds -lt 150)){return}
  $path=$ResultPath+'.progress.json';$temp=$path+'.tmp'
  try{
    $script:CslProgressSequence++
    $snapshot=@{schemaVersion=2;runId=$RunId;complete=$false;sequence=$script:CslProgressSequence;timestampUtc=[datetime]::UtcNow.ToString('o');stages=@($script:Stages.ToArray());events=@($script:CheckEvents.ToArray());assessmentVersion=1;assessment=(Get-CslCheckAssessment @($script:CheckEvents.ToArray()))}
    [IO.File]::WriteAllText($temp,($snapshot|ConvertTo-Json -Depth 9),[Text.UTF8Encoding]::new($false))
    if(Test-Path -LiteralPath $path){[IO.File]::Replace($temp,$path,[NullString]::Value)}else{[IO.File]::Move($temp,$path)}
    $script:CslLastProgressUtc=[datetime]::UtcNow
  }catch{}finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}}
}
function Add-Item($level, $t, $w) { [void]$script:Items.Add([pscustomobject]@{ Level = $level; Text = $t; Weight = $w; Group = $script:CurrentHead }) }
function Say-Head($t) { $script:CurrentHead = [string]$t; [void]$script:Stages.Add([string]$t); Write-Host ''; Write-Host "== $($t)" -ForegroundColor Cyan;Write-CslProgress -ForceWrite }
function Add-CslCheckEvent($level, $text, [int]$weight=0) { [void]$script:CheckEvents.Add([pscustomobject]@{ Level=$level; Text=[string]$text; Group=$script:CurrentHead;Weight=$weight });Write-CslProgress }
function Say-Pass($t) { Add-CslCheckEvent 'PASS' $t; Write-Host "  [通过] $($t)" -ForegroundColor Green }
function Say-Info($t) { Add-CslCheckEvent 'INFO' $t; Write-Host "  [信息] $($t)" -ForegroundColor Gray }
function Say-Fix($t) { Add-CslCheckEvent 'FIX' $t; Write-Host "  [修复] $($t)" -ForegroundColor Yellow }
function Say-Note($t) { Add-CslCheckEvent 'NOTE' $t; Write-Host "  [提示] $($t)" -ForegroundColor DarkGray; Add-Item 'NOTE' $t 0 }
function Say-Warn($t, $w = 8) { Add-CslCheckEvent 'WARN' $t $w; Write-Host "  [警告] $($t)" -ForegroundColor Yellow; Add-Item 'WARN' $t $w }
function Say-Fail($t, $w = 25) { Add-CslCheckEvent 'FAIL' $t $w; Write-Host "  [失败] $($t)" -ForegroundColor Red; Add-Item 'FAIL' $t $w }
function Say-Unknown($t) { Add-CslCheckEvent 'UNKNOWN' $t; Write-Host "  [待核实] $t" -ForegroundColor DarkYellow; Add-Item 'UNKNOWN' $t 0 }

function Set-CslRiskObservation([string]$Id, [string]$Group, $Observation) {
  # Replace an earlier observation after repair/startup instead of leaving stale failures in the report.
  for ($index=$script:Items.Count-1;$index -ge 0;$index--) { if ($script:Items[$index].Group -eq $Group) { $script:Items.RemoveAt($index) } }
  for ($index=$script:CheckEvents.Count-1;$index -ge 0;$index--) { if ($script:CheckEvents[$index].Group -eq $Group) { $script:CheckEvents.RemoveAt($index) } }
  $script:CurrentHead=$Group
  $safe=[ordered]@{id=$Id;status=$Observation.status;code=$Observation.code;message=$Observation.message}
  if ($null -ne $Observation.observed) { $safe.observed=[int]$Observation.observed }
  if ($null -ne $Observation.processCount) { $safe.processCount=[int]$Observation.processCount }
  if ($Observation.signals) { $safe.categories=@($Observation.signals | ForEach-Object {$_.kind} | Select-Object -Unique) }
  $script:RiskChecks[$Id]=[pscustomobject]$safe
  if ($Observation.blocksLaunch -and -not $script:LaunchBlocks.Contains($Observation.code)) { [void]$script:LaunchBlocks.Add([string]$Observation.code) }
  if ($Observation.status -eq 'unknown') { Say-Unknown $Observation.message }
  elseif ($Observation.status -eq 'risk' -and $Id -eq 'account') {
    Say-Warn $Observation.message 0
    foreach ($category in @($safe.categories)) { Say-Info ("客户端告警类别：$category（仅保留类别，不展示日志原文）") }
  } elseif ($Observation.status -eq 'risk') { Say-Fail $Observation.message }
  elseif ($Observation.status -eq 'unavailable') { Say-Info $Observation.message }
  else { Say-Pass $Observation.message }
}

function Update-CslRouteObservation {
  $observation=Get-CslLiveClaudeRoutes $cfg
  Set-CslRiskObservation 'routes' '14. Claude 实际进程连接' $observation
}

Write-Host '==============================================' -ForegroundColor Cyan
Write-Host '   Claude 桌面版 启动前检查 v3.5.3' -ForegroundColor Cyan
if ($Relearn) { Write-Host '   [重新学习] 将按当前环境重新记住出口 IP / 节点 / 时区' -ForegroundColor Cyan }
Write-Host ("   " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + $(if ($NoLaunch) { '   [NoLaunch 不启动 Claude]' } else { '' })) -ForegroundColor Cyan
Write-Host '==============================================' -ForegroundColor Cyan

# ---------- 1. Clash Verge / TUN ----------
Say-Head '1. Clash Verge 与 TUN 模式'
$mihomo = Get-ProxyCore
$verge  = Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue
$tun = Get-TunAdapter
if ($ApplySettings -and -not ($mihomo -and $tun -and $tun.Status -eq 'Up')) {
  if (-not $mihomo -and -not $verge) {
    if ($cfg.clashExe -and (Test-Path $cfg.clashExe)) { Say-Info '代理未运行，正在启动已配置的 Clash Verge'; Start-Process -FilePath $cfg.clashExe -WindowStyle Hidden | Out-Null }
    else { Say-Fail "Clash Verge 未运行，也没找到安装位置（可在 preflight.json 里填写 clashExe）" }
  } else { Say-Info 'Clash Verge 已运行，但 TUN 未就绪，等待中…' }
  $deadline = (Get-Date).AddSeconds(30)
  $tunAttempted = $false
  while ((Get-Date) -lt $deadline) {
    $mihomo = Get-ProxyCore
    if ($mihomo -and -not $tunAttempted) {
      $tunAttempted = $true
      $enabled = Enable-CslTun $cfg
      if ($enabled.ok -and $enabled.changed) { Say-Info '已请求启用 TUN，正在复查运行状态' }
    }
    $tun = Get-TunAdapter
    if ($mihomo -and $tun -and $tun.Status -eq 'Up') { Say-Fix '代理内核与 TUN 已恢复，复查通过'; break }
    Start-Sleep -Seconds 2
  }
}
if ($mihomo) { Say-Pass "代理内核 $(@($mihomo)[0].ProcessName) 运行中 (PID $(@($mihomo)[0].Id))" } else { Say-Fail '代理内核 (mihomo) 未运行' }
if ($tun -and $tun.Status -eq 'Up') { Say-Pass "TUN 网卡 $($tun.Name) 已启用" }
else { Say-Fail 'TUN 网卡未就绪；只读检查不会启动或修改代理。需要时可应用预设设置，或在 Clash Verge 中启用 TUN' }

# ---------- 2. 时区 ----------
Say-Head '2. 系统时区'
$tz = (Get-TimeZone).Id
if ($ApplySettings -and -not $cfg.timezone) {
  $tr0 = Get-Trace 'https://claude.ai/cdn-cgi/trace'; $iana = $null
  if ($tr0['ip']) { try { $iana = ((Invoke-Curl @('-m','12',"https://ipinfo.io/$($tr0['ip'])/json")) | ConvertFrom-Json).timezone } catch {} }
  $win = Convert-IanaToWindows $iana
  if ($win) { Save-Learned $cfg @{ timezone = $win; expectedTzIana = [string]$iana }; Say-Fix "首次运行：按出口 IP 所在地（$($iana)）设定目标时区 $($win)" }
  else { Say-Note "无法按出口 IP 判断时区（$($iana)），跳过时区检查；可在 preflight.json 里手动填写 timezone" }
}
if ($ApplySettings -and $cfg.timezone -and $tz -ne $cfg.timezone) {
  Say-Info "检测到时区偏差，正在按预设修复为 $($cfg.timezone)"
  try {
    & tzutil.exe /s "$($cfg.timezone)" 2>&1 | Out-Null
    $tz = (& tzutil.exe /g).Trim()
  } catch { $tz = (Get-TimeZone).Id }
  if ($tz -eq $cfg.timezone) { Say-Fix '系统时区已恢复为预设值，复查通过' }
}
if (-not $cfg.timezone) { Say-Info '未设置目标时区；只读检查不建立或修改基准' }
elseif ($tz -eq $cfg.timezone) { Say-Pass "时区: $($tz)" }
elseif ($ApplySettings) { Say-Fail "时区修复未成功，当前为 $tz；需要具备设置时区的权限后重试" }
else { Say-Warn "当前时区 $tz 与预设不同；可运行「检查并修复」" 8 }
$tzAuto = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\tzautoupdate' -ErrorAction SilentlyContinue).Start
if ($tzAuto -eq 4) { Say-Pass '自动设置时区已关闭 (tzautoupdate Start=4)' }
else { Say-Info '系统自动时区未禁用；此项仅供参考，运行期监控会按预设复查实际时区' }

# ---------- 3. 节点锁定（mihomo 外部控制器） ----------
Say-Head '3. 节点锁定'
$ctlVer = Ctl-Get $cfg '/version'
if (-not $ctlVer) {
  if ($ApplySettings) { Say-Fail '代理控制器不可达，无法修复并复查预设节点；请检查 Clash Verge 控制器状态' }
  else { Say-Warn '代理控制器不可达，无法确认预设节点状态' 10 }
} else {
  Say-Pass "外部控制器已连接 (mihomo $($ctlVer.version))"
  $groups = @(); if ($cfg.claudeGroup) { $groups += $cfg.claudeGroup }
  if ($cfg.pinMainGroup -and $cfg.mainGroup) { $groups += $cfg.mainGroup }
  if ($script:CslAllowConfigWrite -and -not $cfg.expectedNode -and $cfg.claudeGroup) {
    $gi = Ctl-GetGroup $cfg $cfg.claudeGroup
  if ($gi -and $gi.now) { Save-Learned $cfg @{ expectedNode = [string]$gi.now }; Say-Fix '已确认当前 Claude 策略组节点，检查通过后保存为基准' }
  }
  $switched = $false
  foreach ($g in $groups) {
    $info = Ctl-GetGroup $cfg $g
    if (-not $info) { if ($ApplySettings) { Say-Fail "$g 策略组不存在或无法读取，未能完成标准修复" } else { Say-Note "$g 策略组状态无法确认" }; continue }
    if (-not $cfg.expectedNode) { Say-Info "$($g) 组 → $($info.now)（未设置锁定节点）"; continue }
    if ($info.now -eq $cfg.expectedNode) { Say-Pass "$($g) 组 → $($info.now)" }
    elseif ($ApplySettings) {
      Say-Info "$($g) 组与预设不符，正在恢复预设节点"
      if (Ctl-SelectNode $cfg $g $cfg.expectedNode) {
        $after = Ctl-GetGroup $cfg $g
        if ($after.now -eq $cfg.expectedNode) { Say-Fix "$($g) 组已恢复预设节点，复查通过"; $switched = $true }
        else { Say-Fail "$($g) 组切换后仍为 $($after.now)" }
      } else { Say-Fail "$($g) 组切换请求失败" }
    } else { Say-Fail "$g 组与预设节点不一致；只读检查不切换节点，可选择「应用预设设置」" }
  }
  if ($switched) { Say-Info '已切换节点，等待 3 秒后重新测 IP…'; Start-Sleep -Seconds 3 }
}

# ---------- 4. 三方 IP 对比 ----------
Say-Head '4. 出口 IP 三方对比（本机实测 / 期望 / Claude 边缘）'
$localIp = $null; $ipinfo = $null
try { $ipinfo = (Invoke-Curl @('-m','12','https://ipinfo.io/json')) | ConvertFrom-Json } catch {}
if ($ipinfo -and $ipinfo.ip) { $localIp = $ipinfo.ip; Say-Info "本机实测(ipinfo): $($ipinfo.ip) $($ipinfo.country) $($ipinfo.city) / $($ipinfo.org)" }
else {
  $localIp = (Invoke-Curl @('-4','-m','12','https://api.ipify.org')).Trim()
  if ($localIp) { Say-Info "本机实测(ipify): $($localIp)" } else { Say-Warn '本机实测 IP 查询失败（ipinfo / ipify 都无响应）' 5 }
}
$edge = @()
foreach ($u in @('https://claude.ai/cdn-cgi/trace', 'https://api.anthropic.com/cdn-cgi/trace')) {
  $tr = Get-Trace $u
  $hostName = ([uri]$u).Host
  if ($tr['ip']) { $edge += [pscustomobject]@{ Host = $hostName; Ip = $tr['ip']; Loc = $tr['loc']; Colo = $tr['colo'] }; Say-Info "Claude 边缘($($hostName)): ip=$($tr['ip']) loc=$($tr['loc']) colo=$($tr['colo'])" }
  elseif ($hostName -eq 'claude.ai') { Say-Fail '无法访问 claude.ai/cdn-cgi/trace' }
  else { Say-Info "$($hostName) 不提供 trace（忽略）" }
}
$edgeLoc = $(if ($edge.Count) { $edge[0].Loc } else { '' })
if ($script:CslAllowConfigWrite -and -not $cfg.expectedIp) {
  $ips = @($edge | ForEach-Object { $_.Ip } | Where-Object { $_ } | Select-Object -Unique)
  if ($edge.Count -and $ips.Count -eq 1) { Save-Learned $cfg @{ expectedIp = $ips[0]; expectedLoc = $edgeLoc }; Say-Fix "已确认 Claude 域名探测出口 $($ips[0])（$($edgeLoc)），检查通过后保存为基准" }
  elseif ($ips.Count -gt 1) { Say-Warn ("各方看到的出口 IP 不一致，暂不记住: " + ($ips -join ', ')) 10 }
  elseif (-not $edge.Count) { Say-Warn '测不到 Claude 看到的出口 IP，暂不记住' 10 }
}
if ($cfg.expectedIp) { Say-Info "期望: $($cfg.expectedIp) loc=$($cfg.expectedLoc)" }
$all = @(); if ($cfg.expectedIp) { $all = @($edge | ForEach-Object { $_.Ip }) }
$bad = @($all | Where-Object { $_ -ne $cfg.expectedIp })
$badLoc = @($edge | Where-Object { $_.Loc -ne $cfg.expectedLoc })
if ($all.Count -gt 0 -and $bad.Count -eq 0 -and $badLoc.Count -eq 0) { Say-Pass "Claude 域名探测出口与预设一致: $($cfg.expectedIp)" }
elseif ($all.Count -gt 0) { Say-Fail ("IP 不一致: 本机=$($localIp) 边缘=" + (($edge | ForEach-Object { "$($_.Host):$($_.Ip)/$($_.Loc)" }) -join ',') + " 期望=$($cfg.expectedIp)") }
$exitIp = $(if ($edge.Count) { $edge[0].Ip } else { $localIp })
if ($localIp -and $exitIp -and $localIp -ne $exitIp) { Say-Info '通用 IP 查询与 Claude 域名探测出口不同，可能由分流造成；不据此阻止启动' }

# ---------- 5. IP 风险评分 ----------
Say-Head '5. IP 风险（proxycheck.io / ip-api）'
if ($CheckMode -eq 'full') {
$qip = $(if ($exitIp) { $exitIp } else { $cfg.expectedIp })
$pc = $null
try { $pc = (Invoke-Curl @('-m','15',"https://proxycheck.io/v2/$($qip)?vpn=1&asn=1&risk=1")) | ConvertFrom-Json } catch {}
$pcd = $null; if ($pc -and $pc.status -match 'ok|warning') { $pcd = $pc.$qip }
if ($pcd) {
  $risk = [int]$pcd.risk
  $line = "proxycheck: risk=$($risk) proxy=$($pcd.proxy) type=$($pcd.type) / $($pcd.provider) $($pcd.organisation)"
  if ($risk -ge [int]$cfg.failRisk) { Say-Warn "$($line)（第三方评分仅供参考）" 0 }
  elseif ($risk -ge [int]$cfg.warnRisk -or $pcd.proxy -eq 'yes') { Say-Warn "$($line)（第三方评分仅供参考）" 0 }
  else { Say-Pass $line }
} else { Say-Info 'proxycheck.io 查询失败或被限流：结果未知，不扣分' }
$ia = $null
try { $ia = (Invoke-Curl @('-m','12',"http://ip-api.com/json/$($qip)?fields=status,countryCode,isp,org,as,proxy,hosting,mobile")) | ConvertFrom-Json } catch {}
if ($ia -and $ia.status -eq 'success') {
  $line = "ip-api: $($ia.countryCode) $($ia.isp) / $($ia.as) proxy=$($ia.proxy) hosting=$($ia.hosting)"
  if ($ia.hosting -or $ia.proxy) { Say-Warn "$($line)（第三方标签仅供参考）" 0 } else { Say-Pass $line }
} else { Say-Note 'ip-api 查询失败（忽略）' }
} else { Say-Info '快速检查跳过第三方 IP 评分；完整诊断可查询参考标签' }

# ---------- 6. DNS ----------
Say-Head '6. DNS (fake-ip)'
$dns = Resolve-DnsName api.anthropic.com -Type A -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress } | Select-Object -First 1
if ($dns -and ($dns.IPAddress -like '198.18.*' -or $dns.IPAddress -like '198.19.*')) { Say-Pass "api.anthropic.com → $($dns.IPAddress)（fake-ip，由 Clash 接管）" }
elseif ($dns) { Say-Info "api.anthropic.com 已解析为真实地址；redir-host 或 fake-ip 例外也可能正常，不据此判断代理失效" }
else { Say-Warn 'api.anthropic.com 解析失败' 5 }

# ---------- 7. IPv6 ----------
Say-Head '7. IPv6 出口（参考）'
$v6 = & curl.exe --noproxy '*' -6 -s -m 8 https://api64.ipify.org 2>$null
if ($LASTEXITCODE -ne 0 -or -not $v6 -or ($v6 -notmatch ':')) { Say-Info '未测得 IPv6 出口：可能不可用、被阻止或探测失败，不能据此确认无泄露' }
else { Say-Warn "检测到 IPv6 出口: $($v6)；是否受代理管理需结合路由确认，不仅凭地址存在判定泄露" 0 }

# ---------- 8. Anthropic API ----------
Say-Head '8. api.anthropic.com 连通性'
$tmp = [IO.Path]::GetTempFileName()
$code = & curl.exe --noproxy '*' -s -m 15 -o $tmp -w '%{http_code}' https://api.anthropic.com/v1/messages 2>$null
$body = ''; try { $body = [string](Get-Content $tmp -Raw -ErrorAction SilentlyContinue) } catch {}
Remove-Item $tmp -ErrorAction SilentlyContinue
$bodyOne = ($body -replace '\s+', ' ')
if ($code -in @('200','401','404','405')) { Say-Pass "HTTPS 探测收到 HTTP $code 响应；仅确认连通性，不验证账号权限、地区可用性或请求成功" }
elseif ($code -eq '403') { Say-Warn 'HTTP 403：访问被拒绝，可能涉及权限或网关策略；不能仅凭状态码判定地区封锁' 0 }
elseif ($code -eq '000' -or -not $code) { Say-Fail '无法连接 api.anthropic.com' }
else { Say-Warn "HTTP $($code)（非预期状态码）" 5 }

# ---------- 9. 环境变量 ----------
Say-Head '9. 环境变量'
# 检测与修复共用同一模式源（-FixVarPattern / preflight.json fixVarPatterns / 默认列表）
# 只读用户级注册表 / [Environment]::GetEnvironmentVariable(n,'User')，不把进程环境当真相
$targets = Find-CslRelayEnvTargets -Patterns $script:FixPatterns -TestMode:$TestMode
if (-not $targets.ok) {
  Say-Fail $targets.error
} else {
  $userNames = @($targets.user | ForEach-Object { $_.Name })
  $machNames = @($targets.machineOnly | ForEach-Object { $_.Name })
  if ($userNames.Count -eq 0 -and $machNames.Count -eq 0) {
    Say-Pass '没有匹配的第三方中转环境变量（用户级）'
  } else {
    foreach ($u in $targets.user) {
      if ($u.Name -eq 'ANTHROPIC_BASE_URL' -and -not (Test-CslOfficialEndpoint $u.Value)) {
        Say-Warn 'Claude Code 配置了自定义接口地址；请按用途核实，桌面聊天检查不会清除该变量' 0
      } else { Say-Info ("用户级 {0} 已配置：属于 Claude Code 配置，不以变量存在判定中转或阻止桌面聊天启动" -f $u.Name) }
    }
    foreach ($m in $targets.machineOnly) {
      Say-Note ("{0} 仅 Machine 级存在：需要管理员手动处理" -f $m.Name)
    }
    # 交互修复：显式 -FixEnv 已在上方短路。此处仅在有 TTY 且非 NoPause 时询问。
    # 纯 -NoPause 绝不自动修。envFixKeep 中的变量不进确认名单；envFixEnabled=false 不询问。
    $keepNow = @($script:EnvFixSettings.keep)
    $fixNames = @($userNames | Where-Object { $null -ne $_ -and -not ($keepNow.Count -gt 0 -and (Test-CslNameMatchesPatterns -Name $_ -Patterns $keepNow)) })
    foreach ($kn in @($userNames | Where-Object { $null -ne $_ -and $fixNames -notcontains $_ })) {
      Say-Info ("{0} 在 envFixKeep 中，一键修复会保留它" -f $kn)
    }
    if ($userNames.Count -gt 0 -and -not $script:EnvFixSettings.enabled) {
      Say-Info '一键修复已在 preflight.json 关闭（envFixEnabled=false），请手动处理'
    } elseif ($fixNames.Count -gt 0) {
      Say-Info '检查模式保留现有变量；仅显式使用 -FixEnv 才会进入清理预览和确认'
    }
  }
}
$hp = [Environment]::GetEnvironmentVariable('HTTPS_PROXY','User'); if (-not $hp) { $hp = $env:HTTPS_PROXY }
if ($hp) { Say-Info '已配置 HTTPS_PROXY；本工具的探测使用现有 TUN 路径' } else { Say-Info '未配置 HTTPS_PROXY；TUN 模式不要求设置该变量' }

# ---------- 10. 残留配置扫描（只报告，不删除，不显示值） ----------
Say-Head '10. 第三方接口残留扫描'
if ($CheckMode -eq 'full') {
$scan = @()
$cdir = Join-Path $env:USERPROFILE '.claude'
foreach ($f in @('settings.json','settings.local.json','config.json')) { $scan += (Join-Path $cdir $f) }
$scan += (Join-Path $env:USERPROFILE '.claude.json')
$adir = Join-Path $env:APPDATA 'Claude'
if (Test-Path $adir) { $scan += @(Get-ChildItem $adir -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
$hostRx = 'kimi|moonshot|deepseek|openrouter|siliconflow|bigmodel|zhipu|dashscope|aliyuncs|volces|minimax|anyrouter|api2d|aicodemirror|packycode|claude-relay|gptsapi|ohmygpt|xiaomimimo'
$residue = 0
foreach ($f in ($scan | Select-Object -Unique)) {
  if (-not (Test-Path $f)) { continue }
  $txt = ''; try { $txt = [IO.File]::ReadAllText($f) } catch { continue }
  $hits = @()
  $parsed = $null; try { $parsed = $txt | ConvertFrom-Json } catch { Say-Info '有配置文件无法解析，未据此判定存在中转'; continue }
  $baseUrl = $null
  if ($parsed.env) { $baseUrl = $parsed.env.ANTHROPIC_BASE_URL }
  if (-not $baseUrl) { $baseUrl = $parsed.ANTHROPIC_BASE_URL }
  if ($baseUrl -and -not (Test-CslOfficialEndpoint ([string]$baseUrl))) { $residue++; Say-Warn "$f 配置了 Claude Code 自定义接口；按用途保留，不影响桌面聊天检查" 0 }
}
if ($residue -eq 0) { Say-Pass '已扫描的配置未发现 Claude Code 自定义接口；正常 API Key 与模型设置不算残留' }
$npmDir = $cfg.npmGlobalDir
if ($npmDir -and (Test-Path $npmDir)) {
  $helpers = @(Get-ChildItem $npmDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^claude-(kimi|deepseek|model|models|multi)[\w\-]*\.(ps1|cmd|bat)$' } | ForEach-Object { $_.Name })
  if ($helpers.Count) { Say-Info '发现可选的 Claude Code 模型切换脚本：文件存在不代表当前正在使用' }
  else { Say-Pass '没有第三方模型切换脚本' }
}
} else { Say-Info '快速检查跳过配置文件扫描；不会读取凭据文件' }

# ---------- 11. 其他 ----------
Say-Head '11. 其他'
$ui = (Get-UICulture).Name
if ($ui -match '^zh') { Say-Note "系统界面语言为 $($ui)（一般不影响，可忽略）" } else { Say-Pass "系统界面语言 $($ui)" }
if ($cfg.claudeAumid -or ($cfg.claudeExe -and (Test-Path $cfg.claudeExe))) { Say-Pass 'Claude 桌面版已安装' } else { Say-Warn '没找到 Claude 桌面版（可在 preflight.json 里填写 claudeExe）' 5 }
if (Get-Command claude -ErrorAction SilentlyContinue) { Say-Pass 'Claude Code CLI 已安装' } else { Say-Note '未找到 claude CLI（仅影响命令行版）' }


# ---------- 12. 浏览器环境 ----------
Say-Head '12. 浏览器环境'
$script:BrowserStaticWarnUsed = 0
$script:BrowserStaticWarnCap = 20
function Soft-BrowserWarn([string]$t, [int]$w = 5) {
  Say-Info ($t + '（其他浏览器配置仅供参考，不扣分、不阻止桌面版启动）')
}
function Read-PrefText([string]$path) {
  $tmp = Join-Path $env:TEMP ('csl-pref-' + [guid]::NewGuid().ToString('n'))
  try {
    Copy-Item -LiteralPath $path -Destination $tmp -Force -ErrorAction Stop
    $txt = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8)
  } catch {
    try {
      $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
      $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
      $txt = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
    } catch { return $null }
  } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  return $txt
}
function Get-JsonStr([string]$txt, [string]$key) {
  if (-not $txt) { return $null }
  $m = [regex]::Match($txt, '"' + [regex]::Escape($key) + '"\s*:\s*"((?:\\.|[^"\\])*)"')
  if ($m.Success) { return $m.Groups[1].Value } else { return $null }
}
function Test-LangMismatch([string]$langs, [string]$loc) {
  # en* never reported. Otherwise compare base language with exit-IP country's common languages.
  # Mismatch -> caller should Say-Warn with weight 0 (建议修, 不扣分).
  if (-not $langs -or -not $loc) { return $false }
  $first = (($langs -split ',')[0]).Trim().ToLowerInvariant()
  if (-not $first) { return $false }
  if ($first.StartsWith('en')) { return $false }
  $cc = $loc.ToUpperInvariant()
  $base = ($first -split '-')[0]
  $map = @{
    'zh' = @('CN','TW','HK','MO','SG')
    'ja' = @('JP')
    'ko' = @('KR')
    'de' = @('DE','AT','CH','LI')
    'fr' = @('FR','BE','CH','LU','MC','CA')
    'es' = @('ES','MX','AR','CO','CL','PE','VE','EC','GT','CU','BO','DO','HN','PY','SV','NI','CR','PA','UY','PR')
    'pt' = @('PT','BR','AO','MZ')
    'ru' = @('RU','BY','KZ','KG')
    'it' = @('IT','CH','SM','VA')
    'nl' = @('NL','BE','SR')
    'ar' = @('SA','AE','EG','IQ','JO','KW','LB','MA','OM','QA','SY','TN','YE','BH','DZ','LY','SD')
    'th' = @('TH')
    'vi' = @('VN')
    'id' = @('ID')
    'ms' = @('MY','BN','SG')
    'tr' = @('TR','CY')
    'pl' = @('PL')
    'uk' = @('UA')
    'hi' = @('IN')
  }
  if ($map.ContainsKey($base)) {
    return -not ($cc -in $map[$base])
  }
  # Unknown language with region tag: warn when region != exit country
  if ($first -match '^[a-z]{2}-([a-z]{2})$') {
    return ($Matches[1].ToUpperInvariant() -ne $cc)
  }
  return $false
}

$browserRoots = @(
  @{ Name = 'Chrome'; Path = (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data') },
  @{ Name = 'Edge'; Path = (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data') },
  @{ Name = 'Brave'; Path = (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data') }
)
$foundBrowser = $false
if ($CheckMode -eq 'full') {
foreach ($b in $browserRoots) {
  if (-not (Test-Path -LiteralPath $b.Path)) { continue }
  $profiles = @(Get-ChildItem -LiteralPath $b.Path -Directory -ErrorAction SilentlyContinue | Where-Object {
    ($_.Name -eq 'Default' -or $_.Name.StartsWith('Profile ')) -and ($_.FullName -notmatch 'panel-edge')
  })
  foreach ($prof in $profiles) {
    $prefPath = Join-Path $prof.FullName 'Preferences'
    if (-not (Test-Path -LiteralPath $prefPath)) { continue }
    $foundBrowser = $true
    $txt = Read-PrefText $prefPath
    if (-not $txt) { Say-Info "$($b.Name) · $($prof.Name): 无法读取 Preferences"; continue }
    # Label always includes profile directory name; optional profile.name from JSON as secondary.
    $dirName = $prof.Name
    $displayName = $null
    $langs = $null
    try {
      $prefObj = $txt | ConvertFrom-Json -ErrorAction Stop
      if ($prefObj.profile -and $prefObj.profile.PSObject.Properties['name'] -and $prefObj.profile.name) {
        $displayName = [string]$prefObj.profile.name
      }
      if ($prefObj.intl -and $prefObj.intl.PSObject.Properties['accept_languages']) {
        $langs = [string]$prefObj.intl.accept_languages
      }
    } catch { }
    if (-not $langs) { $langs = Get-JsonStr $txt 'accept_languages' }
    $label = "$($b.Name) · $dirName"
    if ($displayName -and $displayName -ne $dirName -and $displayName -ne 'Person 1') {
      $label = "$($b.Name) · $dirName（$displayName）"
    }
    $webrtc = $null
    $wm = [regex]::Match($txt, '"ip_handling_policy"\s*:\s*"([^"]+)"')
    if ($wm.Success) { $webrtc = $wm.Groups[1].Value }
    if ($webrtc -eq 'disable_non_proxied_udp') {
      Say-Pass "${label}: WebRTC=disable_non_proxied_udp"
    } elseif ($webrtc) {
      Soft-BrowserWarn "${label}: WebRTC=$webrtc（建议 disable_non_proxied_udp 或用扩展禁用）" 5
    } else {
      Soft-BrowserWarn "${label}: 未设置 webrtc.ip_handling_policy，可能暴露真实/局域网 IP（建议 disable_non_proxied_udp）" 5
    }
    if ($langs) {
      if (Test-LangMismatch $langs $cfg.expectedLoc) {
        Say-Info "${label}: 语言 $langs 与出口地区 $($cfg.expectedLoc) 不一致（仅参考）"
      } else {
        Say-Info "${label}: 语言 $langs"
      }
    }
    if ($txt -match '(?i)switchyomega|foxyproxy|proxy\s*switch|webrtc.?leak|canvas.?blocker|fingerprint|指纹|CanvasFingerprint|WebRTC Control') {
      Say-Info "${label}: 检测到代理/指纹相关扩展（仅提示）"
    }
  }
}
if (-not $foundBrowser) { Say-Info '未找到 Chrome / Edge / Brave 用户配置（跳过静态配置检查）' }

$ffRoot = Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles'
if (Test-Path -LiteralPath $ffRoot) {
  foreach ($fp in @(Get-ChildItem -LiteralPath $ffRoot -Directory -ErrorAction SilentlyContinue)) {
    $pj = Join-Path $fp.FullName 'prefs.js'
    if (-not (Test-Path -LiteralPath $pj)) { continue }
    $ptxt = ''; try { $ptxt = [IO.File]::ReadAllText($pj) } catch { continue }
    $m = [regex]::Match($ptxt, 'user_pref\("media\.peerconnection\.enabled"\s*,\s*(true|false)\)')
    if ($m.Success) {
      if ($m.Groups[1].Value -eq 'false') { Say-Info "Firefox「$($fp.Name)」: WebRTC 已关闭" }
      else { Soft-BrowserWarn "Firefox「$($fp.Name)」: media.peerconnection.enabled=true，可能暴露 IP" 5 }
    } else {
      Soft-BrowserWarn "Firefox「$($fp.Name)」: 未关闭 media.peerconnection.enabled（默认开启）" 5
    }
  }
}

} else { Say-Info '快速检查不扫描其他浏览器配置' }
$bcPath = Join-Path $script:Root 'browser-check.json'
if (-not (Test-Path -LiteralPath $bcPath)) {
  Say-Info '实时浏览器检查（WebRTC/时区/语言）请从检查面板运行；命令行模式跳过，不扣分'
} else {
  $raw = $null; try { $raw = [IO.File]::ReadAllText($bcPath, [Text.Encoding]::UTF8) } catch {}
  $bc = $null; if ($raw) { try { $bc = $raw | ConvertFrom-Json } catch { Say-Warn 'browser-check.json 解析失败' 3 } }
  if ($bc) {
    $ts = $null
    if ($bc.ts) {
      try {
        $ts = [datetime]::Parse(
          [string]$bc.ts,
          [Globalization.CultureInfo]::InvariantCulture,
          [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
        )
      } catch {
        try { $ts = [datetime]::Parse([string]$bc.ts, $null, [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime() } catch {}
      }
    }
    if (-not $ts -or [math]::Abs((([datetime]::UtcNow) - $ts).TotalMinutes) -gt 3) {
      Say-Info 'browser-check.json 超过 3 分钟或无时间戳，视为过期；请从面板重新检查（不扣分）'
    } else {
      Say-Info ("实时快照 " + $ts.ToUniversalTime().ToString('HH:mm:ss') + ' UTC')
      $srflx = @(); $hostC = @(); $v6extra = @()
      if ($bc.webrtc) {
        if ($bc.webrtc.srflx) { $srflx = @($bc.webrtc.srflx | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
        if ($bc.webrtc.host) { $hostC = @($bc.webrtc.host | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
        if ($bc.webrtc.ipv6) { $v6extra = @($bc.webrtc.ipv6 | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
      }
      $pubV4 = @($srflx | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
      $pubV6 = @(@($srflx | Where-Object { $_ -match ':' }) + $v6extra | Select-Object -Unique)
      $expectIp = $(if ($cfg.expectedIp) { [string]$cfg.expectedIp } else { [string]$exitIp })
      if ($pubV4.Count -eq 0 -and $pubV6.Count -eq 0) {
        Say-Info '面板 Edge 的 WebRTC 未收集到公网候选：可能被禁用、探测超时或不可达，结果未知'
      } else {
        if ($pubV4.Count) {
          $uniq = @($pubV4 | Select-Object -Unique)
          $bad = @($uniq | Where-Object { $expectIp -and $_ -ne $expectIp })
          if ($expectIp -and $bad.Count -eq 0) { Say-Pass "WebRTC 公网 IP 与出口一致: $($uniq[0])" }
          elseif ($expectIp -and $bad.Count) { Say-Warn ("面板 Edge 的 WebRTC 公网 IP 与预设不同: WebRTC=" + ($uniq -join ',') + " 期望=$expectIp；需要结合路由核实，不能直接代表 Claude 桌面端连接") 0 }
          else { Say-Info ("WebRTC 公网 IP: " + ($uniq -join ',')) }
        }
        if ($pubV6.Count) { Say-Warn ("面板 Edge 的 WebRTC 发现公网 IPv6: " + ($pubV6 -join ',') + "（路由归属待核实）") 0 }
      }
      $mdns = @($hostC | Where-Object { $_ -match '\.local$' })
      if ($mdns.Count) { Say-Info ("WebRTC host 含 mDNS（正常）: " + ($mdns -join ',')) }

      $btz = [string]$bc.timezone
      $expectIana = [string]$cfg.expectedTzIana
      if (-not $expectIana -and $cfg.timezone) {
        if ([string]$cfg.timezone -match '/') { $expectIana = [string]$cfg.timezone }
        else { $expectIana = Convert-WindowsToIana ([string]$cfg.timezone) }
      }
      if ($btz -and $expectIana) {
        if ($btz -eq $expectIana) { Say-Pass "浏览器时区 $btz 与出口一致" }
        else { Say-Info "面板浏览器时区 $btz 与预设时区 $expectIana 不一致（仅参考）" }
      } elseif ($btz) { Say-Info "浏览器时区: $btz（尚未记住出口 IANA 时区）" }

      $blang = [string]$bc.language
      if ((-not $blang) -and $bc.languages) { $blang = [string](@($bc.languages)[0]) }
      if ($blang -and $cfg.expectedLoc) {
        if (Test-LangMismatch $blang $cfg.expectedLoc) { Say-Info "面板浏览器语言 $blang 与出口地区 $($cfg.expectedLoc) 不一致（仅参考）" }
        else { Say-Pass "浏览器语言 $blang" }
      } elseif ($blang) { Say-Info "浏览器语言: $blang" }

      if ($bc.webdriver -eq $true) { Say-Info '面板浏览器由自动化驱动（不代表 Claude 桌面端环境）' }
      else { Say-Pass 'navigator.webdriver 未开启' }
    }
  }
}


Say-Head '13. 官方支持地区核对'
$regionSnapshot=Get-CslRegionSnapshot
$regionAssessment=Get-CslRegionAssessment $regionSnapshot ([string]$edgeLoc)
Set-CslRiskObservation 'regions' '13. 官方支持地区核对' $regionAssessment
Say-Info ('官方来源：'+$script:CslRegionSource)
if ($regionSnapshot.status -eq 'available') { Say-Info ("官方名单距上次成功核对 $($regionSnapshot.ageDays) 天；超过 7 天且无法刷新时视为待核实") }

Say-Head '14. Claude 实际进程连接'
Update-CslRouteObservation

Say-Head '15. 客户端告警扫描'
Set-CslRiskObservation 'account' '15. 客户端告警扫描' (Get-CslClientAccountEvidence)

# Only commit a newly learned baseline after a complete, usable check.
if ($Relearn -and (-not $cfg.expectedIp -or -not $cfg.expectedNode -or -not $cfg.timezone)) {
  Say-Fail '当前出口、节点或时区无法完整确认；未保存新的环境基准'
}
# ---------- 评分 ----------
$fails = @($script:Items | Where-Object Level -eq 'FAIL')
$warns = @($script:Items | Where-Object Level -eq 'WARN')
$unknowns = @($script:Items | Where-Object Level -eq 'UNKNOWN')
$notes = @($script:Items | Where-Object Level -eq 'NOTE')
$lost = ($script:Items | Measure-Object -Property Weight -Sum).Sum; if (-not $lost) { $lost = 0 }
$score = [Math]::Max(0, 100 - [int]$lost)
Write-Host ''
Write-Host '==============================================' -ForegroundColor Cyan
$sc = $(if ($fails.Count) { 'Red' } elseif ($score -ge 90) { 'Green' } else { 'Yellow' })
Write-Host "  一致性评分: $($score) / 100" -ForegroundColor $sc
if ($fails.Count) { Write-Host "  【必须修】$($fails.Count) 项" -ForegroundColor Red;    foreach ($i in $fails) { Write-Host "    - $($i.Text)" -ForegroundColor Red } }
if ($warns.Count) { Write-Host "  【建议修】$($warns.Count) 项" -ForegroundColor Yellow; foreach ($i in $warns) { Write-Host "    - $($i.Text)" -ForegroundColor Yellow } }
if ($notes.Count) { Write-Host "  【不用管】$($notes.Count) 项" -ForegroundColor DarkGray; foreach ($i in $notes) { Write-Host "    - $($i.Text)" -ForegroundColor DarkGray } }
if ($unknowns.Count) { Write-Host "  【未核实】$($unknowns.Count) 项" -ForegroundColor DarkYellow; foreach ($i in $unknowns) { Write-Host "    - $($i.Text)" -ForegroundColor DarkYellow } }
if (-not ($fails.Count + $warns.Count + $notes.Count + $unknowns.Count)) { Write-Host '  本次已检查项目未见已知异常' -ForegroundColor Green }
Write-Host '==============================================' -ForegroundColor Cyan
$result = $(if ($fails.Count) { 'FAIL' } elseif ($warns.Count -or $unknowns.Count -or $script:LaunchBlocks.Count) { 'WARN' } else { 'PASS' })
if ($script:CslPendingLearned.Count -gt 0) {
  if ($fails.Count -eq 0 -and $script:LaunchBlocks.Count -eq 0) { Save-Learned $cfg $script:CslPendingLearned -Commit }
  else { Say-Info '检查未通过，保留原有环境基准，不写入本次记录' }
}

if ($ExportIssues) {
  Write-Host ''
  Write-Host '-------- 问题说明（可复制） --------' -ForegroundColor Cyan
  $pack = Format-CslIssuePack -Items @($script:Items.ToArray()) -HideIp:$HideIp
  Write-Host $pack
  Write-Host '-------- 结束 --------' -ForegroundColor Cyan
}

# ---------- 启动 ----------
$launched = 'no'
if ($NoLaunch) {
  Write-Host '[NoLaunch] 本次不启动 Claude，不启动后台监控。' -ForegroundColor Cyan
  $launched = 'nolaunch'
} elseif ($fails.Count -eq 0 -and $script:LaunchBlocks.Count -eq 0) {
  if ($fails.Count) { Write-Host "有 $($fails.Count) 项必须修，但使用了 -Force，仍然启动。" -ForegroundColor Red }
  if (Get-ClaudeProcesses) { Write-Host 'Claude 已在运行，切换到前台…' -ForegroundColor Green; $launched = 'front' }
  else { Write-Host '正在启动 Claude…' -ForegroundColor Green; $launched = 'yes' }
  if (-not (Start-ClaudeApp $cfg)) {
    Say-Fail '未能启动 Claude 桌面版，请核对安装状态或 claudeExe 配置'
    $launched = 'notfound'
    $fails = @($script:Items | Where-Object Level -eq 'FAIL')
    $score = [Math]::Max(0, 100 - [int](($script:Items | Measure-Object -Property Weight -Sum).Sum))
    $result = 'FAIL'
  }
  if ($launched -ne 'notfound') {
    Update-CslRouteObservation
    Set-CslRiskObservation 'account' '15. 客户端告警扫描' (Get-CslClientAccountEvidence)
  }
  $mon = Join-Path $script:Root 'claude-monitor.ps1'
  if ($launched -ne 'notfound' -and (Test-Path $mon)) {
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$($mon)`"")
    Write-Host "已启动后台监控（每 $($cfg.monitorIntervalMin) 分钟检查一次）" -ForegroundColor Gray
  }
} else {
  Write-Host '仍有阻断项或地区资料无法核实，未自动启动 Claude。请处理后重试。' -ForegroundColor Red
}

# ---------- 日志 ----------
$fails=@($script:Items | Where-Object Level -eq 'FAIL');$warns=@($script:Items | Where-Object Level -eq 'WARN');$unknowns=@($script:Items | Where-Object Level -eq 'UNKNOWN')
$lost=($script:Items | Measure-Object -Property Weight -Sum).Sum
$score=[Math]::Max(0,100-[int]$lost)
$result=$(if($fails.Count){'FAIL'}elseif($warns.Count -or $unknowns.Count -or $script:LaunchBlocks.Count){'WARN'}else{'PASS'})
$logLine = '{0} | score={1} | ip={2} | tz={3} | fail={4} | warn={5} | launch={6}' -f $result, $score, $exitIp, $tz, $fails.Count, $warns.Count, $launched
if ($fails.Count) { $logLine += ' | ' + (($fails | ForEach-Object { $_.Text }) -join '; ') }
Write-Log $logLine
$finalExitCode = $(if ($fails.Count) { 1 } elseif($script:LaunchBlocks.Count){3}else{0})
if ($script:Stages.Count -ne 15) { throw '检查项目未全部执行' }
Write-CslCheckReport -Path $ResultPath -RunId $RunId -Complete $true -Result $result -Score $score -ExitCode $finalExitCode -Items @($script:Items.ToArray()) -Stages @($script:Stages.ToArray()) -Mode $CheckMode -Launch $launched -Events @($script:CheckEvents.ToArray()) -RepairMode ([bool]$ApplySettings) -RiskChecks @($script:RiskChecks.Values) -LaunchBlocks @($script:LaunchBlocks.ToArray())

if (-not $NoPause) {
  if ($fails.Count -and -not $Force) { Write-Host ''; Write-Host '按任意键退出' -ForegroundColor Gray; try { [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Read-Host | Out-Null } }
  else { Write-Host '5 秒后自动关闭…' -ForegroundColor Gray; Start-Sleep -Seconds 5 }
}
exit $finalExitCode
