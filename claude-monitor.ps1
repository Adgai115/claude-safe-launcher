<#
  Claude 运行期间后台监控（由 claude-preflight.ps1 在启动 Claude 后隐藏运行）
  每 monitorIntervalMin 分钟检查：Claude 边缘看到的出口 IP、Claude 策略组节点。
  变化时：尝试切回 → 仍不对则弹出提醒；monitorKillOnChange=true 时关闭 Claude。
  Claude 退出后自动结束。单实例（互斥锁）。
  测试: powershell -NoProfile -ExecutionPolicy Bypass -File claude-monitor.ps1 -Once -DryRun
#>
param([switch]$Once, [switch]$DryRun, [switch]$HideIp)
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'claude-common.ps1')
$cfg = Load-Config
$tag = '[monitor]' + $(if ($DryRun) { '[DryRun]' } else { '' })
# R4b：-HideIp（由 preflight -HideIp 传入）时，监控写进 preflight.log 的行、-Once 屏幕输出和提醒文字里的公网 IP 遮成 <出口IP>
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'claude-issueexport.ps1')
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'claude-rules.ps1')
$script:MonHideIp = [bool]$HideIp
function Write-CslMonLog([string]$Line) { Write-Log (Format-CslPreflightLogLine $Line -HideIp:$script:MonHideIp) }

function Out-Mon([string]$t, [string]$color = 'Gray') {
  if ($Once) { Write-Host (Format-CslPreflightLogLine $t -HideIp:$script:MonHideIp) -ForegroundColor $color }
}

$created = $false
$mutex = New-Object Threading.Mutex($false, 'Local\ClaudePreflightMonitor')
try { $created = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $created = $true }
if (-not $created) { Write-CslMonLog "$($tag) 已有监控实例在运行，本实例退出"; Out-Mon '已有监控实例在运行，退出' 'Yellow'; exit 0 }

function Show-Alert([string]$title, [string]$text) {
  $text = Format-CslPreflightLogLine $text -HideIp:$script:MonHideIp
  try {
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $t = [Security.SecurityElement]::Escape($title); $b = [Security.SecurityElement]::Escape($text)
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml("<toast scenario='reminder'><visual><binding template='ToastGeneric'><text>$($t)</text><text>$($b)</text></binding></visual><actions><action content='知道了' arguments='ok'/></actions></toast>")
    $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show((New-Object Windows.UI.Notifications.ToastNotification($xml)))
  } catch {
    try { [void](New-Object -ComObject WScript.Shell).Popup($text, 120, $title, 0x30 + 0x40000) } catch {}
  }
}

function Test-State {
  $r = [ordered]@{ node = $null; ctlOk = $false; ip = $null; loc = $null; problems = @() }
  $g = Ctl-GetGroup $cfg $cfg.claudeGroup
  if ($g) { $r.ctlOk = $true; $r.node = $g.now; if ($cfg.expectedNode -and $g.now -ne $cfg.expectedNode) { $r.problems += "Claude 组节点变为 $($g.now)" } }
  $tr = Get-Trace 'https://claude.ai/cdn-cgi/trace'
  $r.ip = $tr['ip']; $r.loc = $tr['loc']
  if (-not $r.ip) { $r.problems += 'claude.ai trace 无响应' }
  elseif ($cfg.expectedIp -and ($r.ip -ne $cfg.expectedIp -or $r.loc -ne $cfg.expectedLoc)) { $r.problems += "Claude 看到的 IP 变为 $($r.ip) loc=$($r.loc)" }
  return $r
}

function Invoke-Check {
  $s = Test-State
  $ctlTxt = $(if ($s.ctlOk) { "node=$($s.node)" } else { 'node=控制器不可达' })
  if ($s.problems.Count -eq 0) {
    Out-Mon "正常: ip=$($s.ip) loc=$($s.loc) $($ctlTxt)" 'Green'
    if ($Once) { Write-CslMonLog "$($tag) OK | ip=$($s.ip) | $($ctlTxt)" }
    return
  }
  $p = $s.problems -join '; '
  Write-CslMonLog "$($tag) CHANGE | $($p)"
  Out-Mon "发现变化: $($p)" 'Yellow'
  if ($DryRun) {
    $plan = @()
    if ($s.ctlOk) { $plan += "PUT 切回 $($cfg.claudeGroup)/$($cfg.mainGroup) → $($cfg.expectedNode)" } else { $plan += '控制器不可达，无法自动切回' }
    $plan += '若仍不对：弹出 Windows 提醒'
    if ($cfg.monitorKillOnChange) { $plan += '并关闭 Claude（monitorKillOnChange=true）' }
    Write-CslMonLog "$($tag) 将执行(未执行): $($plan -join ' → ')"
    Out-Mon ("[DryRun] 将执行(未执行): " + ($plan -join ' → ')) 'Cyan'
    return
  }
  if ($s.ctlOk -and $cfg.expectedNode) {
    [void](Ctl-SelectNode $cfg $cfg.claudeGroup $cfg.expectedNode)
    if ($cfg.pinMainGroup -and $cfg.mainGroup) { [void](Ctl-SelectNode $cfg $cfg.mainGroup $cfg.expectedNode) }
    Start-Sleep -Seconds 3
    $s2 = Test-State
    if ($s2.problems.Count -eq 0) { Write-CslMonLog "$($tag) FIXED | 已切回 $($cfg.expectedNode) ip=$($s2.ip)"; Show-Alert 'Claude 监控' "节点曾被切换，已自动切回 $($cfg.expectedNode)（IP $($s2.ip)）"; return }
    $p = $s2.problems -join '; '
  }
  Write-CslMonLog "$($tag) STILL-WRONG | $($p)"
  Show-Alert 'Claude 出口异常' "$($p)。请检查 Clash 节点，期望 IP $($cfg.expectedIp)。"
  if ($cfg.monitorKillOnChange) {
    $procs = @(Get-ClaudeProcesses)
    foreach ($pr in $procs) { try { Stop-Process -Id $pr.ProcessId -Force -ErrorAction Stop } catch {} }
    Write-CslMonLog "$($tag) KILLED Claude ($($procs.Count) 个进程)"
  }
}

try {
  if ($Once) { Invoke-Check; exit 0 }
  $waited = 0
  while (-not (Get-ClaudeProcesses) -and $waited -lt 90) { Start-Sleep -Seconds 3; $waited += 3 }
  if (-not (Get-ClaudeProcesses)) { Write-CslMonLog "$($tag) 90 秒内未检测到 Claude，监控退出"; exit 0 }
  $interval = [Math]::Max(1, [int]$cfg.monitorIntervalMin) * 60
  Write-CslMonLog "$($tag) 开始监控，间隔 $([int]($interval/60)) 分钟"
  while ($true) {
    Invoke-Check
    $slept = 0
    while ($slept -lt $interval) {
      Start-Sleep -Seconds 15; $slept += 15
      if (-not (Get-ClaudeProcesses)) { Write-CslMonLog "$($tag) Claude 已退出，监控结束"; exit 0 }
    }
  }
} finally {
  try { $mutex.ReleaseMutex() } catch {}
  $mutex.Dispose()
}
