#Requires -Version 5.1
# 规则目录 + 单一评分单元测试
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File tests\rules.Tests.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'claude-rules.ps1')

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
$tun = Get-CslRuleById -Catalog $cat -Id 'net.tun'
Assert-True ($tun.checks -match 'tun\.enable') 'tun uses Clash tun.enable'
$https = Get-CslRuleById -Catalog $cat -Id 'cfg.https_proxy'
Assert-Eq $https.severity 'info' 'https_proxy info'
Assert-Eq $https.refDeduction 0 'https_proxy 0'
$desk = Get-CslRuleById -Catalog $cat -Id 'cfg.claude_desktop'
Assert-Eq $desk.refDeduction 0 'desktop 0'
$risk = Get-CslRuleById -Catalog $cat -Id 'exit.ip_risk_proxycheck'
Assert-Eq $risk.refDeduction 0 'ip risk 0'
$envu = Get-CslRuleById -Catalog $cat -Id 'cfg.env_relay_user'
Assert-True ($envu.platforms -contains 'win') 'envfix platforms include win'
Assert-True (-not ($envu.platforms -contains 'mac')) 'envfix platforms exclude mac (manual only)'

Write-Host '== Severity enum ==' -ForegroundColor Cyan
$allowed = @('must_fix','should_fix','info')
$bad = @($cat.checks | Where-Object { $allowed -notcontains [string]$_.severity })
Assert-Eq $bad.Count 0 'all severities in enum'

Write-Host '== Score: must_fix blocks launch ==' -ForegroundColor Cyan
$r = Get-CslRulesScore -Catalog $cat -Results @(
  [pscustomobject]@{ id = 'net.tun'; status = 'failed' }
)
Assert-Eq $r.score 75 'tun fail deducts 25'
Assert-True (-not $r.canLaunchSafely) 'must_fix failed → unsafe'
Assert-Eq $r.summary.must_fix_failed 1 'one must_fix'

Write-Host '== Score: should_fix does not block ==' -ForegroundColor Cyan
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
# Three static should_fix fails with 5+5+… — use overrides so we exceed 20
$staticResults = @(
  [pscustomobject]@{ id = 'net.browser_webrtc_chromium'; status = 'failed'; refDeductionOverride = 10 },
  [pscustomobject]@{ id = 'net.browser_webrtc_firefox'; status = 'failed'; refDeductionOverride = 10 },
  [pscustomobject]@{ id = 'locale.browser_lang_static'; status = 'failed'; refDeductionOverride = 10 }
)
$r4 = Get-CslRulesScore -Catalog $cat -Results $staticResults
Assert-Eq $r4.browserCap.staticWarnSumBeforeCap 30 'before cap 30'
Assert-Eq $r4.browserCap.staticWarnSumAfterCap 20 'after cap 20'
Assert-Eq $r4.score 80 'score after cap'
Assert-True $r4.canLaunchSafely 'static warns do not block'

Write-Host '== Score: override + mixed ==' -ForegroundColor Cyan
$r5 = Get-CslRulesScore -Catalog $cat -Results @(
  [pscustomobject]@{ id = 'net.ipv6_leak'; status = 'failed' },
  [pscustomobject]@{ id = 'net.dns_fakeip'; status = 'failed' },
  [pscustomobject]@{ id = 'locale.system_lang'; status = 'info' },
  [pscustomobject]@{ id = 'net.clash_running'; status = 'passed' }
)
Assert-Eq $r5.score 65 '25+10=35 → 65'
Assert-True (-not $r5.canLaunchSafely) 'ipv6 must_fix blocks'
Assert-Eq $r5.summary.passed 1 'one passed'

Write-Host '== JSON shape (current/expected/recheck) ==' -ForegroundColor Cyan
$row = @($r5.checks | Where-Object id -eq 'net.ipv6_leak')[0]
Assert-True ($null -ne $row.current -or $row.current -eq '') 'current field present'
Assert-True ($null -ne $row.expected) 'expected field present'
Assert-True ($null -ne $row.recheck) 'recheck field present'
$payload = New-CslPreflightResult -ScoreResult $r5 -Platform 'win' -Verdict 'blocked'
Assert-Eq $payload.verdict 'blocked' 'verdict blocked'
Assert-Eq $payload.schemaVersion 1 'schemaVersion'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("csl-preflight-result-" + [guid]::NewGuid().ToString('n') + '.json')
Write-CslPreflightResultJson -Result $payload -Path $tmp | Out-Null
Assert-True (Test-Path $tmp) 'json written'
$loaded = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-Eq $loaded.score $r5.score 'round-trip score'
Assert-True ($loaded.checks.Count -ge 1) 'checks array'
# no BOM
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
if ($script:Fail -gt 0) {
  Write-Host "FAILED: $($script:Fail) assertion(s)" -ForegroundColor Red
  exit 1
}
Write-Host 'All rules tests passed.' -ForegroundColor Green
exit 0
