#Requires -Version 5.1
# 规则目录 + 单一评分单元测试
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File tests\rules.Tests.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
# 与 claude-preflight.ps1 相同的加载顺序：common、envfix、rules
. (Join-Path $root 'claude-common.ps1')
. (Join-Path $root 'claude-envfix.ps1')
. (Join-Path $root 'claude-rules.ps1')
# Restore Stop after dot-sourcing so non-terminating errors also hit the trap
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

Write-Host '== StrictMode not leaked to caller ==' -ForegroundColor Cyan
$probe = New-Object psobject
$leak = $null
try { $null = $probe.PSObject.Properties.Name; $null = $probe.NoSuchProp } catch { $leak = $_.FullyQualifiedErrorId }
Assert-True ($null -eq $leak) "dot-sourcing claude-rules.ps1 leaves caller non-strict (err=[$leak])"
$rulesSrc = Get-Content (Join-Path $root 'claude-rules.ps1') -Raw -Encoding UTF8
Assert-True (-not ($rulesSrc -match '(?m)^\s*Set-StrictMode')) 'claude-rules.ps1 has no script-level Set-StrictMode'

Write-Host '== Catalog load ==' -ForegroundColor Cyan
$cat = Get-CslRulesCatalog
Assert-Eq $cat.rulesVersion '4.0.0' 'rulesVersion'
Assert-Eq $cat.checks.Count 32 '32 checks'
Assert-Eq $cat.scoring.staticBrowserCap 20 'staticBrowserCap'
$ids = @($cat.checks | ForEach-Object { [string]$_.id })
Assert-Eq ($ids | Select-Object -Unique).Count 32 'unique ids'
$api = Get-CslRuleById -Catalog $cat -Id 'exit.api_anthropic'
Assert-True ($null -ne $api) 'api rule exists'
Assert-Eq $api.category 'proxy-net' 'api.anthropic category=proxy-net'

Write-Host '== fixType / fixId / containsIp / no fixable ==' -ForegroundColor Cyan
$allowedFt = @('none','confirm','manual')
$badFt = @($cat.checks | Where-Object { $allowedFt -notcontains [string]$_.fixType })
Assert-Eq $badFt.Count 0 'fixType enum'
$withFixable = @($cat.checks | Where-Object { $null -ne $_.PSObject.Properties['fixable'] })
Assert-Eq $withFixable.Count 0 'no fixable field'
$envu = Get-CslRuleById -Catalog $cat -Id 'cfg.env_relay_user'
Assert-Eq $envu.fixType 'confirm' 'envfix fixType=confirm'
Assert-Eq $envu.fixId 'envfix.user-anthropic' 'envfix fixId'
Assert-True (-not ($envu.platforms -contains 'mac')) 'envfix platforms exclude mac'
$tun = Get-CslRuleById -Catalog $cat -Id 'net.tun'
Assert-Eq $tun.fixType 'manual' 'tun manual'
Assert-True ($null -eq $tun.fixId -or [string]$tun.fixId -eq '') 'tun fixId empty'
$ip = Get-CslRuleById -Catalog $cat -Id 'exit.three_way_ip'
Assert-True ([bool]$ip.containsIp) 'three_way containsIp'
$noip = Get-CslRuleById -Catalog $cat -Id 'net.controller'
Assert-True (-not [bool]$noip.containsIp) 'controller not containsIp'

Write-Host '== Severity enum ==' -ForegroundColor Cyan
$allowed = @('must_fix','should_fix','info')
$bad = @($cat.checks | Where-Object { $allowed -notcontains [string]$_.severity })
Assert-Eq $bad.Count 0 'all severities in enum'

Write-Host '== Score: must_fix failed blocks ==' -ForegroundColor Cyan
$r = Get-CslRulesScore -Catalog $cat -Results @(
  [pscustomobject]@{ id = 'net.tun'; status = 'failed' }
)
Assert-Eq $r.score 75 'tun fail deducts 25'
Assert-True (-not $r.canLaunchSafely) 'must_fix failed → unsafe'
Assert-Eq $r.summary.must_fix_failed 1 'one must_fix'
Assert-Eq $r.summary.error 0 'error count 0'

Write-Host '== Score: error deducts 0; must_fix error → blocked ==' -ForegroundColor Cyan
$re = Get-CslRulesScore -Catalog $cat -Results @(
  [pscustomobject]@{ id = 'net.tun'; status = 'error'; current = 'Clash config unreadable (masked)' }
)
Assert-Eq $re.score 100 'error never deducts'
Assert-True (-not $re.canLaunchSafely) 'must_fix error → unsafe'
Assert-Eq $re.summary.error 1 'summary.error=1'
Assert-Eq $re.summary.must_fix_failed 0 'error is not failed'
$rowE = @($re.checks | Where-Object id -eq 'net.tun')[0]
Assert-Eq $rowE.status 'error' 'row status error'
Assert-True ($rowE.current -match 'unreadable') 'error current has reason'
$payloadE = New-CslPreflightResult -ScoreResult $re -Platform 'win'
Assert-Eq $payloadE.verdict 'blocked' 'must_fix error → verdict blocked'

Write-Host '== Score: should_fix error does not block ==' -ForegroundColor Cyan
$re2 = Get-CslRulesScore -Catalog $cat -Results @(
  [pscustomobject]@{ id = 'net.controller'; status = 'error'; current = 'timeout' }
)
Assert-Eq $re2.score 100 'should_fix error 0 deduction'
Assert-True $re2.canLaunchSafely 'should_fix error still safe'
Assert-Eq $re2.summary.error 1 'error counted'

Write-Host '== Score: should_fix failed does not block ==' -ForegroundColor Cyan
$r2 = Get-CslRulesScore -Catalog $cat -Results @(
  [pscustomobject]@{ id = 'net.controller'; status = 'failed' }
)
Assert-Eq $r2.score 90 'controller deducts 10'
Assert-True $r2.canLaunchSafely 'should_fix still safe'

Write-Host '== Score: hint-only 0 ==' -ForegroundColor Cyan
$r3 = Get-CslRulesScore -Catalog $cat -Results @(
  [pscustomobject]@{ id = 'cfg.https_proxy'; status = 'failed' },
  [pscustomobject]@{ id = 'exit.ip_risk_proxycheck'; status = 'failed' },
  [pscustomobject]@{ id = 'cfg.claude_desktop'; status = 'failed' }
)
Assert-Eq $r3.score 100 'hint-only no deduction'
Assert-True $r3.canLaunchSafely 'info fails still safe'

Write-Host '== Score: static browser cap 20 ==' -ForegroundColor Cyan
$staticResults = @(
  [pscustomobject]@{ id = 'net.browser_webrtc_chromium'; status = 'failed'; refDeductionOverride = 10 },
  [pscustomobject]@{ id = 'net.browser_webrtc_firefox'; status = 'failed'; refDeductionOverride = 10 },
  [pscustomobject]@{ id = 'locale.browser_lang_static'; status = 'failed'; refDeductionOverride = 10 }
)
$r4 = Get-CslRulesScore -Catalog $cat -Results $staticResults
Assert-Eq $r4.browserCap.staticWarnSumBeforeCap 30 'before cap 30'
Assert-Eq $r4.browserCap.staticWarnSumAfterCap 20 'after cap 20'
Assert-Eq $r4.score 80 'score after cap'

Write-Host '== Enriched fixType/fixId/containsIp ==' -ForegroundColor Cyan
$r5 = Get-CslRulesScore -Catalog $cat -Results @(
  [pscustomobject]@{ id = 'cfg.env_relay_user'; status = 'failed' },
  [pscustomobject]@{ id = 'exit.three_way_ip'; status = 'failed' }
)
$envRow = @($r5.checks | Where-Object id -eq 'cfg.env_relay_user')[0]
Assert-Eq $envRow.fixType 'confirm' 'enriched fixType'
Assert-Eq $envRow.fixId 'envfix.user-anthropic' 'enriched fixId'
Assert-True ($null -eq $envRow.PSObject.Properties['fixable']) 'enriched has no fixable'
$ipRow = @($r5.checks | Where-Object id -eq 'exit.three_way_ip')[0]
Assert-True ([bool]$ipRow.containsIp) 'enriched containsIp'
Assert-True (-not $r5.canLaunchSafely) 'env+ip must_fix blocks'
Assert-Eq $r5.summary.error 0 'no errors in this case'

Write-Host '== JSON shape ==' -ForegroundColor Cyan
$payload = New-CslPreflightResult -ScoreResult $r5 -Platform 'win' -Verdict 'blocked'
Assert-Eq $payload.schemaVersion 1 'schemaVersion'
Assert-Eq $payload.verdict 'blocked' 'verdict'
Assert-True ($null -ne $payload.summary.error) 'summary.error present'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("csl-preflight-result-" + [guid]::NewGuid().ToString('n') + '.json')
Write-CslPreflightResultJson -Result $payload -Path $tmp | Out-Null
$loaded = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-Eq $loaded.score $r5.score 'round-trip score'
Assert-Eq $loaded.summary.error 0 'round-trip error count'
$bytes = [IO.File]::ReadAllBytes($tmp)
Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'json no BOM'
Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

Write-Host '== node_lock runtime override (info/0) ==' -ForegroundColor Cyan
$r6 = Get-CslRulesScore -Catalog $cat -Results @(
  [pscustomobject]@{ id = 'net.node_lock'; status = 'failed'; severityOverride = 'info'; refDeductionOverride = 0 }
)
Assert-Eq $r6.score 100 'no policy group → 0'
Assert-True $r6.canLaunchSafely 'info override safe'

Write-Host '== JSON current: env items output names only (CSL_TEST_CANARY) ==' -ForegroundColor Cyan
# preflight 不能在测试里整体运行（curl.exe / 注册表 / 网络），改为从 preflight 源文件取同一批函数（真实的 item 文本 + JSON 映射）
$pfAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'claude-preflight.ps1'), [ref]$null, [ref]$null)
foreach ($fnName in @('Format-CslEnvUserItemText', 'Get-CslJsonCurrent', 'New-CslScoreMappedResults')) {
  $fnAst = $pfAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }, $true) | Select-Object -First 1
  Assert-True ($null -ne $fnAst) "preflight defines $fnName"
  if ($fnAst) { . ([scriptblock]::Create($fnAst.Extent.Text)) }
}
$canaryName = 'CSL_TEST_CANARY'
$canaryVal = 'csl-canary-9f3a'
$prevCanary = [Environment]::GetEnvironmentVariable($canaryName)
$jsonTmp = Join-Path ([IO.Path]::GetTempPath()) ("csl-canary-result-" + [guid]::NewGuid().ToString('n') + '.json')
try {
  [Environment]::SetEnvironmentVariable($canaryName, $canaryVal)
  $canaryStore = [pscustomobject]@{
    ListUserNames    = { @('CSL_TEST_CANARY') }
    ListMachineNames = { @() }
    GetMachine       = { param($n) $null }
    GetUserEntry     = { param($n) $v = [Environment]::GetEnvironmentVariable($n); if ($null -eq $v) { $null } else { @{ Value = $v; Kind = 'String' } } }
  }
  $found = Find-CslRelayEnvTargets -Patterns @('CSL_TEST_CANARY') -TestMode -Store $canaryStore
  Assert-True ($found.ok -and @($found.user).Count -eq 1) 'canary shows up as an env target'
  $canaryItems = New-Object System.Collections.ArrayList
  foreach ($u in $found.user) {
    $shown = Format-CslEnvUserItemText $u.Name $u.Value
    # screen/CLI text keeps the masked value (unchanged); proves the canary row is a real masked item
    Assert-True ($shown -like '*CSL_TEST_CANARY=*' -and $shown.Contains('*')) 'screen text still has NAME=masked'
    Assert-True (-not $shown.Contains($canaryVal)) 'screen text does not carry the raw canary'
    [void]$canaryItems.Add([pscustomobject]@{ Level = 'FAIL'; Text = $shown; Weight = 25; Group = '9. 环境变量' })
  }
  # an HTTPS_PROXY-style NAME=masked-url text goes through the same mapping
  [void]$canaryItems.Add([pscustomobject]@{ Level = 'WARN'; Text = ('HTTPS_PROXY={0}' -f (Mask-Value -Value 'http://csl-canary-9f3a@127.0.0.1:7890' -Kind Url)); Weight = 5; Group = '9. 环境变量' })
  $mapped = New-CslScoreMappedResults $canaryItems
  Assert-Eq @($mapped).Count 2 'mapping keeps one result per item'
  $cur0 = [string]@($mapped)[0].current
  $cur1 = [string]@($mapped)[1].current
  Assert-Eq $cur0 '用户级 CSL_TEST_CANARY：已设置' 'env item current = name + status only'
  Assert-True ($cur0.Contains('CSL_TEST_CANARY')) 'env item current has the variable name'
  Assert-True (-not $cur0.Contains($canaryVal)) 'env item current has no canary value'
  Assert-True (-not $cur0.Contains('*')) 'env item current has no *'
  Assert-True (-not $cur0.Contains('=')) 'env item current has no ='
  Assert-Eq $cur1 'HTTPS_PROXY：已设置' 'NAME=value text current = name + status only'
  Assert-True (-not $cur1.Contains('*') -and -not $cur1.Contains('=') -and -not $cur1.Contains('canary')) 'NAME=value current has no value, no *, no ='
  # 兜底：没有 NAME= 形态、但仍带 * 的遗漏文本，也不能把 * 带进 current
  $stray = Get-CslJsonCurrent 'proxy sk-ant***9f3a leaked'
  Assert-True (-not $stray.Contains('*') -and -not $stray.Contains('9f3a')) 'stray masked token is scrubbed from current'
  # real JSON path: score -> payload -> file
  $canaryScore = Get-CslRulesScore -Catalog $cat -Results @($mapped)
  $canaryPayload = New-CslPreflightResult -ScoreResult $canaryScore -Platform 'win' -Verdict 'blocked'
  Write-CslPreflightResultJson -Result $canaryPayload -Path $jsonTmp | Out-Null
  $jsonRaw = [IO.File]::ReadAllText($jsonTmp, (New-Object System.Text.UTF8Encoding($false)))
  Assert-True (-not $jsonRaw.Contains($canaryVal)) 'JSON file has no canary value'
  Assert-True (-not $jsonRaw.Contains('*')) 'JSON file has no *'
  Assert-True ($jsonRaw.Contains('CSL_TEST_CANARY')) 'JSON file has the variable name'
  $canaryRow = @(($jsonRaw | ConvertFrom-Json).checks | Where-Object id -eq 'item.1')[0]
  Assert-Eq $canaryRow.current '用户级 CSL_TEST_CANARY：已设置' 'JSON checks[item.1].current = name + status only'
  Assert-Eq $canaryRow.fixId 'envfix.user-anthropic' 'env item keeps fixId in JSON'
}
finally {
  [Environment]::SetEnvironmentVariable($canaryName, $prevCanary)
  Remove-Item -LiteralPath $jsonTmp -Force -ErrorAction SilentlyContinue
}
Assert-Eq ([string][Environment]::GetEnvironmentVariable($canaryName)) ([string]$prevCanary) 'canary variable cleaned up (restored to previous state)'

Write-Host ''
if ($script:Fail -gt 0 -or $script:Uncaught -gt 0) {
  Write-Host "FAILED: $($script:Fail) assertion(s), $($script:Uncaught) uncaught error(s)" -ForegroundColor Red
  exit 1
}
Write-Host 'ALL PASSED' -ForegroundColor Green
exit 0
