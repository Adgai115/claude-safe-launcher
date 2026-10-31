#Requires -Version 5.1
# Repairs the recorded standard by default; monitorAutoRepair=false opts into notify-only mode.
param([switch]$Once, [switch]$DryRun)
. (Join-Path $PSScriptRoot 'claude-common.ps1')
. (Join-Path $PSScriptRoot 'claude-diagnostics.ps1')
. (Join-Path $PSScriptRoot 'claude-risk.ps1')
$cfg = Load-Config
$tag = '[monitor]' + $(if ($DryRun) { '[DryRun]' } else { '' })
$script:AlertKey = ''
$script:LastAlertUtc = [datetime]::MinValue
$script:RuntimeAlertKey = ''
$script:RuntimeLastAlertUtc = [datetime]::MinValue
$created = $false
$mutex = New-Object Threading.Mutex($false, 'Local\ClaudePreflightMonitor')
try { $created = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $created = $true }
if (-not $created) { if ($Once) { Write-Host '已有监控实例在运行' }; exit 0 }

function Show-Alert([string]$Title, [string]$Text) {
  try {
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $t = [Security.SecurityElement]::Escape($Title); $b = [Security.SecurityElement]::Escape($Text)
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$t</text><text>$b</text></binding></visual></toast>")
    $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show((New-Object Windows.UI.Notifications.ToastNotification($xml)))
  } catch { Write-Log "$tag notification unavailable" }
}

function Test-State {
  $state = @{ ip = $null; problems = @(); codes = @(); ctlOk = $true }
  $groups = @($cfg.claudeGroup)
  if ($cfg.pinMainGroup -and $cfg.mainGroup) { $groups += $cfg.mainGroup }
  foreach ($group in @($groups | Where-Object { $_ } | Select-Object -Unique)) {
    $g = Ctl-GetGroup $cfg $group
    if (-not $g) {
      $state.ctlOk = $false; $state.problems += "$group 策略组状态无法确认"; $state.codes += "controller:$group"
    } elseif ($cfg.expectedNode -and $g.now -ne $cfg.expectedNode) {
      $state.problems += "$group 策略组与预设不一致"; $state.codes += "node:$group"
    }
  }
  $trace = Get-Trace 'https://claude.ai/cdn-cgi/trace'
  $zone = (Get-TimeZone).Id
  if ($cfg.timezone -and $zone -ne $cfg.timezone) { $state.problems += '系统时区与预设不一致'; $state.codes += 'timezone:changed' }
  $adapter = Get-TunAdapter
  if (-not $adapter -or $adapter.Status -ne 'Up') { $state.problems += 'TUN 未就绪'; $state.codes += 'tun:unavailable' }
  $state.ip = $trace['ip']
  if (-not $state.ip) { $state.problems += 'Claude 域名探测无响应（结果未知）'; $state.codes += 'trace:unknown' }
  elseif ($cfg.expectedIp -and ($state.ip -ne $cfg.expectedIp -or $trace['loc'] -ne $cfg.expectedLoc)) {
    $state.problems += 'Claude 域名探测出口与预设不同'; $state.codes += 'trace:changed'
  }
  return $state
}

function Invoke-Check {
  $attempts = [Math]::Min(5, [Math]::Max(1, [int]$cfg.monitorRetryCount))
  $state = $null
  for ($attempt = 1; $attempt -le $attempts; $attempt++) {
    $state = Test-State
    if (-not $state.problems.Count) { break }
    if ($attempt -lt $attempts -and -not $DryRun) { Start-Sleep -Seconds ([Math]::Min(4, $attempt * 2)) }
  }
  if (-not $state.problems.Count) {
    if ($script:AlertKey) { Write-Log "$tag RECOVERED"; Show-Alert 'Claude 环境恢复' '连续探测异常已恢复。' }
    $script:AlertKey = ''
    if ($Once) { Write-Host '监控探测通过'; Write-Log "$tag OK" }
    return
  }
  if ($DryRun) { Write-Host 'DryRun：检测到异常；未修改节点、未通知、未关闭 Claude'; return }
  if ($cfg.monitorAutoRepair) {
    if ($state.ctlOk -and $cfg.expectedNode) {
      [void](Ctl-SelectNode $cfg $cfg.claudeGroup $cfg.expectedNode)
      if ($cfg.pinMainGroup -and $cfg.mainGroup) { [void](Ctl-SelectNode $cfg $cfg.mainGroup $cfg.expectedNode) }
    }
    if ($state.codes -contains 'timezone:changed') { & tzutil.exe /s "$($cfg.timezone)" 2>$null | Out-Null }
    if ($state.codes -contains 'tun:unavailable') { [void](Enable-CslTun $cfg) }
    Start-Sleep -Seconds 3
    $state = Test-State
    if (-not $state.problems.Count) { Write-Log "$tag FIXED"; Show-Alert 'Claude 监控' '已按启用的自动修复配置恢复预设节点。'; $script:AlertKey = ''; return }
  }
  $key = (@($state.codes | Sort-Object -Unique) -join '|')
  $decision = Get-CslMonitorAlertDecision -Key $key -PreviousKey $script:AlertKey -LastAlertUtc $script:LastAlertUtc -CooldownMinutes ([int]$cfg.monitorAlertCooldownMin)
  if ($decision -eq 'notify') {
    $script:AlertKey = $key; $script:LastAlertUtc = [datetime]::UtcNow
    Write-Log "$tag ALERT | $($state.problems -join '; ')"
    Show-Alert 'Claude 环境需要检查' ("连续 $attempts 次探测异常：" + ($state.problems -join '；') + '。同类提醒将在冷却时间内合并。')
  }
}

function Invoke-RuntimeRiskCheck {
  $routes=Get-CslLiveClaudeRoutes $cfg
  $account=Get-CslClientAccountEvidence
  $codes=@()
  if ($routes.status -eq 'risk') { $codes+='routes:mismatch' }
  if ($account.status -eq 'risk') { $codes+=@($account.signals|ForEach-Object{'account:'+ $_.kind}) }
  $unknown=0
  if ($routes.status -eq 'unknown') { $unknown++ }
  if ($account.status -eq 'unknown') { $unknown++ }
  $summary=@{
    timestampUtc=[datetime]::UtcNow.ToString('o');active=$true
    status=$(if($codes.Count){'risk'}elseif($unknown){'unknown'}else{'observed'})
    remaining=$codes.Count;unknown=$unknown;fixed=0
    routes=@{status=$routes.status;code=$routes.code;message=$routes.message;observed=$routes.observed;processCount=$routes.processCount;tcpAttributed=$routes.tcpAttributed}
    account=@{status=$account.status;code=$account.code;message=$account.message;categories=@($account.signals|ForEach-Object{$_.kind})}
  }
  $path=Join-Path $script:Root 'monitor-risk.json';$temp=$path+'.tmp'
  try {
    [IO.File]::WriteAllText($temp,($summary|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    if(Test-Path -LiteralPath $path){[IO.File]::Replace($temp,$path,[NullString]::Value)}else{[IO.File]::Move($temp,$path)}
  } catch { } finally { if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue} }
  if ($codes.Count) {
    $key=(@($codes|Sort-Object -Unique)-join '|')
    $decision=Get-CslMonitorAlertDecision -Key $key -PreviousKey $script:RuntimeAlertKey -LastAlertUtc $script:RuntimeLastAlertUtc -CooldownMinutes ([int]$cfg.monitorAlertCooldownMin)
    if($decision -eq 'notify'){
      $script:RuntimeAlertKey=$key;$script:RuntimeLastAlertUtc=[datetime]::UtcNow
      Write-Log '[risk-monitor] client connection or account signal requires review'
      Show-Alert 'Claude 观测提醒' '已观测到客户端连接偏差或近期日志告警，请查看检查面板。连接观测为只读，不会断开连接或关闭 Claude。'
    }
  } else {
    $script:RuntimeAlertKey=''
  }
}

try {
  if ($Once) { Invoke-Check; exit 0 }
  $waited = 0
  while (-not (Get-ClaudeProcesses) -and $waited -lt 90) { Start-Sleep -Seconds 3; $waited += 3 }
  if (-not (Get-ClaudeProcesses)) { exit 0 }
  $interval = [Math]::Max(1, [int]$cfg.monitorIntervalMin) * 60
  $riskInterval=[Math]::Max(15,[int]$cfg.riskMonitorIntervalSec)
  $nextStandard=[datetime]::MinValue;$nextRisk=[datetime]::MinValue
  Write-Log "$tag started | interval=$interval | autoRepair=$([bool]$cfg.monitorAutoRepair)"
  while ($true) {
    if([datetime]::UtcNow -ge $nextStandard){Invoke-Check;$nextStandard=[datetime]::UtcNow.AddSeconds($interval)}
    if([datetime]::UtcNow -ge $nextRisk){Invoke-RuntimeRiskCheck;$nextRisk=[datetime]::UtcNow.AddSeconds($riskInterval)}
    Start-Sleep -Seconds 5
    if (-not (Get-ClaudeProcesses)) { Write-Log "$tag Claude exited"; exit 0 }
  }
} finally { try { $mutex.ReleaseMutex() } catch {}; $mutex.Dispose() }
