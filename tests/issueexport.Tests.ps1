#Requires -Version 5.1
# 问题说明导出单元测试（不碰真实系统，不调用 agent）
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File tests\issueexport.Tests.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'claude-common.ps1')
. (Join-Path $root 'claude-issueexport.ps1')
# claude-common.ps1 sets Continue when dot-sourced; restore Stop so non-terminating errors also hit the trap
$ErrorActionPreference = 'Stop'
# Any uncaught error counts as a failure
$script:Uncaught = 0
trap {
  $script:Uncaught++
  Write-Host ("  FAIL  uncaught error: {0} (line {1})" -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber) -ForegroundColor Red
  continue
}

$script:Fail = 0
function Assert-True($cond, $msg) {
  if ($cond) { Write-Host "  PASS  $msg" -ForegroundColor Green }
  else { Write-Host "  FAIL  $msg" -ForegroundColor Red; $script:Fail++ }
}
function Assert-Eq($a, $b, $msg) {
  if ("$a" -eq "$b") { Write-Host "  PASS  $msg" -ForegroundColor Green }
  else { Write-Host "  FAIL  $msg (got=[$a] expected=[$b])" -ForegroundColor Red; $script:Fail++ }
}
function Assert-Contains($hay, $needle, $msg) {
  if (("" + $hay).Contains([string]$needle)) { Write-Host "  PASS  $msg" -ForegroundColor Green }
  else { Write-Host "  FAIL  $msg (missing [$needle] in [$hay])" -ForegroundColor Red; $script:Fail++ }
}
function Assert-NotContains($hay, $needle, $msg) {
  if (-not (("" + $hay).Contains([string]$needle))) { Write-Host "  PASS  $msg" -ForegroundColor Green }
  else { Write-Host "  FAIL  $msg (unexpected [$needle] in [$hay])" -ForegroundColor Red; $script:Fail++ }
}

$up = 'C:\Users\Adgai'
$pc = 'DESKTOP-SECRET'
$exitIp = '203.0.113.44'

Write-Host '== Protect-CslIssueValue masking ==' -ForegroundColor Cyan
$p1 = Protect-CslIssueValue -Value "$up\AppData\Local\Claude\config.json" -UserProfile $up -ComputerName $pc
Assert-Contains $p1 '%USERPROFILE%' 'path username -> %USERPROFILE%'
Assert-NotContains $p1 'Adgai' 'username not leaked in path'

$p2 = Protect-CslIssueValue -Value "host=$pc timezone ok" -UserProfile $up -ComputerName $pc
Assert-Contains $p2 '<PC>' 'computer name -> <PC>'
Assert-NotContains $p2 $pc 'raw computer name not leaked'

$sub = 'https://cdn.example-provider.com/subscribe?token=abc123secret'
$p3 = Protect-CslIssueValue -Value "订阅 $sub" -UserProfile $up -ComputerName $pc
Assert-Contains $p3 '<订阅链接>' 'subscription URL fully masked'
Assert-NotContains $p3 'abc123secret' 'subscription token not leaked'
Assert-NotContains $p3 'example-provider' 'subscription host not leaked'

$p4 = Protect-CslIssueValue -Value '节点 relay-us.evil-node.com:443' -UserProfile $up -ComputerName $pc
Assert-Contains $p4 '<节点>' 'node domain fully masked'
Assert-NotContains $p4 'evil-node' 'node host not leaked'

$sec = Protect-CslIssueValue -Value 'controllerSecret=super-secret-bearer-token-value' -UserProfile $up -ComputerName $pc
Assert-NotContains $sec 'super-secret-bearer-token-value' 'controller secret not leaked'
Assert-Contains $sec 'controllerSecret=' 'keeps key name'
Assert-True ($sec -match '\*\*\*\*') 'secret uses Protect-Secret style mask'

Write-Host '== Exit IP keep vs HideIp ==' -ForegroundColor Cyan
$keep = Protect-CslIssueValue -Value "出口 IP $exitIp" -UserProfile $up -ComputerName $pc
Assert-Contains $keep $exitIp 'exit IP kept by default'
$hid = Protect-CslIssueValue -Value "出口 IP $exitIp" -HideIp -UserProfile $up -ComputerName $pc
Assert-Contains $hid '<出口IP>' 'exit IP masked with -HideIp'
Assert-NotContains $hid $exitIp 'raw exit IP absent when HideIp'

$fake = Protect-CslIssueValue -Value 'DNS 198.18.0.24' -HideIp -UserProfile $up -ComputerName $pc
Assert-Contains $fake '198.18.0.24' 'fake-ip range kept even with HideIp'

Write-Host '== Four-part structure + fixed lines ==' -ForegroundColor Cyan
$one = Format-CslIssueDescription -Group '4. 出口 IP 三方对比（本机实测 / 期望 / Claude 边缘）' -Level 'FAIL' -Text "本机 $exitIp ≠ 期望 198.51.100.9" -UserProfile $up -ComputerName $pc
Assert-Contains $one $script:CslIssueIpNotice 'opening IP notice when IP kept'
Assert-Contains $one '问题:' 'has 问题'
Assert-Contains $one '当前状态:' 'has 当前状态'
Assert-Contains $one '期望状态:' 'has 期望状态'
Assert-Contains $one '复查命令:' 'has 复查命令'
Assert-Contains $one $script:CslIssueClosing 'fixed closing line'
Assert-Contains $one $exitIp 'current state keeps exit IP'
Assert-True ($one.TrimEnd().EndsWith($script:CslIssueClosing)) 'closes with fixed line'

$oneHide = Format-CslIssueDescription -Group '4. 出口 IP 三方对比' -Level 'FAIL' -Text "本机 $exitIp" -HideIp -UserProfile $up -ComputerName $pc
Assert-NotContains $oneHide $script:CslIssueIpNotice 'no IP notice when HideIp'
Assert-NotContains $oneHide $exitIp 'HideIp omits raw exit IP in description'
Assert-Contains $oneHide '<出口IP>' 'HideIp uses placeholder in description'
Assert-Contains $oneHide $script:CslIssueClosing 'closing line still present with HideIp'

Write-Host '== Pack formatting ==' -ForegroundColor Cyan
$items = @(
  [pscustomobject]@{ Level = 'FAIL'; Text = "出口 $exitIp"; Group = '4. 出口 IP 三方对比' },
  [pscustomobject]@{ Level = 'WARN'; Text = "浏览器时区 Asia/Shanghai（期望 America/New_York）"; Group = '12. 浏览器环境' },
  [pscustomobject]@{ Level = 'PASS'; Text = 'should skip'; Group = '1. Clash' }
)
$pack = Format-CslIssuePack -Items $items -UserProfile $up -ComputerName $pc
Assert-Contains $pack $script:CslIssueIpNotice 'pack has single IP notice'
Assert-Eq (($pack -split [regex]::Escape($script:CslIssueIpNotice)).Count - 1) 1 'IP notice appears once in pack'
Assert-Contains $pack '---- 问题 1 ----' 'pack item 1'
Assert-Contains $pack '---- 问题 2 ----' 'pack item 2'
Assert-NotContains $pack 'should skip' 'PASS rows excluded'
Assert-Contains $pack $script:CslIssueClosing 'pack keeps closing line'

$packHide = Format-CslIssuePack -Items $items -HideIp -UserProfile $up -ComputerName $pc
Assert-NotContains $packHide $script:CslIssueIpNotice 'HideIp pack omits notice'
Assert-NotContains $packHide $exitIp 'HideIp pack omits raw IP'

$empty = Format-CslIssuePack -Items @([pscustomobject]@{ Level = 'PASS'; Text = 'ok'; Group = '1. x' }) -UserProfile $up -ComputerName $pc
Assert-Contains $empty '没有失败或警告' 'empty pack message'

Write-Host '== No secret / token leakage in formatted text ==' -ForegroundColor Cyan
$bad = Format-CslIssueDescription -Group '3. 节点锁定' -Level 'FAIL' -Text "controllerSecret=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef 节点 badnode.example.com" -UserProfile $up -ComputerName $pc
Assert-NotContains $bad 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef' '64-hex token redacted'
Assert-NotContains $bad 'controllerSecret=deadbeef' 'secret assignment not verbatim'
Assert-Contains $bad '<节点>' 'node domain masked in formatted issue'

Write-Host ''
if ($script:Fail -gt 0 -or $script:Uncaught -gt 0) {
  Write-Host "FAILED: $($script:Fail) assertion(s), $($script:Uncaught) uncaught error(s)" -ForegroundColor Red
  exit 1
}
Write-Host 'ALL PASSED' -ForegroundColor Green
exit 0
