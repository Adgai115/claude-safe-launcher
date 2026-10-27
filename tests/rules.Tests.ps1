#Requires -Version 5.1
# 规则目录 + 单一评分单元测试
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File tests\rules.Tests.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
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

Write-Host ''
if ($script:Fail -gt 0 -or $script:Uncaught -gt 0) {
  Write-Host "FAILED: $($script:Fail) assertion(s), $($script:Uncaught) uncaught error(s)" -ForegroundColor Red
  exit 1
}
Write-Host 'ALL PASSED' -ForegroundColor Green
exit 0
