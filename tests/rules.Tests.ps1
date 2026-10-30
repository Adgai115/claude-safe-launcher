#Requires -Version 5.1
# 规则目录 + 单一评分单元测试
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File tests\rules.Tests.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
# 与 claude-preflight.ps1 相同的加载顺序：common、envfix、issueexport（JSON current 复用其脱敏）、rules
. (Join-Path $root 'claude-common.ps1')
. (Join-Path $root 'claude-envfix.ps1')
. (Join-Path $root 'claude-issueexport.ps1')
. (Join-Path $root 'claude-rules.ps1')
# Restore Stop after dot-sourcing so non-terminating errors also hit the trap
$ErrorActionPreference = 'Stop'
# Any uncaught error counts as a failure
# Counting rule (R3, same in all test files):
#   (?m)^\s*FAIL(?!ED)\b   counts failed assertions; must equal "N assertion(s)" in the FAILED summary.
#   (?m)^\s*UNCAUGHT\b     counts uncaught errors;    must equal "M uncaught error(s)".
# The summary line starts with FAILED / ALL PASSED and matches neither regex.
$script:Uncaught = 0
trap {
  $script:Uncaught++
  Write-Host ("  UNCAUGHT  {0} (line {1})" -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber) -ForegroundColor Red
  continue
}

$script:Fail = 0
# R4c test-hardening: a failed setup is 1 FAIL (counted by the setup assertion); the assertions that depend on it are
# listed by name as SKIP (not PASS, not FAIL) and the run can never end as ALL PASSED while any SKIP exists.
$script:Skipped = New-Object System.Collections.ArrayList
function Skip-CslDependents([string]$Setup, [string[]]$Names) {
  foreach ($n in $Names) { Write-Host ("  SKIP  {0} (skipped: setup failed: {1})" -f $n, $Setup) -ForegroundColor Yellow; [void]$script:Skipped.Add($n) }
}
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

Write-Host '== First run: Load-Config with no preflight.json ==' -ForegroundColor Cyan
# 空临时目录：没有 preflight.json、没有 clash-verge.yaml；Find-* 用桩函数，避免探测本机。不打印配置内容。
$fr = Join-Path ([IO.Path]::GetTempPath()) ('csl-firstrun-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fr | Out-Null
$savedCfgPath = $script:CfgPath; $savedVergeDir = $script:VergeDir
$savedFind = @{}; foreach ($fn in 'Find-ClaudeApp','Find-ClashExe','Find-NpmGlobalDir') { $savedFind[$fn] = (Get-Item "function:$fn" -ErrorAction SilentlyContinue).ScriptBlock }
$frErr = $null; $frCfg = $null
try {
  $script:CfgPath = Join-Path $fr 'preflight.json'; $script:VergeDir = $fr
  function Find-ClaudeApp { @{ aumid = ''; exe = '' } }
  function Find-ClashExe { '' }
  function Find-NpmGlobalDir { '' }
  $errBefore = $Error.Count
  try { $frCfg = Load-Config } catch { $frErr = $_.FullyQualifiedErrorId }
  if (-not $frErr -and $Error.Count -gt $errBefore) { $frErr = $Error[0].FullyQualifiedErrorId }
  Assert-True ($null -eq $frErr) "first-run Load-Config: 0 errors (err=[$frErr])"
  $want = @('expectedIp','expectedLoc','expectedNode','claudeGroup','mainGroup','pinMainGroup','timezone','expectedTzIana','claudeAumid','claudeExe','clashExe','proxyUrl','controllerUrl','controllerSecret','warnRisk','failRisk','monitorIntervalMin','monitorKillOnChange','npmGlobalDir','fixVarPatterns','envFixEnabled','envFixKeep')
  $haveNames = @(); if ($frCfg) { $haveNames = @($frCfg.PSObject.Properties | ForEach-Object { $_.Name }) }
  $missing = @($want | Where-Object { $haveNames -notcontains $_ })
  Assert-True (($null -ne $frCfg) -and $missing.Count -eq 0) "first-run Load-Config: all $($want.Count) defaults present (missing=[$($missing -join ',')])"
  $written = @(); if (Test-Path $script:CfgPath) { $j = Get-Content $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json; $written = @($j.PSObject.Properties | ForEach-Object { $_.Name }) }
  $missingW = @($want | Where-Object { $written -notcontains $_ })
  Assert-True ((Test-Path $script:CfgPath) -and $missingW.Count -eq 0) "first-run preflight.json written with all defaults (missing=[$($missingW -join ',')])"
} finally {
  $script:CfgPath = $savedCfgPath; $script:VergeDir = $savedVergeDir
  foreach ($fn in $savedFind.Keys) { if ($savedFind[$fn]) { Set-Item "function:script:$fn" $savedFind[$fn] } }
  Remove-Item -Recurse -Force $fr -ErrorAction SilentlyContinue
}

Write-Host '== Catalog load ==' -ForegroundColor Cyan
$cat = Get-CslRulesCatalog
Assert-Eq $cat.rulesVersion '4.0.0' 'rulesVersion'
Assert-Eq @($cat.checks | Where-Object { ([string]$_.id) -notlike 'meta.*' }).Count 33 '33 real checks (32 + browser.check_parse; meta.* reserved ids excluded)'
Assert-Eq $cat.checks.Count 34 '34 catalog entries = 33 checks + reserved meta.unmapped'
Assert-Eq $cat.scoring.staticBrowserCap 20 'staticBrowserCap'
$ids = @($cat.checks | ForEach-Object { [string]$_.id })
Assert-Eq ($ids | Select-Object -Unique).Count 34 'unique ids'
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
foreach ($fnName in @('Format-CslEnvUserItemText', 'Get-CslJsonCurrent', 'New-CslScoreMappedResults', 'Invoke-CslPreflightScoring')) {
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
    # R1: screen/CLI text is name + status only (no masked value any more)
    Assert-True ($shown -ceq '用户级 CSL_TEST_CANARY：已设置（会让 Claude Code 走第三方接口）' -and -not $shown.Contains('*') -and -not $shown.Contains('=')) 'R1 [screen] canary row text is name + status only (replaces the old NAME=masked assertion; no =, no *)'
    Assert-True (-not $shown.Contains($canaryVal)) 'screen text does not carry the raw canary'
    [void]$canaryItems.Add([pscustomobject]@{ Level = 'FAIL'; Text = $shown; Weight = 25; Group = '9. 环境变量'; Id = 'cfg.env_relay_user' })
  }
  # an HTTPS_PROXY-style NAME=masked-url text goes through the same mapping
  [void]$canaryItems.Add([pscustomobject]@{ Level = 'WARN'; Text = ('HTTPS_PROXY={0}' -f (Mask-Value -Value 'http://csl-canary-9f3a@127.0.0.1:7890' -Kind Url)); Weight = 5; Group = '9. 环境变量'; Id = 'cfg.https_proxy' })
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
  $canaryRow = @(($jsonRaw | ConvertFrom-Json).checks | Where-Object id -eq 'cfg.env_relay_user')[0]
  Assert-Eq $canaryRow.current '用户级 CSL_TEST_CANARY：已设置' 'JSON checks[cfg.env_relay_user].current = name + status only'
  Assert-Eq $canaryRow.fixId 'envfix.user-anthropic' 'env item keeps fixId in JSON'
}
finally {
  [Environment]::SetEnvironmentVariable($canaryName, $prevCanary)
  Remove-Item -LiteralPath $jsonTmp -Force -ErrorAction SilentlyContinue
}

Write-Host '== R4 JSON current: paths / PC name / subscription / node / secret / IP masked like issue export ==' -ForegroundColor Cyan
# 全部是假金丝雀值：-UserProfile / -ComputerName 直接注入，不读也不写真实环境变量和注册表
$r4Up = 'C:\Users\cslR4user'
$r4Pc = 'CSLR4-PC77'
$r4SubHost = 'cslr4canary'
$r4SubTok = 'r4tok9Z'
$r4NodeIp = '45.77.10.203'
$r4NodeDom = 'hk1.cslr4node.top'
$r4Secret = 'r4secretQ7w'
$r4ExitIp = '203.0.113.77'
$r4RtcIp = '198.51.100.23'
$r4DnsIp = '192.0.2.44'
$r4Items = @(
  [pscustomobject]@{ Level = 'FAIL'; Text = ("Clash Verge 未运行，{0}\AppData\Local\Clash Verge\clash-verge.exe 不存在（主机 {1}）" -f $r4Up, $r4Pc); Weight = 25; Group = '2. 代理'; Id = 'net.clash_running' }
  [pscustomobject]@{ Level = 'WARN'; Text = ("外部控制器 http://127.0.0.1:9097 无法连接 controllerSecret={0} 订阅 https://sub.{1}.xyz/api/v1/client/subscribe?token={2}" -f $r4Secret, $r4SubHost, $r4SubTok); Weight = 10; Group = '3. 节点锁定'; Id = 'net.controller' }
  [pscustomobject]@{ Level = 'FAIL'; Text = ("Claude 组切换后仍为 {0}:443 ({1})" -f $r4NodeDom, $r4NodeIp); Weight = 25; Group = '3. 节点锁定'; Id = 'net.node_lock' }
  [pscustomobject]@{ Level = 'WARN'; Text = ("各方看到的出口 IP 不一致，暂不记住: {0}, 198.18.0.24" -f $r4ExitIp); Weight = 10; Group = '5. 出口 IP'; Id = 'exit.three_way_ip' }
  [pscustomobject]@{ Level = 'FAIL'; Text = ("WebRTC srflx 暴露 {0}" -f $r4RtcIp); Weight = 25; Group = '8. 浏览器'; Id = 'exit.webrtc_srflx' }
  [pscustomobject]@{ Level = 'WARN'; Text = ("api.anthropic.com → {0}，不是 fake-ip，DNS 可能未被 Clash 接管" -f $r4DnsIp); Weight = 10; Group = '6. DNS'; Id = 'net.dns_fakeip' }
)
$r4Canaries = @('cslR4user', $r4Pc, $r4SubHost, $r4SubTok, $r4NodeIp, 'cslr4node', $r4Secret)
function Get-CslR4Json([switch]$HideIp) {
  $m = New-CslScoreMappedResults $r4Items -Catalog $cat -HideIp:$HideIp -UserProfile $r4Up -ComputerName $r4Pc -ExtraHosts @($r4NodeIp)
  $sc = Get-CslRulesScore -Catalog $cat -Results @($m)
  $pl = New-CslPreflightResult -ScoreResult $sc -Platform 'win' -Verdict 'blocked'
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("csl-r4-result-" + [guid]::NewGuid().ToString('n') + '.json')
  try {
    Write-CslPreflightResultJson -Result $pl -Path $tmp | Out-Null
    $raw = [IO.File]::ReadAllText($tmp, (New-Object System.Text.UTF8Encoding($false)))
  } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  $obj = $raw | ConvertFrom-Json
  return [pscustomobject]@{ Mapped = @($m); Raw = $raw; Checks = @($obj.checks); Text = ((@($obj.checks) | ForEach-Object { [string]$_.current }) -join "`n") }
}
function Get-CslR4Row($J, $Id) { return @($J.Checks | Where-Object id -eq $Id)[0] }
$r4 = Get-CslR4Json
Assert-Eq @($r4.Checks).Count 6 'R4 JSON keeps one row per item'
Assert-Eq @($r4.Checks | Where-Object id -eq 'meta.unmapped').Count 0 'R4 rows keep their real rule ids'
foreach ($c in $r4Canaries) { Assert-True (-not $r4.Raw.Contains($c)) ("R4 JSON has no canary {0}" -f $c) }
Assert-True (-not $r4.Raw.Contains('*')) 'R4 JSON has no *'
Assert-True ($r4.Text.Contains('%USERPROFILE%')) 'R4 JSON current has %USERPROFILE%'
Assert-True ($r4.Text.Contains('<PC>')) 'R4 JSON current has <PC>'
Assert-True ($r4.Text.Contains('<订阅链接>')) 'R4 JSON current has <订阅链接>'
Assert-True ($r4.Text.Contains('<节点>')) 'R4 JSON current has <节点>'
Assert-True ($r4.Raw.Contains($r4ExitIp)) 'R4 exit IP kept by default'
Assert-True ($r4.Raw.Contains($r4RtcIp)) 'R4 WebRTC IP kept by default'
Assert-True ($r4.Raw.Contains('198.18.0.24')) 'R4 fake-ip kept'
Assert-True ([bool](Get-CslR4Row $r4 'exit.three_way_ip').containsIp) 'R4 exit IP row containsIp'
Assert-True ([bool](Get-CslR4Row $r4 'exit.webrtc_srflx').containsIp) 'R4 WebRTC row containsIp'
Assert-True ([bool](Get-CslR4Row $r4 'net.dns_fakeip').containsIp) 'R4 public IP in a non-IP rule sets containsIp'
Assert-True (-not [bool](Get-CslR4Row $r4 'net.clash_running').containsIp) 'R4 row without IP keeps containsIp false'

Write-Host '== R4 JSON current with -HideIp ==' -ForegroundColor Cyan
$r4h = Get-CslR4Json -HideIp
foreach ($c in @($r4ExitIp, $r4RtcIp, $r4DnsIp)) { Assert-True (-not $r4h.Raw.Contains($c)) ("R4 -HideIp JSON has no IP {0}" -f $c) }
foreach ($c in $r4Canaries) { Assert-True (-not $r4h.Raw.Contains($c)) ("R4 -HideIp JSON has no canary {0}" -f $c) }
Assert-True ($r4h.Text.Contains('<出口IP>')) 'R4 -HideIp JSON current has <出口IP>'
Assert-True ($r4h.Raw.Contains('198.18.0.24')) 'R4 -HideIp keeps fake-ip'
Assert-True ([bool](Get-CslR4Row $r4h 'exit.three_way_ip').containsIp) 'R4 -HideIp exit IP row still containsIp'
Assert-True ([bool](Get-CslR4Row $r4h 'exit.webrtc_srflx').containsIp) 'R4 -HideIp WebRTC row still containsIp'
Assert-True ([bool](Get-CslR4Row $r4h 'net.dns_fakeip').containsIp) 'R4 -HideIp non-IP rule still containsIp'
Assert-True (-not [bool](Get-CslR4Row $r4h 'net.clash_running').containsIp) 'R4 -HideIp row without IP keeps containsIp false'
Assert-Eq ([int]$r4h.Mapped.Count) 6 'R4 -HideIp keeps one row per item'
# preflight 的评分入口把 -HideIp 一路传到 JSON current
$r4inv = Invoke-CslPreflightScoring $r4Items $cat -HideIp
$r4invText = (@($script:CslScoreMapped) | ForEach-Object { [string]$_.current }) -join "`n"
Assert-True (-not $r4invText.Contains($r4ExitIp) -and -not $r4invText.Contains($r4RtcIp)) 'R4 Invoke-CslPreflightScoring -HideIp masks IPs in current'
Assert-True ($r4invText.Contains('<出口IP>')) 'R4 Invoke-CslPreflightScoring -HideIp current has <出口IP>'
Assert-Eq ([string][Environment]::GetEnvironmentVariable($canaryName)) ([string]$prevCanary) 'canary variable cleaned up (restored to previous state)'

Write-Host '== v4 part 2: real rule ids, no item.N placeholders ==' -ForegroundColor Cyan
$catIds = @($cat.checks | ForEach-Object { [string]$_.id })
$pfSrc = [IO.File]::ReadAllText((Join-Path $root 'claude-preflight.ps1'))
Assert-True (-not ($pfSrc -match "item\.\{0\}")) 'preflight has no item.N placeholder id'
# 每个 Say-Fail / Say-Warn / Say-Note / Soft-BrowserWarn 调用点都必须带 -Id <目录里的真实 id>（仅 Soft-BrowserWarn 内部的转发调用除外；R4d 把第 2/3 节挪进了命名函数，其中的调用点仍要检查）
$sayNames = @('Say-Fail', 'Say-Warn', 'Say-Note', 'Soft-BrowserWarn')
$callAsts = @($pfAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and ($sayNames -contains $n.GetCommandName()) }, $true))
$sites = New-Object System.Collections.ArrayList
$parseSiteId = $null
$badSites = New-Object System.Collections.ArrayList
foreach ($ca in $callAsts) {
  $anc = $ca.Parent; $inFn = $false
  while ($anc) { if ($anc -is [System.Management.Automation.Language.FunctionDefinitionAst]) { if ($anc.Name -eq 'Soft-BrowserWarn') { $inFn = $true }; break }; $anc = $anc.Parent }
  if ($inFn) { continue }
  $els = @($ca.CommandElements); $idVal = $null
  for ($k = 0; $k -lt $els.Count; $k++) {
    if ($els[$k] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$k].ParameterName -eq 'Id') {
      if ($els[$k].Argument) { $idVal = $els[$k].Argument.Extent.Text.Trim("'") }
      elseif ($k + 1 -lt $els.Count) { $idVal = $els[$k + 1].Extent.Text.Trim("'") }
    }
  }
  if ($ca.Extent.Text -like '*browser-check.json 解析失败*') { $parseSiteId = $idVal }
  if ($idVal -and ($catIds -contains $idVal)) { [void]$sites.Add($idVal) } else { [void]$badSites.Add(("line {0}" -f $ca.Extent.StartLineNumber)) }
}
Assert-True ($sites.Count -ge 40) ("preflight check call sites found ($($sites.Count))")
Assert-True ($badSites.Count -eq 0) ("every check call site has -Id with a valid catalog id (bad=[$($badSites -join ', ')])")
Assert-Eq $parseSiteId 'browser.check_parse' 'browser-check.json 解析失败 warning maps to browser.check_parse (product ruling; not exit.webrtc_srflx)'
$siteGolden = 'auto.webdriver:1,browser.check_parse:1,cfg.claude_cli:1,cfg.claude_desktop:1,cfg.env_relay_machine:1,cfg.env_relay_user:3,cfg.https_proxy:1,cfg.residue_claude:1,cfg.residue_scripts:1,exit.api_anthropic:3,exit.blocked_region:1,exit.edge_trace:1,exit.ip_risk_ipapi:2,exit.ip_risk_proxycheck:3,exit.local_ip:1,exit.three_way_ip:3,exit.webrtc_ipv6:1,exit.webrtc_srflx:1,locale.browser_lang_live:1,locale.browser_lang_static:1,locale.browser_tz_live:1,locale.system_lang:1,locale.system_tz:2,locale.tz_auto:1,net.browser_webrtc_chromium:2,net.browser_webrtc_firefox:2,net.clash_running:1,net.controller:1,net.dns_fakeip:2,net.ipv6_leak:1,net.mihomo_core:1,net.node_lock:3,net.tun:1'
$siteActual = (@($sites | Group-Object | Sort-Object Name | ForEach-Object { '{0}:{1}' -f $_.Name, $_.Count }) -join ',')
Assert-Eq $siteActual $siteGolden 'call-site id set matches the reviewed golden list (id:count)'
$usedIds = @($sites | Select-Object -Unique)
$multiIds = @($cat.checks | Where-Object { $_.PSObject.Properties['multi'] -and $_.multi } | ForEach-Object { [string]$_.id } | Sort-Object)
Assert-Eq ($multiIds -join ',') 'cfg.env_relay_machine,cfg.env_relay_user,cfg.residue_claude,locale.browser_lang_static,meta.unmapped,net.browser_webrtc_chromium,net.browser_webrtc_firefox,net.node_lock' 'catalog multi ids (one row per profile/group/variable/file)'

function New-TestItem($lvl, $txt, $w, $id) { [pscustomobject]@{ Level = $lvl; Text = $txt; Weight = $w; Group = 'test'; Id = $id } }
$synth = @($usedIds | ForEach-Object { New-TestItem 'WARN' ('synthetic ' + $_) 5 $_ })
$m1 = New-CslScoreMappedResults $synth -Catalog $cat
Assert-Eq @($m1).Count $usedIds.Count 'every id used by preflight maps to one result'
Assert-Eq @($script:CslUnmappedItems).Count 0 'no unmapped items for real ids'
$m1ids = @($m1 | ForEach-Object { [string]$_.id })
Assert-True (@($m1ids | Where-Object { $catIds -notcontains $_ }).Count -eq 0) 'all emitted ids are catalog ids'
Assert-Eq (@($m1ids | Select-Object -Unique).Count) $m1ids.Count 'no id emitted twice (non-multi)'
$m2 = New-CslScoreMappedResults $synth -Catalog $cat
Assert-Eq ((@($m2 | ForEach-Object { $_.id }) -join '|')) (($m1ids) -join '|') 'mapping is deterministic'
Assert-True (@($m1ids | Where-Object { $_ -like 'item.*' }).Count -eq 0) 'no item.N ids emitted'
$sc1 = Get-CslRulesScore -Catalog $cat -Results $m1
Assert-True (@($sc1.checks | Where-Object { -not $_.category -or -not $_.title -or $_.title -eq $_.id }).Count -eq 0) 'emitted rows carry catalog category and title'
Assert-True (-not (($sc1.checks | ConvertTo-Json -Depth 6).Contains('*'))) 'rows for every id: JSON has no *'
Assert-True (@($sc1.checks | Where-Object { ([string]$_.current).Contains('=') -or ([string]$_.current).Contains('*') }).Count -eq 0) 'rows for every id: current has no = or *'

Write-Host '== v4 part 2 (R0): unmapped items are status=error under reserved id meta.unmapped ==' -ForegroundColor Cyan
$bad = @(
  (New-TestItem 'FAIL' 'no id' 25 $null),
  (New-TestItem 'WARN' 'legacy placeholder' 8 'item.1'),
  (New-TestItem 'FAIL' 'first' 25 'net.tun'),
  (New-TestItem 'FAIL' 'second (net.tun is not multi)' 25 'net.tun'),
  (New-TestItem 'WARN' 'multi a' 6 'cfg.residue_claude'),
  (New-TestItem 'WARN' 'multi b' 6 'cfg.residue_claude'),
  (New-TestItem 'NOTE' 'unknown id note' 0 'zz.not_in_catalog')
)
$mb = New-CslScoreMappedResults $bad -Catalog $cat
$mbIds = @($mb | ForEach-Object { [string]$_.id })
Assert-Eq @($mb).Count $bad.Count 'every item gets a row (none dropped)'
Assert-Eq ($mbIds -join ',') 'meta.unmapped,meta.unmapped,net.tun,meta.unmapped,cfg.residue_claude,cfg.residue_claude,meta.unmapped' 'unmapped rows use meta.unmapped; valid / multi ids kept'
Assert-Eq @($script:CslUnmappedItems).Count 4 'no id / unknown id / item.N / duplicate non-multi → recorded as unmapped'
Assert-True (@($script:CslUnmappedItems | Where-Object { [string]$_.Reason -eq '' }).Count -eq 0) 'each unmapped item has a reason'
$mbRes = Invoke-CslPreflightScoring $bad $cat
$mbRows = @($mbRes.checks)
Assert-True (@($mbRows | Where-Object { $_.id -eq 'meta.unmapped' -and $_.status -ne 'error' }).Count -eq 0) 'every meta.unmapped row has status=error'
Assert-True (@($mbRows | Where-Object { $_.id -ne 'meta.unmapped' -and $_.status -eq 'error' }).Count -eq 0) 'no other row has status=error'
Assert-True (@($mbRows | Where-Object { $_.id -eq 'meta.unmapped' -and -not ([string]$_.notes).StartsWith('未映射：') }).Count -eq 0) 'every meta.unmapped row states the reason in notes'
Assert-True (@($mbRows | Where-Object { $_.id -eq 'meta.unmapped' -and [string]$_.current -ne '' }).Count -eq 0) 'meta.unmapped rows keep current empty (no original text)'
Assert-True (@($mbRows | Where-Object { $_.id -ne 'meta.unmapped' -and $null -ne $_.PSObject.Properties['notes'] }).Count -eq 0) 'only unmapped rows carry a notes field'
Assert-True (@($mbRows | Where-Object { $_.id -eq 'meta.unmapped' -and (([string]$_.notes).Contains('item.') -or ([string]$_.notes).Contains('zz.not_in_catalog')) }).Count -eq 0) 'unmapped notes never echo the original id'
$mbPayload = New-CslPreflightResult -ScoreResult $mbRes -Platform 'win' -Verdict 'blocked'
$mbTmp = Join-Path ([IO.Path]::GetTempPath()) ("csl-unmapped-" + [guid]::NewGuid().ToString('n') + '.json')
try {
  Write-CslPreflightResultJson -Result $mbPayload -Path $mbTmp | Out-Null
  $mbRaw = [IO.File]::ReadAllText($mbTmp, (New-Object System.Text.UTF8Encoding($false)))
} finally { Remove-Item -LiteralPath $mbTmp -Force -ErrorAction SilentlyContinue }
$mbJsonIds = @(($mbRaw | ConvertFrom-Json).checks | ForEach-Object { [string]$_.id })
Assert-True (@($mbJsonIds | Where-Object { $catIds -notcontains $_ }).Count -eq 0) 'R0: every id in the JSON exists in rules/checks.json'
Assert-True (-not $mbRaw.Contains('item.')) 'R0: 0 occurrences of item. in the JSON'
Assert-True (-not $mbRaw.Contains('*')) 'R0: JSON has no *'
$mbDupNonMulti = @($mbJsonIds | Group-Object | Where-Object { $_.Count -gt 1 -and -not (Get-CslRuleById -Catalog $cat -Id $_.Name).multi })
Assert-Eq $mbDupNonMulti.Count 0 'R0: no duplicate ids in the JSON (only multi ids repeat)'
Assert-Eq $mbRes.score 5 'score = 100 - all item weights (95), unmapped weights included'
Assert-True (-not $mbRes.canLaunchSafely) 'unmapped FAIL still blocks launch'
$muRule = Get-CslRuleById -Catalog $cat -Id 'meta.unmapped'
$bcp = Get-CslRuleById -Catalog $cat -Id 'browser.check_parse'
Assert-True ($null -ne $bcp -and $bcp.category -eq 'auto' -and $bcp.severity -eq 'should_fix' -and $bcp.refDeduction -eq 3 -and $bcp.fixType -eq 'none' -and $null -eq $bcp.fixId -and -not $bcp.multi -and ($cat.scoring.staticBrowserCheckIds -notcontains 'browser.check_parse')) 'catalog: browser.check_parse (auto, should_fix, deduction 3, fixType none, not static-capped)'
Assert-True ($null -ne $muRule -and $muRule.multi -and $muRule.refDeduction -eq 0 -and $muRule.fixType -eq 'none' -and $null -eq $muRule.fixId) 'catalog reserves meta.unmapped (multi, no deduction, no fix)'

Write-Host '== v4 part 2: fixId / severity / score unchanged ==' -ForegroundColor Cyan
$fx = @(
  (New-TestItem 'FAIL' (Format-CslEnvUserItemText 'CSL_TEST_PART2' 'not-a-real-value') 25 'cfg.env_relay_user'),
  (New-TestItem 'FAIL' 'env read error text' 25 'cfg.env_relay_user'),
  (New-TestItem 'FAIL' 'clash' 25 'net.clash_running'),
  (New-TestItem 'WARN' 'tz auto' 5 'locale.tz_auto'),
  (New-TestItem 'FAIL' 'tz' 25 'locale.system_tz'),
  (New-TestItem 'NOTE' 'machine only' 0 'cfg.env_relay_machine'),
  (New-TestItem 'WARN' 'lang' 0 'locale.browser_lang_static')
)
$fxm = New-CslScoreMappedResults $fx -Catalog $cat
$fxs = Get-CslRulesScore -Catalog $cat -Results $fxm
$fxr = @($fxs.checks)
Assert-Eq $fxr[0].fixId 'envfix.user-anthropic' 'user-level env item keeps fixId envfix.user-anthropic'
Assert-Eq $fxr[0].fixType 'confirm' 'user-level env item keeps fixType confirm'
Assert-Eq $fxr[0].current '用户级 CSL_TEST_PART2：已设置' 'user-level env item current = name + status only'
Assert-True ($null -eq $fxr[1].fixId) 'env error row has no fixId'
Assert-True ($null -eq $fxr[2].fixId -and $fxr[2].fixType -eq 'none') 'net.clash_running → no fixId, fixType none (same as d025841)'
Assert-True ($null -eq $fxr[4].fixId) 'locale.system_tz (no confirm fix wired in preflight) → no fixId'
Assert-True (@($fxr | Where-Object { $_.fixId } ).Count -eq 1) 'exactly one row carries a fixId'
Assert-Eq $fxr[5].fixType 'none' 'info row has fixType none'
Assert-Eq $fxr[0].severity 'must_fix' 'FAIL keeps must_fix'
Assert-Eq $fxr[3].severity 'should_fix' 'WARN keeps should_fix'
Assert-Eq $fxr[5].severity 'info' 'NOTE keeps info'
$scItems = @((New-TestItem 'FAIL' 'a' 25 'net.tun'), (New-TestItem 'WARN' 'b' 10 'net.dns_fakeip'), (New-TestItem 'NOTE' 'c' 0 'locale.system_lang'), (New-TestItem 'WARN' 'd' 0 'locale.browser_lang_static'))
$scRes = Get-CslRulesScore -Catalog $cat -Results (New-CslScoreMappedResults $scItems -Catalog $cat)
Assert-Eq $scRes.score 65 'score = 100 - sum of item weights (25+10), unchanged by real ids'
Assert-True (-not $scRes.canLaunchSafely) 'must_fix failure still blocks launch'

Write-Host '== v4 part 2 (R0): equivalence with d025841 (score, canLaunchSafely, per-item status + fixId) ==' -ForegroundColor Cyan
# 黄金值 = 同一批合成检查结果在 d025841（item.N 版）上跑出的 score / canLaunchSafely / 每项 status / fixId。
# 每条：Level, Text, Weight, Id, 新 id, d025841 status, d025841 fixId。未映射项的 status 按 R0 改为 error（fixId 仍须与 d025841 相同）。
$r0Golden = @(
  @{ Name = 'S1-confirm-rows'; Score = 40; Can = $false; Items = @(
      @('FAIL', 'Clash Verge 未运行，也没找到安装位置', 25, 'net.clash_running', 'net.clash_running', 'failed', ''),
      @('WARN', '组切换后仍为 X', 6, 'net.node_lock', 'net.node_lock', 'failed', ''),
      @('WARN', '组切换请求失败', 6, 'net.node_lock', 'net.node_lock', 'failed', ''),
      @('WARN', '系统时区 A 与出口 B 不一致', 8, 'locale.system_tz', 'locale.system_tz', 'failed', ''),
      @('WARN', 'controller 不可用', 10, 'net.controller', 'net.controller', 'failed', ''),
      @('WARN', '本机出口 IP 查询失败', 5, 'exit.local_ip', 'exit.local_ip', 'failed', ''),
      @('NOTE', '未找到 claude CLI（仅影响命令行版）', 0, 'cfg.claude_cli', 'cfg.claude_cli', 'info', ''),
      @('NOTE', '系统语言不是中文（一般不影响）', 0, 'locale.system_lang', 'locale.system_lang', 'info', '')
    ) },
  @{ Name = 'S2-user-env'; Score = 21; Can = $false; Items = @(
      @('FAIL', '@ENV:CSL_TEST_HARNESS_A', 25, 'cfg.env_relay_user', 'cfg.env_relay_user', 'failed', 'envfix.user-anthropic'),
      @('FAIL', '@ENV:CSL_TEST_HARNESS_B', 25, 'cfg.env_relay_user', 'cfg.env_relay_user', 'failed', 'envfix.user-anthropic'),
      @('WARN', 'HTTPS_PROXY 未设置', 5, 'cfg.https_proxy', 'cfg.https_proxy', 'failed', ''),
      @('WARN', '文件 a → 命中', 6, 'cfg.residue_claude', 'cfg.residue_claude', 'failed', ''),
      @('WARN', '文件 b → 命中', 6, 'cfg.residue_claude', 'cfg.residue_claude', 'failed', ''),
      @('WARN', '机器级 CSL_TEST_HARNESS_M 已设置，需要管理员手动处理', 8, 'cfg.env_relay_machine', 'cfg.env_relay_machine', 'failed', ''),
      @('WARN', '脚本残留', 4, 'cfg.residue_scripts', 'cfg.residue_scripts', 'failed', '')
    ) },
  @{ Name = 'S3-browser-static'; Score = 72; Can = $true; Items = @(
      @('WARN', 'Chrome WebRTC 策略', 5, 'net.browser_webrtc_chromium', 'net.browser_webrtc_chromium', 'failed', ''),
      @('WARN', 'Edge WebRTC 策略', 5, 'net.browser_webrtc_chromium', 'net.browser_webrtc_chromium', 'failed', ''),
      @('WARN', 'Firefox peerconnection', 5, 'net.browser_webrtc_firefox', 'net.browser_webrtc_firefox', 'failed', ''),
      @('WARN', 'Chrome: 语言与出口地区不一致', 5, 'locale.browser_lang_static', 'locale.browser_lang_static', 'failed', ''),
      @('WARN', 'WebRTC 出口 IP 与期望不一致', 8, 'exit.webrtc_srflx', 'exit.webrtc_srflx', 'failed', ''),
      @('NOTE', '浏览器语言与出口地区不一致', 0, 'locale.browser_lang_live', 'locale.browser_lang_live', 'info', '')
    ) },
  @{ Name = 'S4-unmapped-mixed'; Score = 12; Can = $false; Items = @(
      @('WARN', '无 id 的警告', 8, $null, 'meta.unmapped', 'failed', ''),
      @('FAIL', '未知 id 的失败', 25, 'zz.not_in_catalog', 'meta.unmapped', 'failed', ''),
      @('FAIL', 'TUN 未启用', 25, 'net.tun', 'net.tun', 'failed', ''),
      @('FAIL', 'TUN 重复项（非 multi）', 25, 'net.tun', 'meta.unmapped', 'failed', ''),
      @('NOTE', '未找到 claude CLI（仅影响命令行版）', 0, 'cfg.claude_cli', 'cfg.claude_cli', 'info', ''),
      @('WARN', '本机出口 IP 查询失败', 5, 'exit.local_ip', 'exit.local_ip', 'failed', '')
    ) },
  @{ Name = 'S5-unmapped-warn-only'; Score = 92; Can = $true; Items = @(
      ,@('WARN', '无 id 的警告', 8, $null, 'meta.unmapped', 'failed', '')
    ) },
  @{ Name = 'S6-unmapped-fail-only'; Score = 75; Can = $false; Items = @(
      ,@('FAIL', '无 id 的失败', 25, $null, 'meta.unmapped', 'failed', '')
    ) },
  @{ Name = 'S7-notes-only'; Score = 100; Can = $true; Items = @(
      ,@('NOTE', '未找到 claude CLI（仅影响命令行版）', 0, 'cfg.claude_cli', 'cfg.claude_cli', 'info', '')
    ) },
  @{ Name = 'S8-heavy-clamp'; Score = 0; Can = $false; Items = @(
      @('FAIL', 'a', 25, 'net.clash_running', 'net.clash_running', 'failed', ''),
      @('FAIL', 'b', 25, 'net.mihomo_core', 'net.mihomo_core', 'failed', ''),
      @('FAIL', 'c', 25, 'net.tun', 'net.tun', 'failed', ''),
      @('FAIL', 'd', 25, 'exit.api_anthropic', 'exit.api_anthropic', 'failed', ''),
      @('FAIL', 'e', 25, $null, 'meta.unmapped', 'failed', '')
    ) },
  @{ Name = 'S9-empty'; Score = 100; Can = $true; Items = @(

    ) },
  @{ Name = 'S10-browser-check-parse'; Score = 64; Can = $false; Items = @(
      @('WARN', 'browser-check.json 解析失败', 3, 'browser.check_parse', 'browser.check_parse', 'failed', ''),
      @('WARN', 'WebRTC 出口 IP 与期望不一致', 8, 'exit.webrtc_srflx', 'exit.webrtc_srflx', 'failed', ''),
      @('NOTE', '浏览器语言与出口地区不一致', 0, 'locale.browser_lang_live', 'locale.browser_lang_live', 'info', ''),
      @('FAIL', 'TUN 未启用', 25, 'net.tun', 'net.tun', 'failed', '')
    ) }
)
foreach ($g in $r0Golden) {
  $gi = New-Object System.Collections.ArrayList
  foreach ($e in $g.Items) {
    $t = [string]$e[1]; if ($t.StartsWith('@ENV:')) { $t = Format-CslEnvUserItemText $t.Substring(5) 'not-a-real-value' }
    [void]$gi.Add((New-TestItem $e[0] $t $e[2] $e[3]))
  }
  $gr = Invoke-CslPreflightScoring @($gi) $cat
  $grRows = @($gr.checks)
  $used = @{}; $stMis = New-Object System.Collections.ArrayList; $fxMis = New-Object System.Collections.ArrayList
  foreach ($e in $g.Items) {
    $k = [int]$(if ($used.ContainsKey($e[4])) { $used[$e[4]] } else { 0 }); $used[$e[4]] = $k + 1
    $cand = @($grRows | Where-Object { $_.id -eq $e[4] })
    $row = $(if ($k -lt $cand.Count) { $cand[$k] } else { $null })
    $wantSt = $(if ($e[4] -eq 'meta.unmapped') { 'error' } else { $e[5] })
    if ($null -eq $row -or [string]$row.status -ne $wantSt) { [void]$stMis.Add([string]$e[4]) }
    if ($null -eq $row -or [string]$row.fixId -ne [string]$e[6]) { [void]$fxMis.Add([string]$e[4]) }
  }
  Assert-Eq $gr.score $g.Score ("R0 $($g.Name): score equals d025841")
  Assert-Eq ([bool]$gr.canLaunchSafely) $g.Can ("R0 $($g.Name): canLaunchSafely equals d025841")
  Assert-Eq $grRows.Count $g.Items.Count ("R0 $($g.Name): one row per item (rows equal d025841 rows)")
  Assert-True ($stMis.Count -eq 0) ("R0 $($g.Name): every item status equals d025841 (unmapped = error) (mismatch=[$($stMis -join ',')])")
  Assert-True ($fxMis.Count -eq 0) ("R0 $($g.Name): every item fixId equals d025841 (mismatch=[$($fxMis -join ',')])")
}

Write-Host '== R4a: preflight-result.json only with -Json; -JsonPath ==' -ForegroundColor Cyan
# Temp dirs only; nothing is written to the repo or script directory.
$r4aBase = Join-Path ([IO.Path]::GetTempPath()) ('csl-r4a-' + [guid]::NewGuid().ToString('n'))
$r4aRoot = Join-Path $r4aBase 'root'
$r4aOut = Join-Path $r4aBase 'out'
New-Item -ItemType Directory -Path $r4aRoot -Force | Out-Null
New-Item -ItemType Directory -Path $r4aOut -Force | Out-Null
$r4aPayload = [pscustomobject]@{ schemaVersion = 1; score = 77; checks = @() }
$r4aDefault = Join-Path $r4aRoot 'preflight-result.json'
$r4aX = Join-Path $r4aOut 'x.json'
try {
  # 1) no -Json: nothing written
  $r4aRet = Save-CslPreflightResultJson -Result $r4aPayload -Root $r4aRoot
  Assert-True ($null -eq $r4aRet) 'R4a no -Json: save returns nothing'
  Assert-True (-not (Test-Path -LiteralPath $r4aDefault)) 'R4a no -Json: no preflight-result.json in script dir'
  $r4aErr = $null
  try { Save-CslPreflightResultJson -Result $r4aPayload -JsonPath $r4aX -Root $r4aRoot | Out-Null } catch { $r4aErr = $_.Exception.Message }
  Assert-True ($null -ne $r4aErr) 'R4a -JsonPath without -Json: error'
  Assert-True ([string]$r4aErr -match '-Json') 'R4a -JsonPath without -Json: message says use with -Json'
  Assert-True (-not (Test-Path -LiteralPath $r4aX)) 'R4a -JsonPath without -Json: target file not created'
  Assert-Eq (@(Get-ChildItem -LiteralPath $r4aBase -Recurse -File).Count) 0 'R4a no -Json: no file at all in script dir or temp dir'
  Assert-True ($null -eq (Resolve-CslPreflightJsonPath -Root $r4aRoot)) 'R4a resolve without -Json gives no path'
  # 2) no -Json does not overwrite an existing file
  [IO.File]::WriteAllText($r4aDefault, 'old-r4a', (New-Object System.Text.UTF8Encoding($false)))
  Save-CslPreflightResultJson -Result $r4aPayload -Root $r4aRoot | Out-Null
  Assert-Eq ([IO.File]::ReadAllText($r4aDefault)) 'old-r4a' 'R4a no -Json: existing preflight-result.json not overwritten'
  Remove-Item -LiteralPath $r4aDefault -Force
  # 3) -Json default path = script dir
  $r4aRet = Save-CslPreflightResultJson -Result $r4aPayload -Json -Root $r4aRoot
  Assert-Eq $r4aRet $r4aDefault 'R4a -Json default path is script dir preflight-result.json'
  Assert-True (Test-Path -LiteralPath $r4aDefault) 'R4a -Json default: file written'
  $r4aJ = $null; try { $r4aJ = [IO.File]::ReadAllText($r4aDefault) | ConvertFrom-Json } catch {}
  Assert-Eq $r4aJ.score 77 'R4a -Json default: file parses with payload'
  Remove-Item -LiteralPath $r4aDefault -Force
  # 4) -Json -JsonPath: only the given file
  $r4aRet = Save-CslPreflightResultJson -Result $r4aPayload -Json -JsonPath $r4aX -Root $r4aRoot
  Assert-Eq $r4aRet ([IO.Path]::GetFullPath($r4aX)) 'R4a -JsonPath: save returns the given path'
  Assert-True (Test-Path -LiteralPath $r4aX) 'R4a -JsonPath: file written to given path'
  Assert-True (-not (Test-Path -LiteralPath $r4aDefault)) 'R4a -JsonPath: no preflight-result.json in script dir'
  $r4aBytes = [IO.File]::ReadAllBytes($r4aX)
  Assert-True (-not ($r4aBytes.Length -ge 3 -and $r4aBytes[0] -eq 0xEF -and $r4aBytes[1] -eq 0xBB -and $r4aBytes[2] -eq 0xBF)) 'R4a -JsonPath: UTF-8 without BOM'
  $r4aJ = $null; try { $r4aJ = [IO.File]::ReadAllText($r4aX) | ConvertFrom-Json } catch {}
  Assert-Eq $r4aJ.schemaVersion 1 'R4a -JsonPath: file parses with payload'
  # 5) missing directory: error, nothing created
  $r4aMissDir = Join-Path $r4aBase 'nope'
  $r4aMiss = Join-Path $r4aMissDir 'x.json'
  $r4aErr = $null
  try { Save-CslPreflightResultJson -Result $r4aPayload -Json -JsonPath $r4aMiss -Root $r4aRoot | Out-Null } catch { $r4aErr = $_.Exception.Message }
  Assert-True ($null -ne $r4aErr) 'R4a -JsonPath missing dir: error'
  Assert-True ([string]$r4aErr -match '目录不存在') 'R4a -JsonPath missing dir: message says directory missing'
  Assert-True (-not (Test-Path -LiteralPath $r4aMissDir)) 'R4a -JsonPath missing dir: directory not created'
  Assert-True (-not (Test-Path -LiteralPath $r4aDefault)) 'R4a -JsonPath missing dir: no fallback file in script dir'
  $r4aErr = $null
  try { Resolve-CslPreflightJsonPath -Json -JsonPath $r4aOut -Root $r4aRoot | Out-Null } catch { $r4aErr = $_.Exception.Message }
  Assert-True ($null -ne $r4aErr) 'R4a -JsonPath pointing to a directory: error'
  # 6) real CLI: missing -JsonPath dir exits before any check, writes nothing
  $r4aCli = Join-Path $r4aBase 'cli'
  New-Item -ItemType Directory -Path $r4aCli -Force | Out-Null
  Get-ChildItem -LiteralPath $root -Filter 'claude-*.ps1' -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $r4aCli }
  Copy-Item -LiteralPath (Join-Path $root 'rules') -Destination $r4aCli -Recurse
  $r4aCliMiss = Join-Path (Join-Path $r4aBase 'cli-nope') 'x.json'
  $r4aExe = (Get-Process -Id $PID).Path
  $r4aPrevEnc = $null
  try { $r4aPrevEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
  try {
    $r4aOutLines = @(& $r4aExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $r4aCli 'claude-preflight.ps1') -NoLaunch -NoPause -Json -JsonPath $r4aCliMiss 2>&1 | ForEach-Object { [string]$_ })
    $r4aExit = $LASTEXITCODE
  } finally {
    if ($null -ne $r4aPrevEnc) { try { [Console]::OutputEncoding = $r4aPrevEnc } catch {} }
  }
  Assert-Eq $r4aExit 2 'R4a CLI -JsonPath missing dir: exit 2'
  Assert-True ((($r4aOutLines -join "`n") -match 'CSL_JSON_ERROR=')) 'R4a CLI -JsonPath missing dir: prints CSL_JSON_ERROR='
  Assert-True (-not (Test-Path -LiteralPath (Split-Path -Parent $r4aCliMiss))) 'R4a CLI -JsonPath missing dir: directory not created'
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $r4aCli 'preflight-result.json'))) 'R4a CLI -JsonPath missing dir: no preflight-result.json in script dir'
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $r4aCli 'preflight.json'))) 'R4a CLI -JsonPath missing dir: exits before config is written'
  # real CLI: -JsonPath without -Json exits 2 before any check, writes nothing
  $r4aCliX = Join-Path $r4aOut 'cli-x.json'
  $r4aPrevEnc = $null
  try { $r4aPrevEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
  try {
    $r4aOutLines2 = @(& $r4aExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $r4aCli 'claude-preflight.ps1') -NoLaunch -NoPause -JsonPath $r4aCliX 2>&1 | ForEach-Object { [string]$_ })
    $r4aExit2 = $LASTEXITCODE
  } finally {
    if ($null -ne $r4aPrevEnc) { try { [Console]::OutputEncoding = $r4aPrevEnc } catch {} }
  }
  Assert-Eq $r4aExit2 2 'R4a CLI -JsonPath without -Json: exit 2'
  Assert-True ((($r4aOutLines2 -join "`n") -match 'CSL_JSON_ERROR=.*-Json')) 'R4a CLI -JsonPath without -Json: says use with -Json'
  Assert-True (-not (Test-Path -LiteralPath $r4aCliX)) 'R4a CLI -JsonPath without -Json: target file not created'
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $r4aCli 'preflight-result.json'))) 'R4a CLI -JsonPath without -Json: no preflight-result.json in script dir'
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $r4aCli 'preflight.json'))) 'R4a CLI -JsonPath without -Json: exits before config is written'
} finally {
  try { Remove-Item -LiteralPath $r4aBase -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
# 7) preflight wiring (static): the only write goes through the -Json gate
$r4aPf = Get-Content (Join-Path $root 'claude-preflight.ps1') -Raw -Encoding UTF8
Assert-Eq ([regex]::Matches($r4aPf, 'Save-CslPreflightResultJson\s+-Result\s+\$payload\s+-Json:\$Json\s+-JsonPath\s+\$JsonPath').Count) 1 'R4a preflight saves JSON only via Save-CslPreflightResultJson -Json:$Json -JsonPath $JsonPath'
Assert-Eq ([regex]::Matches($r4aPf, 'Write-CslPreflightResultJson').Count) 0 'R4a preflight has no direct Write-CslPreflightResultJson call'
Assert-True ($r4aPf -match '\[string\]\$JsonPath') 'R4a preflight has -JsonPath parameter'
Assert-True ($r4aPf -match '-JsonPath <') 'R4a -? help documents -JsonPath'
$r4aHelp = @($r4aPf -split "`r?`n" | Where-Object { $_ -match '^\s*-JsonPath <' })
Assert-True ($r4aHelp.Count -eq 1 -and $r4aHelp[0] -match '不给 -Json 也报错退出' -and $r4aHelp[0] -notmatch '忽略') 'R4a -? help says -JsonPath must be used with -Json (error, not ignored)'

# 不用 Get-FileHash（部分 Windows PowerShell 5.1 子进程里不可用），改用 .NET SHA256
function Get-CslR4bSha256([string]$Path) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path)))) } finally { $sha.Dispose() }
}
Write-Host '== R4b-1 node server addresses from the Clash runtime config (fake config, temp dir only) ==' -ForegroundColor Cyan
$r4bBase = Join-Path ([IO.Path]::GetTempPath()) ("csl-r4b-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $r4bBase -Force | Out-Null
try {
  $r4bNodeIp = '203.0.113.91'
  $r4bNodeIp2 = '198.51.100.67'
  # .jp 不在 R4 裸域名规则（com/net/org/io/cc/me/xyz/top/dev）里，只有 R4b-1 的 -ExtraHosts 能遮住
  $r4bNodeDom = 'r4bcanary-node.example-csl.jp'
  $r4bSecret = 'r4bSecretZq8'
  $r4bExitIp = '192.0.2.150'
  $r4bYaml = Join-Path $r4bBase 'clash-verge.yaml'
  $r4bYamlText = @(
    'mixed-port: 7897',
    ('secret: ' + $r4bSecret),
    'external-controller: 127.0.0.1:9097',
    'proxies:',
    '  - name: r4b-n1',
    '    type: ss',
    ('    server: ' + $r4bNodeIp),
    '    port: 443',
    ('  - { name: r4b-n2, type: trojan, server: ' + $r4bNodeDom + ', port: 443, sni: r4b-sni.example }'),
    '  - name: r4b-n3',
    ('    server: "' + $r4bNodeIp2 + '"'),
    'proxy-groups:',
    '  - name: Claude',
    '    proxies: [r4b-n1, r4b-n2]',
    'rules:',
    '  - MATCH,Claude'
  ) -join "`r`n"
  [IO.File]::WriteAllText($r4bYaml, $r4bYamlText, (New-Object System.Text.UTF8Encoding($false)))
  $r4bHashBefore = Get-CslR4bSha256 $r4bYaml
  $r4bNodes = Get-CslClashNodeHosts -Path $r4bYaml
  Assert-True ([bool]$r4bNodes.ok) 'R4b-1 fake config: ok'
  Assert-Eq @($r4bNodes.hosts).Count 3 'R4b-1 fake config: 3 node servers'
  Assert-True ((@($r4bNodes.hosts) -contains $r4bNodeIp) -and (@($r4bNodes.hosts) -contains $r4bNodeIp2) -and (@($r4bNodes.hosts) -contains $r4bNodeDom)) 'R4b-1 fake config: node IPs and domain read'
  Assert-True (-not ((@($r4bNodes.hosts) -join ' ') -match [regex]::Escape($r4bSecret)) -and -not ((@($r4bNodes.hosts) -join ' ') -match 'r4b-sni|9097')) 'R4b-1 reads only server, not secret / sni / controller'
  Assert-Eq ((Get-CslR4bSha256 $r4bYaml)) $r4bHashBefore 'R4b-1 Clash config unchanged after read'
  $r4bMiss = Get-CslClashNodeHosts -Path (Join-Path $r4bBase 'nope.yaml')
  Assert-True ((-not $r4bMiss.ok) -and @($r4bMiss.hosts).Count -eq 0 -and ([string]$r4bMiss.info -match '未找到') -and ([string]$r4bMiss.info -match '不扣分')) 'R4b-1 missing config: falls back with one info'
  $r4bBad = Join-Path $r4bBase 'bad.yaml'
  [IO.File]::WriteAllText($r4bBad, "mixed-port: 7897`r`nproxies: [[[`r`n  garbage {{{`r`n", (New-Object System.Text.UTF8Encoding($false)))
  $r4bBadR = Get-CslClashNodeHosts -Path $r4bBad
  Assert-True ((-not $r4bBadR.ok) -and @($r4bBadR.hosts).Count -eq 0 -and ([string]$r4bBadR.info -match '解析失败') -and ([string]$r4bBadR.info -match '不扣分')) 'R4b-1 unparsable config: falls back with one info'
  # static: reader has no secret / network / write
  $r4bFn = $null
  $r4bRulesAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'claude-rules.ps1'), [ref]$null, [ref]$null)
  $r4bFn = $r4bRulesAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-CslClashNodeHosts' }, $true) | Select-Object -First 1
  Assert-True (($null -ne $r4bFn) -and -not ($r4bFn.Body.Extent.Text -match '(?i)secret\s*[:=]|controller|Invoke-(Curl|WebRequest|RestMethod)|curl|WriteAll|Set-Content|Out-File|Add-Content|Remove-Item|Move-Item')) 'R4b-1 reader: no secret / network / file write'

  # issue export + JSON with the node list (another fake exit IP still follows R4)
  $r4bItems = @(
    [pscustomobject]@{ Level = 'FAIL'; Text = ("Claude 组切换后仍为 {0}:443 ({1})，备用 {2}" -f $r4bNodeDom, $r4bNodeIp, $r4bNodeIp2); Weight = 25; Group = '3. 节点锁定'; Id = 'net.node_lock' }
    [pscustomobject]@{ Level = 'WARN'; Text = ("各方看到的出口 IP 不一致，暂不记住: {0}, 198.18.0.24" -f $r4bExitIp); Weight = 10; Group = '5. 出口 IP'; Id = 'exit.three_way_ip' }
    [pscustomobject]@{ Level = 'FAIL'; Text = ("WebRTC srflx 暴露 {0}" -f $r4bNodeIp); Weight = 25; Group = '8. 浏览器'; Id = 'exit.webrtc_srflx' }
  )
  $r4bNodeCanaries = @($r4bNodeIp, $r4bNodeIp2, $r4bNodeDom, 'r4bcanary')
  $r4bPack = Format-CslIssuePack -Items $r4bItems -ExtraHosts $r4bNodes.hosts
  foreach ($c in $r4bNodeCanaries) { Assert-True (-not $r4bPack.Contains($c)) ("R4b-1 issue export has no node {0}" -f $c) }
  Assert-True ($r4bPack.Contains('<节点>')) 'R4b-1 issue export has <节点>'
  Assert-True ($r4bPack.Contains($r4bExitIp)) 'R4b-1 issue export keeps the other exit IP by default'
  $r4bPackH = Format-CslIssuePack -Items $r4bItems -ExtraHosts $r4bNodes.hosts -HideIp
  Assert-True (-not $r4bPackH.Contains($r4bExitIp) -and $r4bPackH.Contains('<出口IP>')) 'R4b-1 issue export -HideIp masks the other exit IP'
  foreach ($c in $r4bNodeCanaries) { Assert-True (-not $r4bPackH.Contains($c)) ("R4b-1 issue export -HideIp has no node {0}" -f $c) }

  $r4bInv = Invoke-CslPreflightScoring $r4bItems $cat -ExtraHosts $r4bNodes.hosts
  $r4bMap = @($script:CslScoreMapped)
  $r4bCur = ($r4bMap | ForEach-Object { [string]$_.current }) -join "`n"
  foreach ($c in $r4bNodeCanaries) { Assert-True (-not $r4bCur.Contains($c)) ("R4b-1 JSON current has no node {0}" -f $c) }
  Assert-True ($r4bCur.Contains('<节点>')) 'R4b-1 JSON current has <节点>'
  $r4bExitRow = @($r4bMap | Where-Object id -eq 'exit.three_way_ip')[0]
  Assert-True (([string]$r4bExitRow.current).Contains($r4bExitIp) -and ($r4bExitRow.containsIpOverride -eq $true)) 'R4b-1 JSON other exit IP kept by default, containsIp=true'
  $r4bInvH = Invoke-CslPreflightScoring $r4bItems $cat -HideIp -ExtraHosts $r4bNodes.hosts
  $r4bCurH = (@($script:CslScoreMapped) | ForEach-Object { [string]$_.current }) -join "`n"
  Assert-True (-not $r4bCurH.Contains($r4bExitIp) -and $r4bCurH.Contains('<出口IP>')) 'R4b-1 JSON -HideIp masks the other exit IP'
  # node IP == exit IP: masked as node
  $r4bRtcRow = @($r4bMap | Where-Object id -eq 'exit.webrtc_srflx')[0]
  Assert-True ((([string]$r4bRtcRow.current).Contains('<节点>')) -and -not (([string]$r4bRtcRow.current).Contains('<出口IP>')) -and -not (([string]$r4bRtcRow.current).Contains($r4bNodeIp))) 'R4b-1 node IP equal to exit IP is masked as <节点>'
  $r4bRtcH = @(@($script:CslScoreMapped) | Where-Object id -eq 'exit.webrtc_srflx')[0]
  Assert-True ((([string]$r4bRtcH.current).Contains('<节点>')) -and -not (([string]$r4bRtcH.current).Contains('<出口IP>'))) 'R4b-1 node IP equal to exit IP stays <节点> under -HideIp'
  # fallback: no config → R4 behavior (node IP treated as exit IP, kept by default)
  $r4bInvF = Invoke-CslPreflightScoring $r4bItems $cat -ExtraHosts @($r4bMiss.hosts)
  $r4bCurF = (@($script:CslScoreMapped) | ForEach-Object { [string]$_.current }) -join "`n"
  Assert-True ($r4bCurF.Contains($r4bNodeIp)) 'R4b-1 fallback keeps R4 behavior (node IP kept without config)'

  Write-Host '== R4b-2 -HideIp masks screen output and preflight.log ==' -ForegroundColor Cyan
  $r4bV6 = '2001:db8:85a3::8a2e:370:7334'
  $r4bLine = ("出口 {0} WebRTC {1} fake-ip 198.18.0.9 198.19.3.4 内网 192.168.1.20 10.1.2.3 时间 23:15:20 链路本地 fe80::1" -f $r4bExitIp, $r4bV6)
  $r4bMasked = Protect-CslExitIpText $r4bLine
  Assert-True (-not $r4bMasked.Contains($r4bExitIp) -and -not $r4bMasked.Contains($r4bV6) -and $r4bMasked.Contains('<出口IP>')) 'R4b-2 mask: public IPv4 / IPv6 to <出口IP>'
  Assert-True ($r4bMasked.Contains('198.18.0.9') -and $r4bMasked.Contains('198.19.3.4') -and $r4bMasked.Contains('192.168.1.20') -and $r4bMasked.Contains('10.1.2.3') -and $r4bMasked.Contains('23:15:20') -and $r4bMasked.Contains('fe80::1')) 'R4b-2 mask: fake-ip / LAN / time / link-local kept'
  # screen: real Write-Host in a child process, output captured
  $r4bScr = Join-Path $r4bBase 'screen.ps1'
  $r4bScrText = @(
    'param([switch]$HideIp)',
    ('$r = ''' + $root.Replace("'", "''") + ''''),
    '. (Join-Path $r ''claude-common.ps1'')',
    '. (Join-Path $r ''claude-issueexport.ps1'')',
    '. (Join-Path $r ''claude-rules.ps1'')',
    'if ($HideIp) { Enable-CslHideIpHost }',
    'function Say-Pass($t) { Write-Host "  [通过] $($t)" -ForegroundColor Green }',
    ('Say-Pass ''' + $r4bLine + ''''),
    ('Write-Host ''WebRTC 公网 IP:'' ''' + $r4bExitIp + ''' -NoNewline; Write-Host ''''')
  ) -join "`r`n"
  [IO.File]::WriteAllText($r4bScr, $r4bScrText, (New-Object System.Text.UTF8Encoding($true)))
  $r4bExe = (Get-Process -Id $PID).Path
  $r4bPrevEnc = $null
  try { $r4bPrevEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
  try {
    $r4bOutH = (@(& $r4bExe -NoProfile -ExecutionPolicy Bypass -File $r4bScr -HideIp 2>&1 | ForEach-Object { [string]$_ })) -join "`n"
    $r4bOutN = (@(& $r4bExe -NoProfile -ExecutionPolicy Bypass -File $r4bScr 2>&1 | ForEach-Object { [string]$_ })) -join "`n"
  } finally {
    if ($null -ne $r4bPrevEnc) { try { [Console]::OutputEncoding = $r4bPrevEnc } catch {} }
  }
  Assert-Eq ([regex]::Matches($r4bOutH, [regex]::Escape($r4bExitIp)).Count + [regex]::Matches($r4bOutH, [regex]::Escape($r4bV6)).Count) 0 'R4b-2 -HideIp screen: fake public IPs appear 0 times'
  Assert-True ($r4bOutH.Contains('<出口IP>') -and $r4bOutH.Contains('[通过]') -and $r4bOutH.Contains('198.18.0.9') -and $r4bOutH.Contains('192.168.1.20')) 'R4b-2 -HideIp screen: <出口IP> shown, fake-ip / LAN kept'
  Assert-True ($r4bOutN.Contains($r4bExitIp) -and $r4bOutN.Contains($r4bV6) -and -not $r4bOutN.Contains('<出口IP>')) 'R4b-2 without -HideIp screen unchanged'
  # log: real Write-Log into a temp preflight.log
  $r4bPrevLog = $script:LogPath
  $script:LogPath = Join-Path $r4bBase 'preflight.log'
  try {
    $r4bLogLine = ('FAIL | score=60 | ip={0} | tz=Asia/Tokyo | fail=1 | warn=0 | launch=nolaunch | WebRTC 公网 IP 与出口不一致: WebRTC={1} 期望=198.18.0.5' -f $r4bExitIp, $r4bV6)
    Write-Log (Format-CslPreflightLogLine $r4bLogLine -HideIp)
    $r4bLogH = [IO.File]::ReadAllText($script:LogPath)
    Remove-Item -LiteralPath $script:LogPath -Force
    Write-Log (Format-CslPreflightLogLine $r4bLogLine)
    $r4bLogN = [IO.File]::ReadAllText($script:LogPath)
  } finally { $script:LogPath = $r4bPrevLog }
  Assert-True (-not $r4bLogH.Contains($r4bExitIp) -and -not $r4bLogH.Contains($r4bV6) -and $r4bLogH.Contains('ip=<出口IP>') -and $r4bLogH.Contains('198.18.0.5')) 'R4b-2 -HideIp preflight.log: fake public IPs 0 times, <出口IP>, fake-ip kept'
  Assert-True ($r4bLogN.Contains($r4bExitIp) -and $r4bLogN.Contains($r4bV6)) 'R4b-2 without -HideIp preflight.log unchanged'
} finally {
  try { Remove-Item -LiteralPath $r4bBase -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
# preflight wiring (static)
$r4bPf = Get-Content (Join-Path $root 'claude-preflight.ps1') -Raw -Encoding UTF8
Assert-Eq ([regex]::Matches($r4bPf, 'Get-CslClashNodeHosts\s+-Path').Count) 1 'R4b-1 preflight reads node servers once'
Assert-True ($r4bPf -match "Join-Path \`$script:VergeDir 'clash-verge\.yaml'") 'R4b-1 preflight reads the runtime config the launcher already uses'
Assert-Eq ([regex]::Matches($r4bPf, 'Invoke-CslPreflightScoring @\(\$script:Items\) \$script:CslRulesCatalog -HideIp:\$HideIp -ExtraHosts \$script:CslNodeHosts').Count) 1 'R4b-1 JSON scoring gets -ExtraHosts node list'
Assert-Eq ([regex]::Matches($r4bPf, 'Format-CslIssuePack -Items @\(\$script:Items\.ToArray\(\)\) -HideIp:\$HideIp -ExtraHosts \$script:CslNodeHosts').Count) 1 'R4b-1 issue export gets -ExtraHosts node list'
Assert-True ($r4bPf -match 'New-CslScoreMappedResults @\(\$Items\) -Catalog \$Catalog -HideIp:\$HideIp -ExtraHosts \$ExtraHosts') 'R4b-1 scoring entry forwards -ExtraHosts'
$r4bEn = $r4bPf.IndexOf('if ($HideIp) { Enable-CslHideIpHost }')
$r4bFirstHost = $r4bPf.IndexOf("Write-Host '=====")
Assert-True ($r4bEn -gt 0 -and $r4bFirstHost -gt $r4bEn -and [regex]::Matches($r4bPf, 'Enable-CslHideIpHost').Count -eq 1) 'R4b-2 preflight wraps screen output before the first line'
Assert-Eq ([regex]::Matches($r4bPf, 'Write-Log \(Format-CslPreflightLogLine \$logLine -HideIp:\$HideIp\)').Count) 1 'R4b-2 preflight.log line goes through the -HideIp mask'
$r4bHelp = @($r4bPf -split "`r?`n" | Where-Object { $_ -match '^\s*-HideIp :' })
Assert-True ($r4bHelp.Count -eq 1 -and $r4bHelp[0] -match '屏幕输出' -and $r4bHelp[0] -match 'preflight\.log' -and $r4bHelp[0] -match '<节点>') 'R4b -? help states -HideIp covers screen and preflight.log, nodes as <节点>'

Write-Host '== R4b-2 background monitor lines in preflight.log follow -HideIp ==' -ForegroundColor Cyan
$r4bMonPath = Join-Path $root 'claude-monitor.ps1'
$r4bMonSrc = Get-Content $r4bMonPath -Raw -Encoding UTF8
$r4bMonAst = [System.Management.Automation.Language.Parser]::ParseFile($r4bMonPath, [ref]$null, [ref]$null)
$r4bMonParams = @($r4bMonAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
Assert-True ($r4bMonParams -contains 'HideIp') 'R4b-2 monitor has -HideIp parameter'
Assert-Eq ([regex]::Matches($r4bMonSrc, '(?<![\w-])Write-Log\b').Count) 1 'R4b-2 monitor writes preflight.log only via Write-CslMonLog'
$r4bAlert = $r4bMonAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Show-Alert' }, $true) | Select-Object -First 1
Assert-True (($null -ne $r4bAlert) -and ($r4bAlert.Body.Extent.Text -match '\$text = Format-CslPreflightLogLine \$text -HideIp:\$script:MonHideIp')) 'R4b-2 monitor alert text goes through the -HideIp mask'
Assert-True ($pfSrc -match "if \(\`$HideIp\) \{ \`$monArgs \+= '-HideIp' \}" -and $pfSrc -match '-ArgumentList \$monArgs') 'R4b-2 preflight passes -HideIp to the background monitor'
$r4bMonBase = Join-Path ([IO.Path]::GetTempPath()) ("csl-r4bmon-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $r4bMonBase -Force | Out-Null
$r4bPrevLog2 = $script:LogPath
$r4bHadOnce = Test-Path variable:Once
try {
  foreach ($fnName in @('Write-CslMonLog', 'Out-Mon')) {
    $fnAst = $r4bMonAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }, $true) | Select-Object -First 1
    Assert-True ($null -ne $fnAst) "R4b-2 monitor defines $fnName"
    if ($fnAst) { . ([scriptblock]::Create($fnAst.Extent.Text)) }
  }
  $r4bMonIp = '192.0.2.188'
  $r4bMonLine = ('[monitor] FIXED | 已切回 r4b-n1 ip={0} | fake 198.18.0.7' -f $r4bMonIp)
  $script:LogPath = Join-Path $r4bMonBase 'preflight.log'
  $script:MonHideIp = $true
  Write-CslMonLog $r4bMonLine
  $r4bMonLogH = [IO.File]::ReadAllText($script:LogPath)
  Remove-Item -LiteralPath $script:LogPath -Force
  $script:MonHideIp = $false
  Write-CslMonLog $r4bMonLine
  $r4bMonLogN = [IO.File]::ReadAllText($script:LogPath)
  Assert-True (-not $r4bMonLogH.Contains($r4bMonIp) -and $r4bMonLogH.Contains('ip=<出口IP>') -and $r4bMonLogH.Contains('198.18.0.7')) 'R4b-2 monitor -HideIp preflight.log: fake public IP 0 times, fake-ip kept'
  Assert-True ($r4bMonLogN.Contains($r4bMonIp)) 'R4b-2 monitor without -HideIp preflight.log unchanged'
  $Once = $true
  $script:MonHideIp = $true
  $r4bMonOut = (@(Out-Mon ('正常: ip={0} loc=JP' -f $r4bMonIp) 'Green' 6>&1 | ForEach-Object { [string]$_ })) -join "`n"
  Assert-True (-not $r4bMonOut.Contains($r4bMonIp) -and $r4bMonOut.Contains('<出口IP>')) 'R4b-2 monitor -Once -HideIp screen: fake public IP 0 times'
} finally {
  $script:LogPath = $r4bPrevLog2
  $script:MonHideIp = $false
  if (-not $r4bHadOnce) { Remove-Variable -Name Once -ErrorAction SilentlyContinue }
  try { Remove-Item -LiteralPath $r4bMonBase -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

# ============================================================================
# R4c: -? / -Help 只打印帮助，不跑预检（所有入口脚本都有注释式帮助）
# ============================================================================
Write-Host '== R4c-1 every entry script: comment-based help before param(), -Help exits first (static) ==' -ForegroundColor Cyan
$r4cEntryNames = @('claude-monitor.ps1', 'claude-panel.ps1', 'claude-preflight.ps1', 'install.ps1')
$r4cAll = @(Get-ChildItem -LiteralPath $root -File | Where-Object { $_.Name -like 'claude-*.ps1' -or $_.Name -eq 'install.ps1' } | Sort-Object Name)
$r4cWithParam = @()
foreach ($r4cF in $r4cAll) {
  $r4cP = [System.Management.Automation.Language.Parser]::ParseFile($r4cF.FullName, [ref]$null, [ref]$null)
  if ($null -ne $r4cP.ParamBlock) { $r4cWithParam += $r4cF.Name }
}
Assert-Eq ($r4cWithParam -join ',') ($r4cEntryNames -join ',') 'R4c entry scripts (those with a top-level param()) are exactly monitor, panel, preflight, install (new entry => add help + -Help + tests)'
foreach ($r4cName in $r4cEntryNames) {
  $r4cPath = Join-Path $root $r4cName
  $r4cTok = $null; $r4cErr = $null
  $r4cAst = [System.Management.Automation.Language.Parser]::ParseFile($r4cPath, [ref]$r4cTok, [ref]$r4cErr)
  $r4cParamStart = $r4cAst.ParamBlock.Extent.StartOffset
  $r4cHelpTok = @($r4cTok | Where-Object { $_.Kind -eq 'Comment' -and $_.Text.StartsWith('<#') -and $_.Text -match '(?m)^\s*\.SYNOPSIS' } | Select-Object -First 1)
  $r4cFirstCode = @($r4cTok | Where-Object { $_.Kind -ne 'Comment' -and $_.Kind -ne 'NewLine' } | Select-Object -First 1)
  $r4cHelpText = ''
  $r4cHelpOk = ($r4cHelpTok.Count -eq 1 -and $r4cFirstCode.Count -eq 1 -and $r4cFirstCode[0].Extent.StartOffset -eq $r4cParamStart -and $r4cHelpTok[0].Extent.EndOffset -le $r4cParamStart)
  if ($r4cHelpTok.Count -eq 1) { $r4cHelpText = $r4cHelpTok[0].Text }
  $r4cHelpOk = $r4cHelpOk -and ($r4cHelpText -match '(?m)^\s*\.DESCRIPTION') -and ($r4cHelpText -match '(?m)^\s*\.EXAMPLE')
  Assert-True $r4cHelpOk "R4c $r4cName has a comment-help block (.SYNOPSIS/.DESCRIPTION/.EXAMPLE) before param()"
  $r4cParamNames = @($r4cAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
  $r4cDocumented = @([regex]::Matches($r4cHelpText, '(?m)^\s*\.PARAMETER\s+(\w+)') | ForEach-Object { $_.Groups[1].Value })
  $r4cMissing = @($r4cParamNames | Where-Object { $r4cDocumented -notcontains $_ })
  Assert-True ($r4cParamNames -contains 'Help' -and $r4cMissing.Count -eq 0) "R4c $r4cName has -Help and documents every parameter with .PARAMETER (undocumented: $($r4cMissing -join ','))"
  # -Help branch = first statement after param(); its body only prints help and exits 0
  $r4cFirst = $null
  if ($r4cAst.EndBlock -and $r4cAst.EndBlock.Statements.Count -gt 0) { $r4cFirst = $r4cAst.EndBlock.Statements[0] }
  $r4cFirstOk = $false
  if ($r4cFirst -is [System.Management.Automation.Language.IfStatementAst] -and $r4cFirst.Clauses.Count -eq 1 -and $r4cFirst.Clauses[0].Item1.Extent.Text -eq '$Help') {
    $r4cBody = $r4cFirst.Clauses[0].Item2
    $r4cExits = @($r4cBody.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true))
    $r4cCmds = @($r4cBody.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
    $r4cBad = @($r4cCmds | Where-Object { @('Get-Help', 'Out-String', 'Write-Host') -notcontains $_ })
    $r4cFirstOk = ($r4cExits.Count -eq 1 -and $r4cExits[0].Pipeline.Extent.Text -eq '0' -and $r4cBad.Count -eq 0)
  }
  Assert-True $r4cFirstOk "R4c $r4cName -Help branch is the first statement after param(), only prints help and exit 0 (before any check, config, file, network, monitor)"
  $r4cH = $null
  try { $r4cH = Get-Help -Name $r4cPath -Full -ErrorAction Stop } catch {}
  Assert-True ($null -ne $r4cH -and -not [string]::IsNullOrWhiteSpace([string]$r4cH.Synopsis) -and @($r4cH.parameters.parameter).Count -ge 1) "R4c $r4cName Get-Help -Full reads the help statically (synopsis + parameters)"
  if ($r4cName -eq 'claude-preflight.ps1' -or $r4cName -eq 'claude-monitor.ps1') {
    $r4cCfgCalls = @($r4cAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Load-Config' }, $true) | Sort-Object { $_.Extent.StartOffset })
    $r4cHelpIfs = @($r4cAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$Help' }, $true) | Sort-Object { $_.Extent.StartOffset })
    Assert-True ($r4cHelpIfs.Count -ge 1 -and $r4cCfgCalls.Count -ge 1 -and $r4cHelpIfs[0].Extent.EndOffset -lt $r4cCfgCalls[0].Extent.StartOffset) "R4c $r4cName -Help exit comes before the first Load-Config"
  }
}
$r4cPfHelp = [IO.File]::ReadAllText((Join-Path $root 'claude-preflight.ps1'))
$r4cMonHelp = [IO.File]::ReadAllText((Join-Path $root 'claude-monitor.ps1'))
$r4cHideRe = '(?s)\.PARAMETER HideIp\r?\n(.*?)(?=\r?\n\.[A-Z]|\r?\n#>)'
$r4cPfHide = [regex]::Match($r4cPfHelp, $r4cHideRe).Groups[1].Value
$r4cMonHide = [regex]::Match($r4cMonHelp, $r4cHideRe).Groups[1].Value
Assert-True ($r4cPfHide.Contains('<出口IP>') -and $r4cPfHide.Contains('<节点>') -and $r4cPfHide.Contains('preflight.log') -and $r4cPfHide.Contains('监控')) 'R4c preflight -HideIp help states R4b semantics (screen + preflight.log + monitor lines masked as <出口IP>, node servers <节点>)'
Assert-True ($r4cMonHide.Contains('<出口IP>') -and $r4cMonHide.Contains('preflight.log')) 'R4c monitor -HideIp help states the preflight.log / screen masking'

Write-Host '== R4c-2 -Help in a temp copy: exit 0, prints help, writes nothing (child process, temp dir only) ==' -ForegroundColor Cyan
# 守卫约束：实跑只在临时副本里用 -Help（预检另带 -NoLaunch -NoPause，监控另带 -Once -DryRun，面板不开浏览器）。
function Get-CslDirSnapshot([string]$Dir) {
  @(Get-ChildItem -LiteralPath $Dir -Recurse -Force -File | Sort-Object FullName | ForEach-Object { '{0}|{1}|{2}' -f $_.FullName.Substring($Dir.Length), $_.Length, $_.LastWriteTimeUtc.Ticks }) -join "`n"
}
function Invoke-CslHelpProbe([string]$ScriptPath, [string]$ExtraArgs) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = (Get-Process -Id $PID).Path
  $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '" ' + $ExtraArgs
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
  $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
  $psi.EnvironmentVariables['CSL_PANEL_NO_OPEN'] = '1'
  $p = [System.Diagnostics.Process]::Start($psi)
  $so = $p.StandardOutput.ReadToEndAsync()
  $se = $p.StandardError.ReadToEndAsync()
  $timedOut = $false
  if (-not $p.WaitForExit(90000)) { $timedOut = $true; try { $p.Kill() } catch {}; try { [void]$p.WaitForExit(5000) } catch {} }
  $code = if ($timedOut) { -1 } else { $p.ExitCode }
  $out = ''
  try { $out = $so.Result + $se.Result } catch {}
  return @{ Exit = $code; Out = $out; TimedOut = $timedOut }
}
$r4cProbes = @(
  @{ Name = 'claude-preflight.ps1'; Args = '-Help -NoLaunch -NoPause' },
  @{ Name = 'claude-monitor.ps1'; Args = '-Help -Once -DryRun' },
  @{ Name = 'claude-panel.ps1'; Args = '-Help' }
)
$r4cDynNames = @()
foreach ($r4cPr in $r4cProbes) {
  $r4cN = $r4cPr.Name
  $r4cDynNames += @(
    "R4c -Help $($r4cN): exit 0",
    "R4c -Help $($r4cN): prints the help text",
    "R4c -Help $($r4cN): seed preflight.json not modified",
    "R4c -Help $($r4cN): no preflight.log created",
    "R4c -Help $($r4cN): no preflight-result.json created",
    "R4c -Help $($r4cN): temp copy unchanged (no file added or changed; no monitor / panel started)"
  )
}
$r4cBase = Join-Path ([IO.Path]::GetTempPath()) ('csl-r4chelp-' + [guid]::NewGuid().ToString('n'))
$r4cSetupOk = $false
$r4cSetupErr = ''
try {
  try {
    if ($env:CSL_TEST_FORCE_SETUP_FAIL -eq 'r4c-help') { throw 'forced setup failure (CSL_TEST_FORCE_SETUP_FAIL=r4c-help)' }
    New-Item -ItemType Directory -Path $r4cBase -Force | Out-Null
    foreach ($r4cPr in $r4cProbes) {
      $r4cD = Join-Path $r4cBase ([IO.Path]::GetFileNameWithoutExtension($r4cPr.Name))
      New-Item -ItemType Directory -Path $r4cD -Force | Out-Null
      Get-ChildItem -LiteralPath $root -Filter 'claude-*.ps1' -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $r4cD }
      Copy-Item -LiteralPath (Join-Path $root 'rules') -Destination $r4cD -Recurse
      Copy-Item -LiteralPath (Join-Path $root 'claude-panel.html') -Destination $r4cD
      # Safety seed: if -Help ever regresses, a real preflight in this copy must not learn/switch nodes or run tzutil.
      # timezone = the current Windows zone (no change), claudeGroup '' (no node learning / PUT), no main group pin.
      $r4cSeed = [ordered]@{ timezone = [TimeZoneInfo]::Local.Id; claudeGroup = ''; pinMainGroup = $false; mainGroup = '' }
      [IO.File]::WriteAllText((Join-Path $r4cD 'preflight.json'), ($r4cSeed | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    }
    $r4cSetupOk = $true
  } catch { $r4cSetupErr = $_.Exception.Message }
  if (-not $r4cSetupOk) {
    Assert-True $false "R4c setup: temp copies of the entry scripts for -Help probes ($r4cSetupErr)"
    Skip-CslDependents 'R4c temp copies' $r4cDynNames
  } else {
    Assert-True $true 'R4c setup: temp copies of the entry scripts for -Help probes'
    foreach ($r4cPr in $r4cProbes) {
      $r4cN = $r4cPr.Name
      $r4cD = Join-Path $r4cBase ([IO.Path]::GetFileNameWithoutExtension($r4cN))
      $r4cSyn = ([regex]::Match([IO.File]::ReadAllText((Join-Path $root $r4cN)), '(?m)^\.SYNOPSIS\r?\n(.+?)\r?$').Groups[1].Value).Trim()
      $r4cSeedText = [IO.File]::ReadAllText((Join-Path $r4cD 'preflight.json'))
      $r4cSnapBefore = Get-CslDirSnapshot $r4cD
      $r4cRes = Invoke-CslHelpProbe (Join-Path $r4cD $r4cN) $r4cPr.Args
      $r4cSnapAfter = Get-CslDirSnapshot $r4cD
      Assert-True ((-not $r4cRes.TimedOut) -and $r4cRes.Exit -eq 0) "R4c -Help $($r4cN): exit 0"
      Assert-True ($r4cSyn.Length -gt 0 -and $r4cRes.Out.Contains($r4cSyn)) "R4c -Help $($r4cN): prints the help text"
      $r4cSeedAfter = ''
      try { $r4cSeedAfter = [IO.File]::ReadAllText((Join-Path $r4cD 'preflight.json')) } catch {}
      Assert-True ($r4cSeedAfter -ceq $r4cSeedText) "R4c -Help $($r4cN): seed preflight.json not modified"
      Assert-True (-not (Test-Path -LiteralPath (Join-Path $r4cD 'preflight.log'))) "R4c -Help $($r4cN): no preflight.log created"
      Assert-True (-not (Test-Path -LiteralPath (Join-Path $r4cD 'preflight-result.json'))) "R4c -Help $($r4cN): no preflight-result.json created"
      Assert-True ($r4cSnapBefore -ceq $r4cSnapAfter) "R4c -Help $($r4cN): temp copy unchanged (no file added or changed; no monitor / panel started)"
    }
  }
} finally {
  try { Remove-Item -LiteralPath $r4cBase -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

# ============================================================================
# R4d: -NoLaunch 从不改时区、节点和 Clash（写入口守卫 + 进程内桩函数验证）
# 守卫约束：本节不连任何真实 Clash 控制器、不改真实时区、不碰真实 ANTHROPIC_* 变量、不联网；
# 控制器读写（Invoke-Ctl）、tzutil、Save-Learned、Get-Trace / Invoke-Curl 全是桩，Load-Config 只写临时目录。
# ============================================================================
Write-Host '== R4d-1 every write entry point has a -NoLaunch guard before it (static, by entry point) ==' -ForegroundColor Cyan
$r4dPfPath = Join-Path $root 'claude-preflight.ps1'
$r4dAst = [System.Management.Automation.Language.Parser]::ParseFile($r4dPfPath, [ref]$null, [ref]$null)
function Get-R4dFn($Ast, [string]$Name) {
  return ($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) | Select-Object -First 1)
}
function Get-R4dCmds($Ast, [string[]]$Names) {
  return @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and ($Names -contains $n.GetCommandName()) }, $true) | Sort-Object { $_.Extent.StartOffset })
}
function Get-R4dContainer($Node) {
  $p = $Node.Parent
  while ($p) { if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $p.Name }; $p = $p.Parent }
  return '(script body)'
}
# 守卫 = 包装函数的第一条语句：if (-not (Test-CslNoLaunchWriteAllowed -NoLaunch:$NoLaunch)) { ...; return ... }，且所有原始写调用都在它之后
function Test-R4dGuardFirst($Ast, [string]$FnName, [string[]]$RawNames, [string]$GuardCall = 'Test-CslNoLaunchWriteAllowed -NoLaunch:$NoLaunch') {
  $fn = Get-R4dFn $Ast $FnName
  if (-not $fn) { return $false }
  $stmts = @($fn.Body.EndBlock.Statements)
  if ($stmts.Count -eq 0) { return $false }
  $first = $stmts[0]
  if (-not ($first -is [System.Management.Automation.Language.IfStatementAst]) -or $first.Clauses.Count -ne 1) { return $false }
  if (($first.Clauses[0].Item1.Extent.Text -replace '\s+', ' ') -cne ('-not (' + $GuardCall + ')')) { return $false }
  if (@($first.Clauses[0].Item2.FindAll({ param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst] }, $true)).Count -lt 1) { return $false }
  $raw = @(Get-R4dCmds $fn $RawNames)
  if ($raw.Count -lt 1) { return $false }
  foreach ($c in $raw) { if ($c.Extent.StartOffset -lt $first.Extent.EndOffset) { return $false } }
  return $true
}
$r4dTzRaw = @(Get-R4dCmds $r4dAst @('tzutil.exe'))
$r4dTzBad = @($r4dTzRaw | Where-Object { (Get-R4dContainer $_) -ne 'Invoke-CslTzutilSet' })
$r4dSetTz = @()
foreach ($r4dScr in @(Get-ChildItem -LiteralPath $root -File | Where-Object { $_.Name -like 'claude-*.ps1' -or $_.Name -eq 'install.ps1' })) {
  $r4dSa = [System.Management.Automation.Language.Parser]::ParseFile($r4dScr.FullName, [ref]$null, [ref]$null)
  $r4dSetTz += @(Get-R4dCmds $r4dSa @('Set-TimeZone', 'tzutil', 'tzutil.exe') | Where-Object { $r4dScr.Name -ne 'claude-preflight.ps1' -or (Get-R4dContainer $_) -ne 'Invoke-CslTzutilSet' } | ForEach-Object { $r4dScr.Name })
}
Assert-True ($r4dTzRaw.Count -ge 1 -and $r4dTzBad.Count -eq 0 -and $r4dSetTz.Count -eq 0) "R4d [tzutil] tzutil.exe appears only inside Invoke-CslTzutilSet; no Set-TimeZone / other tzutil call in any entry script (outside=$($r4dTzBad.Count), other=$($r4dSetTz.Count))"
Assert-True (Test-R4dGuardFirst $r4dAst 'Set-CslSystemTimeZone' @('Invoke-CslTzutilSet')) 'R4d [tzutil] Set-CslSystemTimeZone: first statement is the -NoLaunch guard (returns), before the Invoke-CslTzutilSet call'
$r4dTzCalls = @(Get-R4dCmds $r4dAst @('Invoke-CslTzutilSet'))
Assert-True ($r4dTzCalls.Count -eq 1 -and (Get-R4dContainer $r4dTzCalls[0]) -eq 'Set-CslSystemTimeZone') 'R4d [tzutil] Invoke-CslTzutilSet is called only from Set-CslSystemTimeZone'
$r4dSelAll = @(Get-R4dCmds $r4dAst @('Ctl-SelectNode', 'Invoke-Ctl', 'Invoke-RestMethod', 'Invoke-WebRequest'))
$r4dSelBad = @($r4dSelAll | Where-Object { (Get-R4dContainer $_) -ne 'Switch-CslClashNode' })
Assert-True ($r4dSelAll.Count -eq 1 -and $r4dSelBad.Count -eq 0) "R4d [Ctl-SelectNode] the only Clash controller write call in claude-preflight.ps1 is Ctl-SelectNode inside Switch-CslClashNode (calls=$($r4dSelAll.Count), outside=$($r4dSelBad.Count))"
Assert-True (Test-R4dGuardFirst $r4dAst 'Switch-CslClashNode' @('Ctl-SelectNode')) 'R4d [Ctl-SelectNode] Switch-CslClashNode: first statement is the -NoLaunch guard (returns), before the Ctl-SelectNode call'
$r4dSaveAll = @(Get-R4dCmds $r4dAst @('Save-Learned'))
$r4dSaveBad = @($r4dSaveAll | Where-Object { (Get-R4dContainer $_) -ne 'Save-CslLearnedGuarded' })
Assert-True ($r4dSaveAll.Count -eq 1 -and $r4dSaveBad.Count -eq 0) "R4d [Save-Learned] the only Save-Learned call in claude-preflight.ps1 is inside Save-CslLearnedGuarded (calls=$($r4dSaveAll.Count), outside=$($r4dSaveBad.Count))"
Assert-True (Test-R4dGuardFirst $r4dAst 'Save-CslLearnedGuarded' @('Save-Learned') 'Test-CslLearnWriteAllowed -NoLaunch:$NoLaunch -Relearn:$Relearn') 'R4d [Save-Learned] Save-CslLearnedGuarded: first statement is the -NoLaunch guard (returns; since the 15:25 revision the guard is Test-CslLearnWriteAllowed: -NoLaunch blocks unless -Relearn), before the Save-Learned call'
$r4dGuardFn = Get-R4dFn $r4dAst 'Test-CslNoLaunchWriteAllowed'
$r4dGuardBody = ''; if ($r4dGuardFn) { $r4dGuardBody = ($r4dGuardFn.Body.EndBlock.Statements | ForEach-Object { $_.Extent.Text }) -join ';' }
Assert-True ($null -ne $r4dGuardFn -and $r4dGuardBody -eq 'return (-not $NoLaunch)') 'R4d [guard] Test-CslNoLaunchWriteAllowed is exactly: return (-not $NoLaunch)'
# 每个调用点都必须带 -NoLaunch:$NoLaunch（缺了它，开关默认 $false = 允许写）
$r4dSiteSpec = @(
  @{ Callee = 'Save-CslLearnedGuarded'; Container = '(script body)'; Ord = 1; Label = 'Relearn'; Entry = 'Save-Learned' },
  @{ Callee = 'Save-CslLearnedGuarded'; Container = '(script body)'; Ord = 2; Label = 'exit-IP learning'; Entry = 'Save-Learned' },
  @{ Callee = 'Save-CslLearnedGuarded'; Container = 'Invoke-CslTimezoneStep'; Ord = 1; Label = 'timezone learning'; Entry = 'Save-Learned' },
  @{ Callee = 'Save-CslLearnedGuarded'; Container = 'Invoke-CslNodeLock'; Ord = 1; Label = 'expectedNode learning'; Entry = 'Save-Learned' },
  @{ Callee = 'Set-CslSystemTimeZone'; Container = 'Invoke-CslTimezoneStep'; Ord = 1; Label = 'timezone change'; Entry = 'tzutil' },
  @{ Callee = 'Switch-CslClashNode'; Container = 'Invoke-CslNodeLock'; Ord = 1; Label = 'node switch'; Entry = 'Ctl-SelectNode' },
  @{ Callee = 'Invoke-CslTimezoneStep'; Container = '(script body)'; Ord = 1; Label = 'section 2 (timezone step)'; Entry = 'tzutil' },
  @{ Callee = 'Invoke-CslNodeLock'; Container = '(script body)'; Ord = 1; Label = 'section 3 (node lock step)'; Entry = 'Ctl-SelectNode' },
  @{ Callee = 'Start-CslClashProcess'; Container = 'Invoke-CslClashStartStep'; Ord = 1; Label = 'Clash start'; Entry = 'Clash start' },
  @{ Callee = 'Invoke-CslClashStartStep'; Container = '(script body)'; Ord = 1; Label = 'section 1 (Clash not running)'; Entry = 'Clash start' },
  @{ Callee = 'Invoke-CslTunWaitStep'; Container = '(script body)'; Ord = 1; Label = 'section 1 (TUN wait)'; Entry = 'TUN wait' }
)
$r4dSiteExpect = @{ 'Save-CslLearnedGuarded' = 4; 'Set-CslSystemTimeZone' = 1; 'Switch-CslClashNode' = 1; 'Invoke-CslTimezoneStep' = 1; 'Invoke-CslNodeLock' = 1; 'Start-CslClashProcess' = 1; 'Invoke-CslClashStartStep' = 1; 'Invoke-CslTunWaitStep' = 1 }
$r4dRelearnPass = @('Save-CslLearnedGuarded', 'Invoke-CslTimezoneStep', 'Invoke-CslNodeLock')
foreach ($r4dSp in $r4dSiteSpec) {
  $r4dAll = @(Get-R4dCmds $r4dAst @($r4dSp.Callee))
  $r4dMine = @($r4dAll | Where-Object { (Get-R4dContainer $_) -eq $r4dSp.Container })
  $r4dOk = $false
  if ($r4dAll.Count -eq $r4dSiteExpect[$r4dSp.Callee] -and $r4dMine.Count -ge $r4dSp.Ord) {
    $r4dEls = @($r4dMine[$r4dSp.Ord - 1].CommandElements)
    foreach ($r4dEl in $r4dEls) {
      if ($r4dEl -is [System.Management.Automation.Language.CommandParameterAst] -and $r4dEl.ParameterName -eq 'NoLaunch' -and $r4dEl.Argument -and $r4dEl.Argument.Extent.Text -eq '$NoLaunch') { $r4dOk = $true }
    }
  }
  Assert-True $r4dOk ('R4d [{0}] call site {1} ({2}) of {3} passes -NoLaunch:$NoLaunch (calls found: {4}, expected: {5})' -f $r4dSp.Entry, $r4dSp.Label, $r4dSp.Container, $r4dSp.Callee, $r4dAll.Count, $r4dSiteExpect[$r4dSp.Callee])
  if ($r4dRelearnPass -contains $r4dSp.Callee) {
    $r4dOk2 = $false
    if ($r4dAll.Count -eq $r4dSiteExpect[$r4dSp.Callee] -and $r4dMine.Count -ge $r4dSp.Ord) {
      foreach ($r4dEl in @($r4dMine[$r4dSp.Ord - 1].CommandElements)) {
        if ($r4dEl -is [System.Management.Automation.Language.CommandParameterAst] -and $r4dEl.ParameterName -eq 'Relearn' -and $r4dEl.Argument -and $r4dEl.Argument.Extent.Text -eq '$Relearn') { $r4dOk2 = $true }
      }
    }
    Assert-True $r4dOk2 ('R4d [Relearn] call site {0} ({1}) of {2} passes -Relearn:$Relearn' -f $r4dSp.Label, $r4dSp.Container, $r4dSp.Callee)
  }
}
# 启动分支：带 -NoLaunch 的分支是 if 链的第一个分支；启动 Claude / 拉起后台监控（监控会 PUT 切节点）只在后面的分支
$r4dStartApp = @(Get-R4dCmds $r4dAst @('Start-ClaudeApp'))
$r4dMonStart = @(Get-R4dCmds $r4dAst @('Start-Process') | Where-Object { $_.Extent.Text -match '\$monArgs' })
$r4dLaunchOk = $false
if ($r4dStartApp.Count -eq 1 -and $r4dMonStart.Count -eq 1) {
  $r4dStartOff = $r4dStartApp[0].Extent.StartOffset
  $r4dLaunchIf = @($r4dAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$NoLaunch' -and $n.Extent.StartOffset -lt $r4dStartOff -and $n.Extent.EndOffset -gt $r4dStartOff }, $true))
  if ($r4dLaunchIf.Count -eq 1) {
    $r4dLi = $r4dLaunchIf[0]
    $r4dNlEnd = $r4dLi.Clauses[0].Item2.Extent.EndOffset
    $r4dBoth = @(@($r4dStartApp) + @($r4dMonStart))
    $r4dLaunchOk = (@($r4dBoth | Where-Object { $_.Extent.StartOffset -ge $r4dNlEnd -and $_.Extent.EndOffset -le $r4dLi.Extent.EndOffset }).Count -eq 2)
  }
}
Assert-True $r4dLaunchOk 'R4d [monitor launch] the if ($NoLaunch) branch comes first; Start-ClaudeApp and the background-monitor Start-Process (monitor can PUT a node switch) only exist in the later branches'

# ---- 15:25 修订：-Relearn 例外 / Load-Config -NoWrite / 不启动 Clash（静态）
$r4dLg = Get-R4dFn $r4dAst 'Test-CslLearnWriteAllowed'
$r4dLgBody = ''; if ($r4dLg) { $r4dLgBody = ($r4dLg.Body.EndBlock.Statements | ForEach-Object { $_.Extent.Text }) -join ';' }
Assert-True ($null -ne $r4dLg -and $r4dLgBody -eq 'return ((-not $NoLaunch) -or $Relearn)') 'R4d [Relearn] Test-CslLearnWriteAllowed is exactly: return ((-not $NoLaunch) -or $Relearn)'
$r4dNoRl = @()
foreach ($r4dFnX in @('Set-CslSystemTimeZone', 'Invoke-CslTzutilSet', 'Switch-CslClashNode', 'Start-CslClashProcess', 'Invoke-CslClashStartStep', 'Test-CslNoLaunchWriteAllowed')) {
  $r4dFx = Get-R4dFn $r4dAst $r4dFnX
  if (-not $r4dFx) { $r4dNoRl += ($r4dFnX + '(missing)'); continue }
  if (@($r4dFx.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) -contains 'Relearn') { $r4dNoRl += $r4dFnX }
}
Assert-True ($r4dNoRl.Count -eq 0) ("R4d [Relearn] -Relearn can never unlock tzutil / Ctl-SelectNode / Clash start: those wrappers and the plain -NoLaunch guard have no -Relearn parameter (offenders=[$($r4dNoRl -join ',')])")
$r4dSpAll = @(Get-R4dCmds $r4dAst @('Start-Process'))
$r4dSpClash = @($r4dSpAll | Where-Object { (Get-R4dContainer $_) -eq 'Start-CslClashProcess' })
$r4dSpOther = @($r4dSpAll | Where-Object { (Get-R4dContainer $_) -ne 'Start-CslClashProcess' -and $_.Extent.Text -notmatch '\$monArgs' })
Assert-True ($r4dSpClash.Count -eq 1 -and $r4dSpOther.Count -eq 0 -and $r4dSpAll.Count -eq 2) "R4d [Clash start] Start-Process appears only inside Start-CslClashProcess (and the monitor launch in the non-NoLaunch branch) (clash=$($r4dSpClash.Count), other=$($r4dSpOther.Count), total=$($r4dSpAll.Count))"
Assert-True (Test-R4dGuardFirst $r4dAst 'Start-CslClashProcess' @('Start-Process')) 'R4d [Clash start] Start-CslClashProcess: first statement is the -NoLaunch guard (returns), before the Start-Process call'
$r4dLcCalls = @(Get-R4dCmds $r4dAst @('Load-Config'))
$r4dLcArgText = ''
if ($r4dLcCalls.Count -eq 1) { foreach ($r4dEl in @($r4dLcCalls[0].CommandElements)) { if ($r4dEl -is [System.Management.Automation.Language.CommandParameterAst] -and $r4dEl.ParameterName -eq 'NoWrite' -and $r4dEl.Argument) { $r4dLcArgText = ($r4dEl.Argument.Extent.Text -replace '\s+', ' ') } } }
Assert-True ($r4dLcCalls.Count -eq 1 -and $r4dLcArgText -ceq '($NoLaunch -and -not $Relearn)') ('R4d [Load-Config] preflight calls Load-Config -NoWrite:($NoLaunch -and -not $Relearn) (calls=' + $r4dLcCalls.Count + ', arg=[' + $r4dLcArgText + '])')
$r4dCmAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'claude-common.ps1'), [ref]$null, [ref]$null)
$r4dLcFn = Get-R4dFn $r4dCmAst 'Load-Config'
$r4dLcParams = @(); if ($r4dLcFn) { $r4dLcParams = @($r4dLcFn.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) }
$r4dLcWrite = @(); if ($r4dLcFn) { $r4dLcWrite = @($r4dLcFn.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text -like '*WriteAllText*' }, $true)) }
$r4dLcWriteOk = $false
if ($r4dLcWrite.Count -eq 1) {
  $r4dP = $r4dLcWrite[0].Parent
  while ($r4dP -and -not ($r4dP -is [System.Management.Automation.Language.IfStatementAst])) { $r4dP = $r4dP.Parent }
  if ($r4dP -and (($r4dP.Clauses[0].Item1.Extent.Text -replace '\s+', ' ') -ceq '$changed -and -not $NoWrite')) { $r4dLcWriteOk = $true }
}
Assert-True (($r4dLcParams -contains 'NoWrite') -and $r4dLcWriteOk) 'R4d [Load-Config] claude-common.ps1 Load-Config has a -NoWrite switch and its only WriteAllText sits under if ($changed -and -not $NoWrite)'
$r4dLcOthers = @()
foreach ($r4dOn in @('claude-monitor.ps1', 'claude-panel.ps1')) {
  $r4dOa = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $r4dOn), [ref]$null, [ref]$null)
  foreach ($r4dOc in @(Get-R4dCmds $r4dOa @('Load-Config'))) { $r4dLcOthers += ('{0}:{1}' -f $r4dOn, @($r4dOc.CommandElements).Count) }
}
Assert-True ($r4dLcOthers.Count -ge 2 -and @($r4dLcOthers | Where-Object { $_ -notmatch ':1$' }).Count -eq 0) ("R4d [Load-Config] other callers (monitor, panel) call Load-Config with no arguments, so their behavior is unchanged (callers=[$($r4dLcOthers -join ',')])")

# ---- 15:49 修订：-NoLaunch 且 Clash 未运行时不等 TUN（静态）
$r4dTw = Get-R4dFn $r4dAst 'Invoke-CslTunWaitStep'
$r4dTwOk = $false
if ($r4dTw) {
  $r4dTwSt = @($r4dTw.Body.EndBlock.Statements)
  $r4dTwFirst = $null; if ($r4dTwSt.Count -gt 0) { $r4dTwFirst = $r4dTwSt[0] }
  $r4dTwSleep = @(Get-R4dCmds $r4dTw @('Start-Sleep'))
  if ($r4dTwFirst -is [System.Management.Automation.Language.IfStatementAst] -and $r4dTwFirst.Clauses.Count -eq 1 -and (($r4dTwFirst.Clauses[0].Item1.Extent.Text -replace '\s+', ' ') -ceq '$NoLaunch -and -not $VergeRunning') -and @($r4dTwFirst.Clauses[0].Item2.FindAll({ param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst] }, $true)).Count -ge 1 -and $r4dTwSleep.Count -eq 1 -and $r4dTwSleep[0].Extent.StartOffset -ge $r4dTwFirst.Extent.EndOffset) { $r4dTwOk = $true }
}
Assert-True $r4dTwOk 'R4d [TUN wait] Invoke-CslTunWaitStep: first statement is if ($NoLaunch -and -not $VergeRunning) { ...; return }, before its only Start-Sleep'
$r4dBodyLoops = @($r4dAst.FindAll({ param($n) ($n -is [System.Management.Automation.Language.WhileStatementAst] -or $n -is [System.Management.Automation.Language.DoWhileStatementAst] -or $n -is [System.Management.Automation.Language.ForStatementAst]) -and (Get-R4dContainer $n) -eq '(script body)' -and @(Get-R4dCmds $n @('Start-Sleep', 'Get-ProxyCore', 'Get-TunAdapter')).Count -gt 0 }, $true))
Assert-True ($r4dBodyLoops.Count -eq 0) "R4d [TUN wait] no TUN wait loop is left in the script body (loops with Start-Sleep / Get-ProxyCore / Get-TunAdapter outside functions: $($r4dBodyLoops.Count))"
$r4dTwCalls = @(Get-R4dCmds $r4dAst @('Invoke-CslTunWaitStep'))
$r4dTwArg1 = ''; if ($r4dTwCalls.Count -eq 1 -and @($r4dTwCalls[0].CommandElements).Count -ge 2) { $r4dTwArg1 = ($r4dTwCalls[0].CommandElements[1].Extent.Text -replace '\s+', ' ') }
Assert-True ($r4dTwCalls.Count -eq 1 -and $r4dTwArg1 -ceq '([bool]$verge)') ("R4d [TUN wait] the script body calls Invoke-CslTunWaitStep once and passes ([bool]`$verge) as the Clash-running state (calls=$($r4dTwCalls.Count), arg1=[$r4dTwArg1])")
$r4dPreText = [IO.File]::ReadAllText((Join-Path $root 'claude-preflight.ps1'))
Assert-True ($r4dPreText.Contains('[重新学习] 将按当前环境重新记住出口 IP / 节点 / 时区') -and -not $r4dPreText.Contains('只报告，不写 preflight.json') -and $r4dPreText.Contains('-NoLaunch：只重新记住并写 preflight.json，不改时区、不切节点、不启动 Clash')) 'R4d [text] the -Relearn banner no longer claims -NoLaunch does not write preflight.json, and says it only re-learns (no tz change / node switch / Clash start)'
$r4dPanel = [IO.File]::ReadAllText((Join-Path $root 'claude-panel.html'))
Assert-True ($r4dPanel.Contains('以后正常启动时如有变化，会提醒并自动切回；本次只记录，不改时区、不切节点。')) 'R4d [text] panel relearn confirm: auto switch-back only on normal launch; this run only records, no timezone change, no node switch'
Assert-True (-not $r4dPanel.Contains('以后发生变化会提醒并自动切回。')) 'R4d [text] panel relearn confirm: old wording implying this run switches back is gone'
$r4dReadme = [IO.File]::ReadAllText((Join-Path $root 'README.md'))
Assert-True ($r4dReadme.Contains('「记住当前环境」（面板以 `-NoLaunch -Relearn` 运行：只重新记住并写入 `preflight.json`，不改系统时区、不切节点、不启动 Clash）')) 'R4d [text] README: the panel "记住当前环境" button only re-learns and writes preflight.json (no timezone change, no node switch, no Clash start)'

Write-Host '== R4d-2 in-process, stubs only: -NoLaunch never changes timezone / node / Clash / preflight.json ==' -ForegroundColor Cyan
$r4dN = [ordered]@{
  Setup = 'R4d setup: guarded write wrappers, step functions and Say-* extracted from claude-preflight.ps1; stubs installed'
  A1 = 'R4d [Ctl-SelectNode] -NoLaunch, node-lock path (claudeGroup set, expectedNode differs from current): Ctl-SelectNode called 0 times'
  A2 = 'R4d [Ctl-SelectNode] -NoLaunch, node-lock path: 0 non-GET controller requests (PUT/PATCH/POST), read-only GETs still happen'
  A3 = 'R4d [Save-Learned] -NoLaunch, node-lock path: Save-Learned called 0 times'
  A4 = 'R4d [Ctl-SelectNode] -NoLaunch, node-lock path: group stays on its node, skip is reported, mismatch still reported as net.node_lock FAIL, not switched'
  A5 = 'R4d [Ctl-SelectNode] control without -NoLaunch (same scenario): Ctl-SelectNode called once, one PUT, group switched to expectedNode (stubs are wired)'
  B1 = 'R4d [Ctl-SelectNode] -NoLaunch with pinMainGroup + mainGroup: 0 Ctl-SelectNode calls, 0 non-GET requests, groups unchanged'
  B2 = 'R4d [Ctl-SelectNode] control without -NoLaunch with pinMainGroup + mainGroup: 2 Ctl-SelectNode calls, 2 PUTs'
  C1 = 'R4d [Save-Learned] -NoLaunch, claudeGroup set and expectedNode empty: expectedNode not learned (0 Save-Learned, cfg.expectedNode stays empty), 0 selects'
  C2 = 'R4d [Save-Learned] control without -NoLaunch: expectedNode learned (1 Save-Learned with key expectedNode = current node)'
  D1 = 'R4d [tzutil] -NoLaunch, configured timezone differs from current: tzutil called 0 times, timezone unchanged, skip reported, mismatch reported as locale.system_tz FAIL'
  D2 = 'R4d [tzutil] control without -NoLaunch: tzutil called once and the timezone is changed'
  E0 = 'R4d [Save-Learned] true no-config path: Load-Config defaults (claudeGroup Claude, timezone and expectedNode empty) and preflight.json created by Load-Config only'
  E1 = 'R4d [Save-Learned] true no-config path, -NoLaunch (timezone step + node-lock step): Save-Learned called 0 times (timezone and expectedNode not learned)'
  E2 = 'R4d [tzutil] true no-config path, -NoLaunch: tzutil called 0 times'
  E3 = 'R4d [Ctl-SelectNode] true no-config path, -NoLaunch: 0 Ctl-SelectNode calls, 0 non-GET controller requests'
  E4 = 'R4d [Save-Learned] true no-config path, -NoLaunch: preflight.json bytes unchanged (.NET SHA256)'
  E5 = 'R4d [Save-Learned] control, true no-config path without -NoLaunch: timezone and expectedNode are learned (2 Save-Learned calls) and preflight.json changes'
  E6 = 'R4d [tzutil] control, true no-config path without -NoLaunch: learned timezone differs from current, tzutil called once'
  G1 = 'R4d [guard] Test-CslNoLaunchWriteAllowed: allowed without -NoLaunch, denied with -NoLaunch'
  G2 = 'R4d [Relearn] Test-CslLearnWriteAllowed truth table: allowed unless -NoLaunch; with -NoLaunch allowed only with -Relearn'
  RL1 = 'R4d [Relearn] -NoLaunch -Relearn (panel Relearn button): Relearn clear + timezone + expectedNode learning writes happen (3 Save-Learned, preflight.json holds the learned values)'
  RL2 = 'R4d [Relearn] -NoLaunch -Relearn: tzutil 0, Ctl-SelectNode 0, non-GET requests 0, tz change reported as skipped (Relearn never unlocks tz / node)'
  RN1 = 'R4d [Relearn] -NoLaunch without -Relearn on an existing preflight.json: Relearn clear, timezone and expectedNode learning blocked (0 Save-Learned, bytes unchanged, expectedNode kept)'
  RN2 = 'R4d [Relearn] -NoLaunch without -Relearn: tzutil 0, Ctl-SelectNode 0, non-GET requests 0, skips reported'
  RC1 = 'R4d [Relearn] control without -NoLaunch: the same Relearn clear writes and learning still happen (behavior unchanged)'
  LC1 = 'R4d [Load-Config] -NoWrite on a true no-config temp dir: preflight.json NOT created, defaults returned in memory'
  LC2 = 'R4d [Load-Config] without -NoWrite on a true no-config temp dir: preflight.json created with the defaults (wiring proof, default behavior unchanged)'
  LC3 = 'R4d [Load-Config] -NoWrite on a partial preflight.json: bytes unchanged, missing defaults filled in memory; without -NoWrite the file is rewritten'
  LC4 = 'R4d [Load-Config] preflight -NoWrite expression: true only for -NoLaunch without -Relearn; -NoLaunch -Relearn on a no-config dir creates the file (writing allowed)'
  CS1 = 'R4d [Clash start] -NoLaunch, Clash not running, clashExe exists: Start-Process called 0 times, skip reported, "Clash Verge 未运行" reported as net.clash_running FAIL'
  CS2 = 'R4d [Clash start] control without -NoLaunch: Start-Process stub called once with clashExe, no FAIL (stub is wired)'
  CS3 = 'R4d [Clash start] no clashExe found: 0 Start-Process calls and the "也没找到安装位置" FAIL, with and without -NoLaunch (behavior unchanged)'
  TW1 = 'R4d [TUN wait] -NoLaunch, Clash not running: no TUN wait (0 Start-Sleep, 0 probes, inputs returned unchanged, Waited=false) and net.clash_running is reported as FAIL'
  TW2 = 'R4d [TUN wait] control without -NoLaunch, Clash not running: the wait path is entered (15 stubbed Start-Sleep calls, Waited=true, TUN never up)'
  TW3 = 'R4d [TUN wait] without -NoLaunch, TUN comes up on the first probe: the wait stops after 1 sleep and returns the adapter'
  TW4 = 'R4d [TUN wait] -NoLaunch but Clash already running (TUN not ready): the read-only wait still happens (15 sleeps)'
  CS4 = 'R4d [Clash start] Clash already running (TUN not ready): 0 Start-Process calls and no FAIL, with and without -NoLaunch'
}
$r4dFnNames = @('Invoke-CslTunWaitStep', 'Test-CslNoLaunchWriteAllowed', 'Test-CslLearnWriteAllowed', 'Start-CslClashProcess', 'Invoke-CslClashStartStep', 'Set-CslSystemTimeZone', 'Switch-CslClashNode', 'Save-CslLearnedGuarded', 'Invoke-CslTimezoneStep', 'Invoke-CslNodeLock', 'Add-Item', 'Say-Head', 'Say-Pass', 'Say-Info', 'Say-Fix', 'Say-Note', 'Say-Warn', 'Say-Fail')
$r4dStubNames = @('Get-ProxyCore', 'Get-TunAdapter', 'Save-Learned', 'Ctl-SelectNode', 'Invoke-Ctl', 'Get-Trace', 'Invoke-Curl', 'Find-ClaudeApp', 'Find-ClashExe', 'Find-NpmGlobalDir')
$r4dSaved = @{}
foreach ($r4dFnN in $r4dStubNames) { $r4dSaved[$r4dFnN] = (Get-Item "function:$r4dFnN" -ErrorAction SilentlyContinue).ScriptBlock }
$r4dRealSave = $r4dSaved['Save-Learned']
$r4dSavedCfgPath = $script:CfgPath; $r4dSavedVergeDir = $script:VergeDir
$r4dSavedItems = $script:Items; $r4dSavedHead = $script:CurrentHead
$r4dTmp = Join-Path ([IO.Path]::GetTempPath()) ('csl-r4d-' + [guid]::NewGuid().ToString('N'))
$r4dReady = $false; $r4dSetupErr = ''
try {
  try {
    $r4dMissing = @()
    foreach ($r4dFnN in $r4dFnNames) {
      $r4dFa = Get-R4dFn $r4dAst $r4dFnN
      if ($null -eq $r4dFa) { $r4dMissing += $r4dFnN } else { . ([scriptblock]::Create($r4dFa.Extent.Text)) }
    }
    if ($r4dMissing.Count -gt 0) { throw ('missing functions: ' + ($r4dMissing -join ',')) }
    New-Item -ItemType Directory -Path $r4dTmp -Force | Out-Null
    $script:R4dS = @{}
    function Reset-R4dState([hashtable]$Now) {
      $script:R4dS = @{ Sleep = 0; Probe = 0; Mihomo = $null; Tun = $null; ClashStart = 0; ClashStartPath = ''; Select = 0; CtlWrite = 0; CtlGet = 0; Save = 0; Tzutil = 0; SaveKeys = @(); SaveVals = @{}; Now = $Now; Passthrough = $false }
      $script:Items = New-Object System.Collections.ArrayList
    }
    # 桩：控制器（假数据，不联网）、写操作计数器
    function Invoke-Ctl($cfg, [string]$method, [string]$path, [string]$body = $null) {
      if ($method -ne 'GET') {
        $script:R4dS.CtlWrite++
        $gw = [uri]::UnescapeDataString(($path -replace '^/proxies/', ''))
        $script:R4dS.Now[$gw] = [string](($body | ConvertFrom-Json).name)
        return @{ ok = $true; text = '' }
      }
      $script:R4dS.CtlGet++
      if ($path -eq '/version') { return @{ ok = $true; text = '{"version":"fake-0.0"}' } }
      if ($path -like '/proxies/*') {
        $gr = [uri]::UnescapeDataString(($path -replace '^/proxies/', ''))
        if ($script:R4dS.Now.ContainsKey($gr)) { return @{ ok = $true; text = (@{ name = $gr; now = $script:R4dS.Now[$gr] } | ConvertTo-Json -Compress) } }
      }
      return @{ ok = $false; text = $null }
    }
    function Ctl-SelectNode($cfg, [string]$group, [string]$node) {
      $script:R4dS.Select++
      if (-not $group -or -not $node) { return $false }
      return (Invoke-Ctl $cfg 'PUT' ('/proxies/' + [uri]::EscapeDataString($group)) ('{"name":' + (ConvertTo-Json $node) + '}')).ok
    }
    function Save-Learned($cfg, [hashtable]$vals) {
      $script:R4dS.Save++
      foreach ($k in $vals.Keys) { $script:R4dS.SaveKeys += $k; $script:R4dS.SaveVals[$k] = $vals[$k] }
      if ($script:R4dS.Passthrough -and $script:R4dRealSaveBlock) { & $script:R4dRealSaveBlock $cfg $vals } else { foreach ($k in $vals.Keys) { $cfg | Add-Member -NotePropertyName $k -NotePropertyValue $vals[$k] -Force } }
    }
    $script:R4dRealSaveBlock = $r4dRealSave
    function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) $script:R4dS.Sleep++ }
    function Get-ProxyCore { $script:R4dS.Probe++; return $script:R4dS.Mihomo }
    function Get-TunAdapter { return $script:R4dS.Tun }
    function Start-Process { param([string]$FilePath, [string[]]$ArgumentList, $WindowStyle) $script:R4dS.ClashStart++; $script:R4dS.ClashStartPath = $FilePath }
    function Invoke-CslTzutilSet([string]$WindowsTzId) { $script:R4dS.Tzutil++; return $WindowsTzId }
    function Get-Trace([string]$url) { return @{ ip = '203.0.113.9'; loc = 'US'; colo = 'TST' } }
    function Invoke-Curl([string[]]$curlArgs) { return '{"timezone":"Asia/Tokyo"}' }
    function Find-ClaudeApp { @{ aumid = ''; exe = '' } }
    function Find-ClashExe { '' }
    function Find-NpmGlobalDir { '' }
    function New-R4dCfg([hashtable]$Over) {
      $c = [pscustomobject]@{ claudeGroup = 'Claude'; mainGroup = ''; pinMainGroup = $false; expectedNode = ''; timezone = ''; expectedTzIana = ''; controllerUrl = 'http://127.0.0.1:9'; controllerSecret = '' }
      foreach ($k in $Over.Keys) { $c | Add-Member -NotePropertyName $k -NotePropertyValue $Over[$k] -Force }
      return $c
    }
    function Invoke-R4dCapture([scriptblock]$Block) {
      $all = @(& $Block 6>&1)
      $txt = (@($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })) -join "`n"
      $val = @($all | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
      return @{ Text = $txt; Value = $val }
    }
    function Get-R4dSha([string]$Path) {
      $sha = [System.Security.Cryptography.SHA256]::Create()
      if (-not (Test-Path -LiteralPath $Path)) { return '<missing>' }
      try { return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path)))).Replace('-', '') } finally { $sha.Dispose() }
    }
    function Test-R4dItem([string]$Level, [string]$Id) { return (@($script:Items | Where-Object { $_.Level -eq $Level -and $_.Id -eq $Id }).Count -ge 1) }
    $r4dReady = $true
  } catch { $r4dSetupErr = $_.Exception.Message }

  if (-not $r4dReady) {
    Assert-True $false ("$($r4dN.Setup) ($r4dSetupErr)")
    Skip-CslDependents 'R4d functions / stubs' @($r4dN.Keys | Where-Object { $_ -ne 'Setup' } | ForEach-Object { $r4dN[$_] })
  } else {
    Assert-True $true $r4dN.Setup
    # ---- G: 守卫函数本身
    Assert-True ((Test-CslNoLaunchWriteAllowed) -and -not (Test-CslNoLaunchWriteAllowed -NoLaunch)) $r4dN.G1

    # ---- A: 节点锁路径（claudeGroup 非空，expectedNode 已存在且与当前不同）
    $cfgA = New-R4dCfg @{ expectedNode = 'NodeA' }
    Reset-R4dState @{ Claude = 'NodeB' }
    $rA = Invoke-R4dCapture { Invoke-CslNodeLock $cfgA -NoLaunch }
    Assert-True ($script:R4dS.Select -eq 0) $r4dN.A1
    Assert-True ($script:R4dS.CtlWrite -eq 0 -and $script:R4dS.CtlGet -ge 2) ("$($r4dN.A2) (writes=$($script:R4dS.CtlWrite), gets=$($script:R4dS.CtlGet))")
    Assert-True ($script:R4dS.Save -eq 0) $r4dN.A3
    Assert-True ($script:R4dS.Now['Claude'] -eq 'NodeB' -and $rA.Text.Contains('[NoLaunch] 已跳过切换节点') -and (Test-R4dItem 'FAIL' 'net.node_lock') -and ($rA.Value.Count -eq 1 -and $rA.Value[0] -eq $false)) $r4dN.A4
    Reset-R4dState @{ Claude = 'NodeB' }
    $rA2 = Invoke-R4dCapture { Invoke-CslNodeLock $cfgA }
    Assert-True ($script:R4dS.Select -eq 1 -and $script:R4dS.CtlWrite -eq 1 -and $script:R4dS.Now['Claude'] -eq 'NodeA' -and ($rA2.Value.Count -eq 1 -and $rA2.Value[0] -eq $true)) $r4dN.A5

    # ---- B: pinMainGroup + mainGroup
    $cfgB = New-R4dCfg @{ expectedNode = 'NodeA'; pinMainGroup = $true; mainGroup = 'Main' }
    Reset-R4dState @{ Claude = 'NodeB'; Main = 'NodeB' }
    $rB = Invoke-R4dCapture { Invoke-CslNodeLock $cfgB -NoLaunch }
    Assert-True ($script:R4dS.Select -eq 0 -and $script:R4dS.CtlWrite -eq 0 -and $script:R4dS.Now['Claude'] -eq 'NodeB' -and $script:R4dS.Now['Main'] -eq 'NodeB') $r4dN.B1
    Reset-R4dState @{ Claude = 'NodeB'; Main = 'NodeB' }
    $rB2 = Invoke-R4dCapture { Invoke-CslNodeLock $cfgB }
    Assert-True ($script:R4dS.Select -eq 2 -and $script:R4dS.CtlWrite -eq 2 -and $script:R4dS.Now['Main'] -eq 'NodeA') $r4dN.B2

    # ---- C: expectedNode 学习
    $cfgC = New-R4dCfg @{ expectedNode = '' }
    Reset-R4dState @{ Claude = 'NodeB' }
    $rC = Invoke-R4dCapture { Invoke-CslNodeLock $cfgC -NoLaunch }
    Assert-True ($script:R4dS.Save -eq 0 -and [string]$cfgC.expectedNode -eq '' -and $script:R4dS.Select -eq 0 -and $script:R4dS.CtlWrite -eq 0 -and $rC.Text.Contains('[NoLaunch] 已跳过')) $r4dN.C1
    $cfgC2 = New-R4dCfg @{ expectedNode = '' }
    Reset-R4dState @{ Claude = 'NodeB' }
    $rC2 = Invoke-R4dCapture { Invoke-CslNodeLock $cfgC2 }
    Assert-True ($script:R4dS.Save -eq 1 -and ($script:R4dS.SaveKeys -join ',') -eq 'expectedNode' -and [string]$script:R4dS.SaveVals['expectedNode'] -eq 'NodeB' -and [string]$cfgC2.expectedNode -eq 'NodeB') $r4dN.C2

    # ---- D: 时区（已配置 timezone，与当前不同）
    $cfgD = New-R4dCfg @{ timezone = 'Tokyo Standard Time' }
    Reset-R4dState @{}
    $rD = Invoke-R4dCapture { Invoke-CslTimezoneStep $cfgD 'Fake Standard Time' -NoLaunch }
    Assert-True ($script:R4dS.Tzutil -eq 0 -and $script:R4dS.Save -eq 0 -and ($rD.Value.Count -eq 1 -and $rD.Value[0] -eq 'Fake Standard Time') -and $rD.Text.Contains('[NoLaunch] 已跳过改时区') -and (Test-R4dItem 'FAIL' 'locale.system_tz')) $r4dN.D1
    Reset-R4dState @{}
    $rD2 = Invoke-R4dCapture { Invoke-CslTimezoneStep $cfgD 'Fake Standard Time' }
    Assert-True ($script:R4dS.Tzutil -eq 1 -and ($rD2.Value.Count -eq 1 -and $rD2.Value[0] -eq 'Tokyo Standard Time')) $r4dN.D2

    # ---- E: 真无配置路径（没有 preflight.json，Load-Config 只在临时目录里建默认文件；Save-Learned 桩直通到真函数，只写这个临时文件）
    $script:CfgPath = Join-Path $r4dTmp 'preflight.json'; $script:VergeDir = $r4dTmp
    $cfgE = Load-Config
    $r4dShaE0 = ''; if (Test-Path -LiteralPath $script:CfgPath) { $r4dShaE0 = Get-R4dSha $script:CfgPath }
    Assert-True ($cfgE.claudeGroup -eq 'Claude' -and [string]$cfgE.timezone -eq '' -and [string]$cfgE.expectedNode -eq '' -and $r4dShaE0 -ne '') $r4dN.E0
    Reset-R4dState @{ Claude = 'NodeB' }
    $script:R4dS.Passthrough = $true
    $rE1 = Invoke-R4dCapture { $null = Invoke-CslTimezoneStep $cfgE 'Fake Standard Time' -NoLaunch; $null = Invoke-CslNodeLock $cfgE -NoLaunch }
    $r4dShaE1 = Get-R4dSha $script:CfgPath
    Assert-True ($script:R4dS.Save -eq 0) $r4dN.E1
    Assert-True ($script:R4dS.Tzutil -eq 0) $r4dN.E2
    Assert-True ($script:R4dS.Select -eq 0 -and $script:R4dS.CtlWrite -eq 0) $r4dN.E3
    Assert-True ($r4dShaE1 -eq $r4dShaE0) $r4dN.E4
    $cfgE2 = Load-Config
    Reset-R4dState @{ Claude = 'NodeB' }
    $script:R4dS.Passthrough = $true
    $rE2 = Invoke-R4dCapture { $null = Invoke-CslTimezoneStep $cfgE2 'Fake Standard Time'; $null = Invoke-CslNodeLock $cfgE2 }
    $r4dShaE2 = Get-R4dSha $script:CfgPath
    Assert-True ($script:R4dS.Save -eq 2 -and ($script:R4dS.SaveKeys -contains 'timezone') -and ($script:R4dS.SaveKeys -contains 'expectedNode') -and $r4dShaE2 -ne $r4dShaE0) $r4dN.E5
    Assert-True ($script:R4dS.Tzutil -eq 1) $r4dN.E6

    # ---- 15:25 修订：-Relearn 例外、Load-Config -NoWrite、不启动 Clash
    Assert-True ((Test-CslLearnWriteAllowed) -and (Test-CslLearnWriteAllowed -Relearn) -and -not (Test-CslLearnWriteAllowed -NoLaunch) -and (Test-CslLearnWriteAllowed -NoLaunch -Relearn)) $r4dN.G2
    $r4dNwSb = $null
    if ($r4dLcArgText) { $r4dNwSb = [scriptblock]::Create('param($NoLaunch, $Relearn) ' + $r4dLcArgText) }
    $r4dNw = @{}
    foreach ($r4dCombo in @(@($true, $false), @($true, $true), @($false, $false), @($false, $true))) {
      $r4dNw[('{0}/{1}' -f $r4dCombo[0], $r4dCombo[1])] = $(if ($r4dNwSb) { [bool](& $r4dNwSb $r4dCombo[0] $r4dCombo[1]) } else { $null })
    }
    $r4dSeedFull = '{"claudeGroup":"Claude","expectedNode":"NodeZ","timezone":"Tokyo Standard Time","expectedIp":"203.0.113.1","expectedLoc":"US"}'
    $r4dClear = @{ expectedIp = ''; expectedLoc = ''; expectedNode = ''; timezone = ''; expectedTzIana = '' }
    $r4dUtf8 = New-Object System.Text.UTF8Encoding($false)

    # LC: Load-Config -NoWrite
    $r4dDirF = Join-Path $r4dTmp 'lc-nowrite'; New-Item -ItemType Directory -Path $r4dDirF -Force | Out-Null
    $script:CfgPath = Join-Path $r4dDirF 'preflight.json'; $script:VergeDir = $r4dDirF
    $cfgF = Load-Config -NoWrite
    Assert-True (-not (Test-Path -LiteralPath $script:CfgPath) -and $cfgF.claudeGroup -eq 'Claude' -and ($cfgF.PSObject.Properties.Name -contains 'timezone') -and ($cfgF.PSObject.Properties.Name -contains 'envFixEnabled') -and [string]$cfgF.controllerUrl -ne '') $r4dN.LC1
    $r4dDirG = Join-Path $r4dTmp 'lc-write'; New-Item -ItemType Directory -Path $r4dDirG -Force | Out-Null
    $script:CfgPath = Join-Path $r4dDirG 'preflight.json'; $script:VergeDir = $r4dDirG
    $cfgG = Load-Config
    $r4dGj = $null; if (Test-Path -LiteralPath $script:CfgPath) { $r4dGj = Get-Content -LiteralPath $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    Assert-True ($null -ne $r4dGj -and $r4dGj.claudeGroup -eq 'Claude' -and ($r4dGj.PSObject.Properties.Name -contains 'envFixEnabled')) $r4dN.LC2
    $r4dDirH = Join-Path $r4dTmp 'lc-partial'; New-Item -ItemType Directory -Path $r4dDirH -Force | Out-Null
    $script:CfgPath = Join-Path $r4dDirH 'preflight.json'; $script:VergeDir = $r4dDirH
    [IO.File]::WriteAllText($script:CfgPath, '{"claudeGroup":"Mine"}', $r4dUtf8)
    $r4dShaH0 = Get-R4dSha $script:CfgPath
    $cfgH = Load-Config -NoWrite
    $r4dShaH1 = Get-R4dSha $script:CfgPath
    $cfgH2 = Load-Config
    $r4dShaH2 = Get-R4dSha $script:CfgPath
    Assert-True ($r4dShaH1 -eq $r4dShaH0 -and $cfgH.claudeGroup -eq 'Mine' -and ($cfgH.PSObject.Properties.Name -contains 'timezone') -and $r4dShaH2 -ne $r4dShaH0) $r4dN.LC3
    $r4dDirI = Join-Path $r4dTmp 'lc-relearn'; New-Item -ItemType Directory -Path $r4dDirI -Force | Out-Null
    $script:CfgPath = Join-Path $r4dDirI 'preflight.json'; $script:VergeDir = $r4dDirI
    $cfgI = Load-Config -NoWrite:([bool]$r4dNw['True/True'])
    Assert-True ($r4dNw['True/False'] -eq $true -and $r4dNw['True/True'] -eq $false -and $r4dNw['False/False'] -eq $false -and $r4dNw['False/True'] -eq $false -and (Test-Path -LiteralPath $script:CfgPath)) $r4dN.LC4

    # RL: -NoLaunch -Relearn（面板「重新学习」）：写 preflight.json 允许，tz / 节点仍不动
    $r4dDirJ = Join-Path $r4dTmp 'relearn-pos'; New-Item -ItemType Directory -Path $r4dDirJ -Force | Out-Null
    $script:CfgPath = Join-Path $r4dDirJ 'preflight.json'; $script:VergeDir = $r4dDirJ
    [IO.File]::WriteAllText($script:CfgPath, $r4dSeedFull, $r4dUtf8)
    $cfgJ = Load-Config -NoWrite:([bool]$r4dNw['True/True'])
    $r4dShaJ0 = Get-R4dSha $script:CfgPath
    Reset-R4dState @{ Claude = 'NodeB' }
    $script:R4dS.Passthrough = $true
    $rJ = Invoke-R4dCapture { $null = Save-CslLearnedGuarded $cfgJ $r4dClear '' 'skip' -NoLaunch -Relearn; $null = Invoke-CslTimezoneStep $cfgJ 'Fake Standard Time' -NoLaunch -Relearn; $null = Invoke-CslNodeLock $cfgJ -NoLaunch -Relearn }
    $r4dJj = $null; if (Test-Path -LiteralPath $script:CfgPath) { $r4dJj = Get-Content -LiteralPath $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    Assert-True ($script:R4dS.Save -eq 3 -and ($script:R4dS.SaveKeys -contains 'timezone') -and ($script:R4dS.SaveKeys -contains 'expectedNode') -and $null -ne $r4dJj -and $r4dJj.timezone -eq 'Tokyo Standard Time' -and $r4dJj.expectedNode -eq 'NodeB' -and (Get-R4dSha $script:CfgPath) -ne $r4dShaJ0) $r4dN.RL1
    Assert-True ($script:R4dS.Tzutil -eq 0 -and $script:R4dS.Select -eq 0 -and $script:R4dS.CtlWrite -eq 0 -and $rJ.Text.Contains('[NoLaunch] 已跳过改时区')) $r4dN.RL2

    # RN: -NoLaunch 不带 -Relearn：一切自动学习与写入拦截
    $r4dDirK = Join-Path $r4dTmp 'relearn-neg'; New-Item -ItemType Directory -Path $r4dDirK -Force | Out-Null
    $script:CfgPath = Join-Path $r4dDirK 'preflight.json'; $script:VergeDir = $r4dDirK
    [IO.File]::WriteAllText($script:CfgPath, $r4dSeedFull, $r4dUtf8)
    $r4dShaK0 = Get-R4dSha $script:CfgPath
    $cfgK = Load-Config -NoWrite:([bool]$r4dNw['True/False'])
    Reset-R4dState @{ Claude = 'NodeB' }
    $script:R4dS.Passthrough = $true
    $rK = Invoke-R4dCapture { $null = Save-CslLearnedGuarded $cfgK $r4dClear '' 'skip' -NoLaunch; $null = Invoke-CslTimezoneStep $cfgK 'Fake Standard Time' -NoLaunch; $null = Invoke-CslNodeLock $cfgK -NoLaunch }
    Assert-True ($script:R4dS.Save -eq 0 -and (Get-R4dSha $script:CfgPath) -eq $r4dShaK0 -and [string]$cfgK.expectedNode -eq 'NodeZ' -and [string]$cfgK.timezone -eq 'Tokyo Standard Time') $r4dN.RN1
    Assert-True ($script:R4dS.Tzutil -eq 0 -and $script:R4dS.Select -eq 0 -and $script:R4dS.CtlWrite -eq 0 -and $rK.Text.Contains('[NoLaunch] 已跳过改时区') -and $rK.Text.Contains('[NoLaunch] 已跳过切换节点')) $r4dN.RN2
    # RC: 对照，不带 -NoLaunch
    $r4dDirL = Join-Path $r4dTmp 'relearn-ctl'; New-Item -ItemType Directory -Path $r4dDirL -Force | Out-Null
    $script:CfgPath = Join-Path $r4dDirL 'preflight.json'; $script:VergeDir = $r4dDirL
    [IO.File]::WriteAllText($script:CfgPath, $r4dSeedFull, $r4dUtf8)
    $r4dShaL0 = Get-R4dSha $script:CfgPath
    $cfgL = Load-Config
    Reset-R4dState @{ Claude = 'NodeB' }
    $script:R4dS.Passthrough = $true
    $rL = Invoke-R4dCapture { $null = Save-CslLearnedGuarded $cfgL $r4dClear '' 'skip' -Relearn; $null = Invoke-CslTimezoneStep $cfgL 'Fake Standard Time' -Relearn; $null = Invoke-CslNodeLock $cfgL -Relearn }
    Assert-True ($script:R4dS.Save -eq 3 -and (Get-R4dSha $script:CfgPath) -ne $r4dShaL0 -and [string]$cfgL.expectedNode -eq 'NodeB') $r4dN.RC1

    # CS: Clash 未运行
    $r4dClashExe = Join-Path $r4dTmp 'fake-clash.exe'; [IO.File]::WriteAllText($r4dClashExe, 'not an executable; Start-Process is a stub', $r4dUtf8)
    $cfgCS = New-R4dCfg @{ clashExe = $r4dClashExe }
    Reset-R4dState @{}
    $rCS1 = Invoke-R4dCapture { Invoke-CslClashStartStep $cfgCS $false -NoLaunch }
    Assert-True ($script:R4dS.ClashStart -eq 0 -and $rCS1.Text.Contains('[NoLaunch] 已跳过启动 Clash') -and $rCS1.Text.Contains('Clash Verge 未运行') -and (Test-R4dItem 'FAIL' 'net.clash_running')) $r4dN.CS1
    Reset-R4dState @{}
    $rCS2 = Invoke-R4dCapture { Invoke-CslClashStartStep $cfgCS $false }
    Assert-True ($script:R4dS.ClashStart -eq 1 -and $script:R4dS.ClashStartPath -eq $r4dClashExe -and -not (Test-R4dItem 'FAIL' 'net.clash_running') -and $rCS2.Text.Contains('正在启动')) $r4dN.CS2
    $cfgCS0 = New-R4dCfg @{ clashExe = '' }
    Reset-R4dState @{}
    $rCS3a = Invoke-R4dCapture { Invoke-CslClashStartStep $cfgCS0 $false -NoLaunch }
    $r4dCs3a = ($script:R4dS.ClashStart -eq 0 -and $rCS3a.Text.Contains('也没找到安装位置') -and (Test-R4dItem 'FAIL' 'net.clash_running'))
    Reset-R4dState @{}
    $rCS3b = Invoke-R4dCapture { Invoke-CslClashStartStep $cfgCS0 $false }
    Assert-True ($r4dCs3a -and $script:R4dS.ClashStart -eq 0 -and $rCS3b.Text.Contains('也没找到安装位置') -and (Test-R4dItem 'FAIL' 'net.clash_running')) $r4dN.CS3
    Reset-R4dState @{}
    $rCS4a = Invoke-R4dCapture { Invoke-CslClashStartStep $cfgCS $true -NoLaunch }
    $r4dCs4a = ($script:R4dS.ClashStart -eq 0 -and -not (Test-R4dItem 'FAIL' 'net.clash_running'))
    Reset-R4dState @{}
    $rCS4b = Invoke-R4dCapture { Invoke-CslClashStartStep $cfgCS $true }
    Assert-True ($r4dCs4a -and $script:R4dS.ClashStart -eq 0 -and -not (Test-R4dItem 'FAIL' 'net.clash_running') -and $rCS4b.Text.Contains('已运行')) $r4dN.CS4

    # ---- 15:49 修订：-NoLaunch 且 Clash 未运行时不等 TUN
    Reset-R4dState @{}
    $rTw1 = Invoke-R4dCapture { Invoke-CslClashStartStep $cfgCS $false -NoLaunch; $script:r4dTwv1 = Invoke-CslTunWaitStep $false 'M0' 'T0' -NoLaunch }
    $r4dTwv = $script:r4dTwv1
    Assert-True ($script:R4dS.Sleep -eq 0 -and $script:R4dS.Probe -eq 0 -and $r4dTwv.Waited -eq $false -and $r4dTwv.Mihomo -eq 'M0' -and $r4dTwv.Tun -eq 'T0' -and $script:R4dS.ClashStart -eq 0 -and (Test-R4dItem 'FAIL' 'net.clash_running') -and $rTw1.Text.Contains('已跳过等待 TUN')) $r4dN.TW1
    Reset-R4dState @{}
    $null = Invoke-R4dCapture { Invoke-CslClashStartStep $cfgCS $false; $script:r4dTwv2 = Invoke-CslTunWaitStep $false $null $null }
    Assert-True ($script:R4dS.Sleep -eq 15 -and $script:R4dS.Probe -eq 15 -and $script:r4dTwv2.Waited -eq $true -and $null -eq $script:r4dTwv2.Tun -and $script:R4dS.ClashStart -eq 1) $r4dN.TW2
    Reset-R4dState @{}
    $script:R4dS.Mihomo = 'MIH'; $script:R4dS.Tun = [pscustomobject]@{ Name = 'FakeTun'; Status = 'Up' }
    $null = Invoke-R4dCapture { $script:r4dTwv3 = Invoke-CslTunWaitStep $false $null $null }
    Assert-True ($script:R4dS.Sleep -eq 1 -and $script:r4dTwv3.Waited -eq $true -and $script:r4dTwv3.Tun.Name -eq 'FakeTun' -and $script:r4dTwv3.Mihomo -eq 'MIH') $r4dN.TW3
    Reset-R4dState @{}
    $null = Invoke-R4dCapture { $script:r4dTwv4 = Invoke-CslTunWaitStep $true $null $null -NoLaunch }
    Assert-True ($script:R4dS.Sleep -eq 15 -and $script:r4dTwv4.Waited -eq $true) $r4dN.TW4
  }
} finally {
  $script:CfgPath = $r4dSavedCfgPath; $script:VergeDir = $r4dSavedVergeDir
  $script:Items = $r4dSavedItems; $script:CurrentHead = $r4dSavedHead
  foreach ($r4dFnN in $r4dStubNames) {
    if ($r4dSaved[$r4dFnN]) { Set-Item "function:script:$r4dFnN" $r4dSaved[$r4dFnN] } else { Remove-Item "function:$r4dFnN" -ErrorAction SilentlyContinue }
  }
  Remove-Item 'function:Invoke-CslTzutilSet' -ErrorAction SilentlyContinue
  Remove-Item 'function:Start-Process' -ErrorAction SilentlyContinue
  Remove-Item 'function:Start-Sleep' -ErrorAction SilentlyContinue
  try { Remove-Item -LiteralPath $r4dTmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

Write-Host '== R1: group 9 relay variables show name + status only on every exit (CSL_TEST_* canaries, no real ANTHROPIC_*) ==' -ForegroundColor Cyan
# 出口：CLI 检查行、面板卡片数据、issue 导出「当前状态」、JSON current（回归）。第 9 组只显示 NAME + 状态，不显示值，也不显示打码值。
# 做法：从 claude-preflight.ps1 取第 9 节原文（到 HTTPS_PROXY 行之前）和 Say-* / Format-* 函数原文，在进程内用假环境变量表（$script:CslEnvStore）真实执行，
# 不碰真实环境变量 / 注册表 / 网络。「面板数据」＝ CLI 输出行经 claude-panel.html 同一条行解析正则得到的卡片行；面板卡片按 esc(r.text) 原样渲染。
$r1Names = @('CSL_TEST_R1_USERVAR', 'CSL_TEST_R1_KEEPVAR', 'CSL_TEST_R1_MACHVAR')
$r1Vals = @('csl-r1-user-canary-7f3q', 'csl-r1-keep-canary-5d8w', 'csl-r1-mach-canary-2k9x')
$r1Suffix = '（会让 Claude Code 走第三方接口）'
$r1MachSuffix = '（会让 Claude Code 走第三方接口；仅机器级存在，需要管理员手动处理）'
$r1UserRow0 = ('用户级 {0}：已设置{1}' -f $r1Names[0], $r1Suffix)
$r1KeepRow0 = ('用户级 {0}：已设置{1}' -f $r1Names[1], $r1Suffix)
$r1MachRow0 = ('机器级 {0}：已设置{1}' -f $r1Names[2], $r1MachSuffix)
function Test-R1Any([string]$Text, [string[]]$Needles) { foreach ($n in $Needles) { if ($Text.Contains($n)) { return $true } }; return $false }
function Get-R1EnvLines([string[]]$Lines, [string[]]$Names) { @($Lines | Where-Object { Test-R1Any ([string]$_) $Names }) }
$r1PfPath = Join-Path $root 'claude-preflight.ps1'
$r1PfSrc = [IO.File]::ReadAllText($r1PfPath)
$r1PfAst = [System.Management.Automation.Language.Parser]::ParseFile($r1PfPath, [ref]$null, [ref]$null)
$r1FnNames = @('Format-CslEnvUserItemText', 'Format-CslEnvMachineItemText', 'Add-Item', 'Say-Head', 'Say-Pass', 'Say-Info', 'Say-Fix', 'Say-Note', 'Say-Warn', 'Say-Fail')
$r1Fn = @{}
foreach ($r1n in $r1FnNames) {
  $r1a = $r1PfAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $r1n }, $true) | Select-Object -First 1
  $r1Fn[$r1n] = $r1a
}
Assert-True (@($r1FnNames | Where-Object { $null -eq $r1Fn[$_] }).Count -eq 0) 'R1 [setup] preflight defines the two Format-CslEnv*ItemText functions and the Say-* / Add-Item helpers'
$r1Calls = { param($ast) @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() }) }
$r1S = $r1PfSrc.IndexOf("Say-Head '9. 环境变量'")
$r1E = $r1PfSrc.IndexOf('$hp = [Environment]::GetEnvironmentVariable(''HTTPS_PROXY''')
Assert-True ($r1S -ge 0 -and $r1E -gt $r1S) 'R1 [setup] group 9 section (Say-Head 9 up to the HTTPS_PROXY line) found in claude-preflight.ps1'
$r1Block = ''; if ($r1S -ge 0 -and $r1E -gt $r1S) { $r1Block = $r1PfSrc.Substring($r1S, $r1E - $r1S) }

# ---- static: group 9 no longer calls Protect-Secret / Mask-Value; HTTPS_PROXY row and the masking helpers are untouched
$r1UCalls = @(); if ($r1Fn['Format-CslEnvUserItemText']) { $r1UCalls = & $r1Calls $r1Fn['Format-CslEnvUserItemText'] }
$r1MCalls = @(); if ($r1Fn['Format-CslEnvMachineItemText']) { $r1MCalls = & $r1Calls $r1Fn['Format-CslEnvMachineItemText'] }
Assert-True ($r1UCalls -notcontains 'Protect-Secret' -and $r1UCalls -notcontains 'Mask-Value' -and $r1MCalls -notcontains 'Protect-Secret' -and $r1MCalls -notcontains 'Mask-Value') 'R1 [static] Format-CslEnvUserItemText / Format-CslEnvMachineItemText do not call Protect-Secret or Mask-Value'
$r1BlockAst = [System.Management.Automation.Language.Parser]::ParseInput($r1Block, [ref]$null, [ref]$null)
$r1BCalls = & $r1Calls $r1BlockAst
Assert-True ($r1Block.Length -gt 0 -and $r1BCalls -notcontains 'Protect-Secret' -and $r1BCalls -notcontains 'Mask-Value') 'R1 [static] group 9 section (up to the HTTPS_PROXY line) calls neither Protect-Secret nor Mask-Value'
Assert-True ($r1PfSrc.Contains('if ($hp) { Say-Pass ("HTTPS_PROXY={0}" -f (Mask-Value -Value $hp -Kind Url)) } else {')) 'R1 [static] HTTPS_PROXY row unchanged (still HTTPS_PROXY=<Mask-Value -Kind Url>, out of R1 scope)'
$r1CmAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'claude-common.ps1'), [ref]$null, [ref]$null)
$r1Sha = New-Object System.Security.Cryptography.SHA256Managed
$r1Hash = {
  param($name)
  $a = $r1CmAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
  if (-not $a) { return 'missing' }
  $b = [Text.Encoding]::UTF8.GetBytes(($a.Extent.Text -replace "`r`n", "`n"))
  return (([BitConverter]::ToString($r1Sha.ComputeHash($b)) -replace '-', '').ToLowerInvariant().Substring(0, 12))
}
$r1MvHash = & $r1Hash 'Mask-Value'; $r1PsHash = & $r1Hash 'Protect-Secret'
Assert-True ($r1MvHash -eq '11a140e8a77b' -and $r1PsHash -eq '11092d710eb4') ("R1 [static] Mask-Value and Protect-Secret in claude-common.ps1 are unchanged (function-text SHA256 sha12 Mask-Value=$r1MvHash Protect-Secret=$r1PsHash)")
$r1Html = [IO.File]::ReadAllText((Join-Path $root 'claude-panel.html'))
$r1PanelRowRx = '^\s+\[(通过|信息|修复|提示|警告|失败)\]\s*(.*)$'
Assert-True ($r1Html.Contains('line.match(/^\s+\[(通过|信息|修复|提示|警告|失败)\]\s*(.*)$/)')) 'R1 [panel] the panel line parser regex is the one this test uses to derive panel card rows'
Assert-True ($r1Html.Contains('<span class="txt">${esc(r.text)}</span>')) 'R1 [panel] a card row renders esc(r.text) verbatim (no masking or rewriting of row text in the panel)'

# ---- run the real group 9 code with fake env tables (user, user+envFixKeep, machine-only)
$r1Saved = @{ Items = $script:Items; Head = $script:CurrentHead; Store = $script:CslEnvStore; Pat = $script:FixPatterns; Fix = $script:EnvFixSettings }
$r1Ok = $false; $r1Lines = @(); $r1Items = @()
try {
  foreach ($r1n in $r1FnNames) { if ($r1Fn[$r1n]) { . ([scriptblock]::Create($r1Fn[$r1n].Extent.Text)) } }
  $script:CslEnvStore = [pscustomobject]@{
    ListUserNames    = { @('CSL_TEST_R1_USERVAR', 'CSL_TEST_R1_KEEPVAR') }
    ListMachineNames = { @('CSL_TEST_R1_MACHVAR') }
    GetMachine       = { param($n) if ($n -eq 'CSL_TEST_R1_MACHVAR') { 'csl-r1-mach-canary-2k9x' } else { $null } }
    GetUserEntry     = { param($n)
      if ($n -eq 'CSL_TEST_R1_USERVAR') { @{ Value = 'csl-r1-user-canary-7f3q'; Kind = 'String' } }
      elseif ($n -eq 'CSL_TEST_R1_KEEPVAR') { @{ Value = 'csl-r1-keep-canary-5d8w'; Kind = 'String' } }
      else { $null } }
  }
  $script:Items = New-Object System.Collections.ArrayList
  $script:CurrentHead = ''
  $script:FixPatterns = @('CSL_TEST_R1_*')
  $script:EnvFixSettings = @{ enabled = $true; keep = @('CSL_TEST_R1_KEEPVAR') }
  $TestMode = $true; $NoPause = $true; $FixEnv = $false; $FailAtIndex = 0
  $r1Lines = @(& { . ([scriptblock]::Create($r1Block)) } 6>&1 | ForEach-Object { [string]$_ })
  $r1Items = @($script:Items.ToArray())
  $r1Ok = $true
} catch { Write-Host ("  FAIL  R1 [setup] group 9 section did not run: {0}" -f $_.Exception.Message) -ForegroundColor Red; $script:Fail++ }
finally {
  $script:Items = $r1Saved.Items; $script:CurrentHead = $r1Saved.Head; $script:CslEnvStore = $r1Saved.Store
  $script:FixPatterns = $r1Saved.Pat; $script:EnvFixSettings = $r1Saved.Fix
}
Assert-True ($r1Ok -and $r1Lines.Count -gt 0 -and $r1Items.Count -eq 3) ('R1 [setup] group 9 ran against the fake table: {0} output lines, {1} items (user, keep, machine-only)' -f $r1Lines.Count, $r1Items.Count)

# ---- Format helpers: name + status, value ignored
$r1FmtU = ''; $r1FmtM = ''
if ($r1Ok) { $r1FmtU = Format-CslEnvUserItemText $r1Names[0] $r1Vals[0]; $r1FmtM = Format-CslEnvMachineItemText $r1Names[2] }
Assert-Eq $r1FmtU $r1UserRow0 'R1 [format] user row = 用户级 NAME：已设置（会让 Claude Code 走第三方接口）, the value argument is ignored'
Assert-Eq $r1FmtM $r1MachRow0 'R1 [format] machine row = 机器级 NAME：已设置（…；仅机器级存在，需要管理员手动处理）'

# ---- exit 1: CLI check lines
$r1Cli = $r1Lines -join "`n"
$r1CliEnv = Get-R1EnvLines $r1Lines $r1Names
Assert-True (-not (Test-R1Any $r1Cli $r1Vals) -and $r1Lines.Count -gt 0) 'R1 [cli] the CLI output has 0 occurrences of any canary value'
Assert-True ($r1CliEnv.Count -ge 4 -and @($r1CliEnv | Where-Object { $_.Contains('*') }).Count -eq 0) ('R1 [cli] the {0} CLI lines naming a group 9 variable have 0 "*"' -f $r1CliEnv.Count)
Assert-True ($r1CliEnv.Count -ge 4 -and @($r1CliEnv | Where-Object { $_.Contains('=') }).Count -eq 0 -and @($r1Names | Where-Object { $r1Cli -match ([regex]::Escape($_) + '\s*=') }).Count -eq 0) 'R1 [cli] the CLI lines naming a group 9 variable have 0 "=" (no NAME=value, no NAME=masked)'
Assert-True (@($r1Names | Where-Object { $r1Cli.Contains($_) }).Count -eq 3) 'R1 [cli] all three variable names (user, envFixKeep, machine-only) are present in the CLI output'
Assert-True ($r1Lines -contains ('  [失败] ' + $r1UserRow0) -and $r1Lines -contains ('  [失败] ' + $r1KeepRow0) -and $r1Lines -contains ('  [提示] ' + $r1MachRow0)) 'R1 [cli] CLI lines are exactly: [失败] 用户级 NAME：已设置（…） x2 and [提示] 机器级 NAME：已设置（…）'
Assert-True ($r1Lines -contains ('  [信息] {0} 在 envFixKeep 中，一键修复会保留它' -f $r1Names[1]) -and @($r1Lines | Where-Object { $_ -eq 'CSL_FIX_ID=envfix.user-anthropic' }).Count -eq 2) 'R1 [cli] fixed notes unchanged: envFixKeep info line, and CSL_FIX_ID=envfix.user-anthropic once per user row'

# ---- exit 2: panel card data (CLI lines through the panel's own row parser)
$r1Rows = @()
foreach ($r1l in $r1Lines) { $r1m = [regex]::Match(($r1l -replace '^\uFEFF', '').TrimEnd(), $r1PanelRowRx); if ($r1m.Success) { $r1Rows += [pscustomobject]@{ lvl = $r1m.Groups[1].Value; text = $r1m.Groups[2].Value } } }
$r1RowTexts = @($r1Rows | ForEach-Object { $_.text })
$r1PanelEnv = @($r1RowTexts | Where-Object { Test-R1Any $_ $r1Names })
Assert-True ($r1Rows.Count -gt 0 -and -not (Test-R1Any ($r1RowTexts -join "`n") $r1Vals)) ('R1 [panel] panel card data ({0} rows) has 0 occurrences of any canary value' -f $r1Rows.Count)
Assert-True ($r1PanelEnv.Count -ge 4 -and @($r1PanelEnv | Where-Object { $_.Contains('*') }).Count -eq 0) ('R1 [panel] the {0} group 9 card rows have 0 "*"' -f $r1PanelEnv.Count)
Assert-True ($r1PanelEnv.Count -ge 4 -and @($r1PanelEnv | Where-Object { $_.Contains('=') }).Count -eq 0) 'R1 [panel] the group 9 card rows have 0 "=" (no =value, no =masked)'
Assert-True (@($r1Names | Where-Object { $n = $_; @($r1PanelEnv | Where-Object { $_.Contains($n) }).Count -ge 1 }).Count -eq 3) 'R1 [panel] all three variable names are present in the group 9 card rows'
Assert-True (@($r1Rows | Where-Object { $_.lvl -eq '失败' -and $_.text -eq $r1UserRow0 }).Count -eq 1 -and @($r1Rows | Where-Object { $_.lvl -eq '失败' -and $_.text -eq $r1KeepRow0 }).Count -eq 1 -and @($r1Rows | Where-Object { $_.lvl -eq '提示' -and $_.text -eq $r1MachRow0 }).Count -eq 1) 'R1 [panel] card rows read: 失败 用户级 NAME：已设置（…） x2 (the fixable-row test /用户级/ still matches) and 提示 机器级 NAME：已设置（…）'

# ---- exit 3: issue export「当前状态」(real Format-CslIssuePack on the real items)
$r1Pack = ''; $r1Cur = @()
if ($r1Ok) { $r1Pack = Format-CslIssuePack -Items $r1Items; $r1Cur = @(($r1Pack -split "`r?`n") | Where-Object { $_.StartsWith('当前状态: ') }) }
Assert-True ($r1Pack.Contains('---- 问题 1 ----') -and -not (Test-R1Any $r1Pack $r1Vals)) 'R1 [issue] the issue export text has 0 occurrences of any canary value'
$r1PackEnv = @(($r1Pack -split "`r?`n") | Where-Object { Test-R1Any $_ $r1Names })
Assert-True ($r1Cur.Count -eq 2 -and $r1PackEnv.Count -eq 4 -and @($r1PackEnv | Where-Object { $_.Contains('*') }).Count -eq 0) 'R1 [issue] the 4 issue export lines naming a variable (问题 + 「当前状态」, x2) have 0 "*"'
Assert-True ($r1Cur.Count -eq 2 -and $r1PackEnv.Count -eq 4 -and @($r1PackEnv | Where-Object { $_.Contains('=') }).Count -eq 0) 'R1 [issue] the 4 issue export lines naming a variable have 0 "=" (no =value, no =masked)'
Assert-True (@($r1Names[0], $r1Names[1] | Where-Object { $r1Pack.Contains($_) }).Count -eq 2) 'R1 [issue] both user variable names are present in the issue export'
Assert-True ($r1Cur -contains ('当前状态: ' + $r1UserRow0) -and $r1Cur -contains ('当前状态: ' + $r1KeepRow0)) 'R1 [issue] 「当前状态」 reads 用户级 NAME：已设置（会让 Claude Code 走第三方接口） for each user variable'

# ---- exit 4 (regression only): JSON current / fixId / status
$r1Json = @()
if ($r1Ok) { $r1Mapped = New-CslScoreMappedResults $r1Items; $r1Json = @($r1Mapped) }
$r1JU = @($r1Json | Where-Object { $_.id -eq 'cfg.env_relay_user' }); $r1JM = @($r1Json | Where-Object { $_.id -eq 'cfg.env_relay_machine' })
$r1JCur = @($r1Json | ForEach-Object { [string]$_.current })
Assert-True ($r1JU.Count -eq 2 -and $r1JM.Count -eq 1 -and [string]$r1JU[0].current -eq ('用户级 ' + $r1Names[0] + '：已设置') -and [string]$r1JU[1].current -eq ('用户级 ' + $r1Names[1] + '：已设置') -and [string]$r1JM[0].current -eq ('机器级 ' + $r1Names[2] + '：已设置')) 'R1 [json] checks[].current = 用户级 NAME：已设置 (x2) and 机器级 NAME：已设置 (name + status only)'
Assert-True ($r1JCur.Count -eq 3 -and -not (Test-R1Any ($r1JCur -join "`n") $r1Vals) -and -not (($r1JCur -join '') -match '[*=]')) 'R1 [json] checks[].current has 0 canary values, 0 "*", 0 "="'
$r1JChecks = @(); if ($r1Ok) { $r1JChecks = @((Get-CslRulesScore -Catalog $cat -Results @($r1Json)).checks) }
$r1CU = @($r1JChecks | Where-Object { $_.id -eq 'cfg.env_relay_user' }); $r1CM = @($r1JChecks | Where-Object { $_.id -eq 'cfg.env_relay_machine' })
Assert-True ($r1CU.Count -eq 2 -and [string]$r1CU[0].fixId -eq 'envfix.user-anthropic' -and [string]$r1CU[1].fixId -eq 'envfix.user-anthropic' -and [string]$r1CU[0].status -eq 'failed' -and $r1CM.Count -eq 1 -and [string]$r1CM[0].fixId -eq '' -and [string]$r1CM[0].status -eq 'info') 'R1 [json] regression: scored checks keep user rows failed + fixId envfix.user-anthropic, machine row info + no fixId'
$r1JsonTmp = Join-Path ([IO.Path]::GetTempPath()) ('csl-r1-result-' + [guid]::NewGuid().ToString('n') + '.json')
try {
  $r1JScore = Get-CslRulesScore -Catalog $cat -Results @($r1Json)
  $r1JPayload = New-CslPreflightResult -ScoreResult $r1JScore -Platform 'win' -Verdict 'blocked'
  Write-CslPreflightResultJson -Result $r1JPayload -Path $r1JsonTmp | Out-Null
  $r1JRaw = [IO.File]::ReadAllText($r1JsonTmp, (New-Object System.Text.UTF8Encoding($false)))
  Assert-True ($r1JRaw.Length -gt 0 -and -not (Test-R1Any $r1JRaw $r1Vals) -and -not $r1JRaw.Contains('*') -and (@($r1Names | Where-Object { $r1JRaw.Contains($_) }).Count -eq 3)) 'R1 [json] preflight-result.json text: 0 canary values, 0 "*", all three names present'
} finally { Remove-Item -LiteralPath $r1JsonTmp -Force -ErrorAction SilentlyContinue }

Write-Host '== R6: JSON keys frozen as v1 (docs/preflight-json-schema.md <-> real JSON) ==' -ForegroundColor Cyan
# Parses the doc's machine-readable key table ("| scope | `key` | 是/否 |") and compares it with the keys of a real
# New-CslPreflightResult payload after a write/ConvertFrom-Json round trip. Read-only; temp file only; no ANTHROPIC_* touched.
$r6Names = [ordered]@{
  DocNoDraft    = 'R6 [doc] title/status says FROZEN v1 and has no DRAFT / candidate marking'
  DocBumpRule   = 'R6 [doc] states the rule: renaming a key requires bumping schemaVersion'
  DocSvRow      = 'R6 [doc] schemaVersion is documented as fixed integer 1'
  DocTable      = 'R6 [doc] key table parses: top 11 / summary 5 / checks 16 (15 required + 1 optional) / browserCap 3'
  JsonSv        = 'R6 [json] round-tripped payload has schemaVersion = 1 (integer)'
  TopSet        = 'R6 [json] top-level key set equals the doc key set (missing 0, extra 0)'
  SummarySet    = 'R6 [json] summary key set equals the doc key set (missing 0, extra 0)'
  CapSet        = 'R6 [json] browserCap key set equals the doc key set (missing 0, extra 0)'
  RowNoExtra    = 'R6 [json] no checks[] row has a key that is not in the doc (extra 0)'
  RowNoMissing  = 'R6 [json] every checks[] row has every required doc key (missing 0)'
  RowNotes      = 'R6 [json] optional notes is present on the meta.unmapped row only and is documented optional'
  SampleSet     = 'R6 [doc] the sample JSON block uses exactly the documented keys (top / summary / checks[0] / browserCap)'
}
$r6Doc = $null; $r6Tab = @{ top = @(); summary = @(); checks = @(); browserCap = @() }; $r6Opt = @{}
$r6Setup = $null; $r6Tmp = $null; $r6Loaded = $null; $r6Raw = ''
function Get-R6KeyDiff($Actual, $Documented) {
  $a = @($Actual | ForEach-Object { [string]$_ }); $d = @($Documented | ForEach-Object { [string]$_ })
  $missing = @($d | Where-Object { $a -notcontains $_ }); $extra = @($a | Where-Object { $d -notcontains $_ })
  return ('missing=[{0}] extra=[{1}]' -f ($missing -join ','), ($extra -join ','))
}
try {
  $r6Raw = [IO.File]::ReadAllText((Join-Path (Join-Path $root 'docs') 'preflight-json-schema.md'), (New-Object Text.UTF8Encoding($false)))
  $r6Doc = $r6Raw -split "`r?`n"
  foreach ($ln in $r6Doc) {
    $m = [regex]::Match($ln, '^\|\s*(top|summary|checks|browserCap)\s*\|\s*`([^`]+)`\s*\|\s*(是|否)\s*\|\s*$')
    if ($m.Success) {
      $r6Tab[$m.Groups[1].Value] += $m.Groups[2].Value
      if ($m.Groups[3].Value -eq '否') { $r6Opt[$m.Groups[1].Value + '.' + $m.Groups[2].Value] = $true }
    }
  }
  $r6Res = @(
    [pscustomobject]@{ id = 'net.tun'; status = 'failed'; current = 'TUN 未开启' },
    [pscustomobject]@{ id = 'exit.api_anthropic'; status = 'passed' },
    [pscustomobject]@{ id = 'net.browser_webrtc_chromium'; status = 'failed'; refDeductionOverride = 5 },
    [pscustomobject]@{ id = 'meta.unmapped'; status = 'error'; notes = '未映射：id 不在 rules/checks.json 里' }
  )
  $r6Score = Get-CslRulesScore -Catalog $cat -Results $r6Res
  $r6Payload = New-CslPreflightResult -ScoreResult $r6Score -Platform 'win' -Verdict 'blocked'
  $r6Tmp = Join-Path ([IO.Path]::GetTempPath()) ('csl-r6-' + [guid]::NewGuid().ToString('n') + '.json')
  Write-CslPreflightResultJson -Result $r6Payload -Path $r6Tmp | Out-Null
  $r6Loaded = Get-Content -LiteralPath $r6Tmp -Raw -Encoding UTF8 | ConvertFrom-Json
} catch { $r6Setup = [string]$_.Exception.Message }
finally { if ($r6Tmp) { Remove-Item -LiteralPath $r6Tmp -Force -ErrorAction SilentlyContinue } }
Assert-True ($null -eq $r6Setup -and $null -ne $r6Loaded -and $r6Doc.Count -gt 0) 'R6 setup: doc read and payload round-tripped (setup failure counts once; dependents are skipped)'
if ($null -ne $r6Setup -or $null -eq $r6Loaded) {
  Skip-CslDependents 'R6 setup' @($r6Names.Values)
} else {
  $r6Head = ($r6Doc | Select-Object -First 8) -join "`n"
  Assert-True (($r6Doc[0] -match 'FROZEN v1') -and ($r6Raw -notmatch 'DRAFT') -and ($r6Raw -notmatch 'candidate') -and ($r6Raw -notmatch '冻结候选')) $r6Names.DocNoDraft
  Assert-True ($r6Head -match '改键名必须升 schemaVersion') $r6Names.DocBumpRule
  Assert-True ($r6Raw -match '\|\s*`schemaVersion`\s*\|\s*固定整数 `1`') $r6Names.DocSvRow
  $r6Cnt = ('{0}/{1}/{2}/{3}' -f $r6Tab.top.Count, $r6Tab.summary.Count, $r6Tab.checks.Count, $r6Tab.browserCap.Count)
  Assert-True (($r6Cnt -eq '11/5/16/3') -and ($r6Opt.Count -eq 1) -and $r6Opt['checks.notes']) ($r6Names.DocTable + " (got $r6Cnt, optional=$($r6Opt.Count))")
  Assert-True ((($r6Loaded.schemaVersion -is [int]) -or ($r6Loaded.schemaVersion -is [long])) -and ($r6Loaded.schemaVersion -eq 1)) $r6Names.JsonSv
  Assert-Eq (Get-R6KeyDiff @($r6Loaded.PSObject.Properties.Name) $r6Tab.top) 'missing=[] extra=[]' $r6Names.TopSet
  Assert-Eq (Get-R6KeyDiff @($r6Loaded.summary.PSObject.Properties.Name) $r6Tab.summary) 'missing=[] extra=[]' $r6Names.SummarySet
  Assert-Eq (Get-R6KeyDiff @($r6Loaded.browserCap.PSObject.Properties.Name) $r6Tab.browserCap) 'missing=[] extra=[]' $r6Names.CapSet
  $r6Rows = @($r6Loaded.checks)
  $r6ReqKeys = @($r6Tab.checks | Where-Object { -not $r6Opt.ContainsKey('checks.' + $_) })
  $r6ExtraAll = New-Object System.Collections.ArrayList; $r6MissAll = New-Object System.Collections.ArrayList
  foreach ($row in $r6Rows) {
    $rn = @($row.PSObject.Properties.Name)
    foreach ($k in $rn) { if ($r6Tab.checks -notcontains $k) { [void]$r6ExtraAll.Add(('{0}:{1}' -f $row.id, $k)) } }
    foreach ($k in $r6ReqKeys) { if ($rn -notcontains $k) { [void]$r6MissAll.Add(('{0}:{1}' -f $row.id, $k)) } }
  }
  Assert-True ($r6Rows.Count -eq 4 -and $r6ExtraAll.Count -eq 0) ($r6Names.RowNoExtra + " (rows=$($r6Rows.Count) extra=[$($r6ExtraAll -join ',')])")
  Assert-True ($r6Rows.Count -eq 4 -and $r6MissAll.Count -eq 0) ($r6Names.RowNoMissing + " (rows=$($r6Rows.Count) missing=[$($r6MissAll -join ',')])")
  $r6WithNotes = @($r6Rows | Where-Object { @($_.PSObject.Properties.Name) -contains 'notes' } | ForEach-Object { $_.id })
  Assert-True (($r6WithNotes -join ',') -eq 'meta.unmapped' -and $r6Opt.ContainsKey('checks.notes')) $r6Names.RowNotes
  $r6SampleOk = $false; $r6SampleMsg = 'sample block not found'
  $r6M = [regex]::Match($r6Raw, '(?s)## 顶层形状\s*```json\s*(.*?)```')
  if ($r6M.Success) {
    $r6S = $r6M.Groups[1].Value | ConvertFrom-Json
    $r6D = @(
      (Get-R6KeyDiff @($r6S.PSObject.Properties.Name) $r6Tab.top),
      (Get-R6KeyDiff @($r6S.summary.PSObject.Properties.Name) $r6Tab.summary),
      (Get-R6KeyDiff @(@($r6S.checks)[0].PSObject.Properties.Name) $r6ReqKeys),
      (Get-R6KeyDiff @($r6S.browserCap.PSObject.Properties.Name) $r6Tab.browserCap)
    )
    $r6SampleMsg = $r6D -join ' | '
    $r6SampleOk = (@($r6D | Where-Object { $_ -ne 'missing=[] extra=[]' }).Count -eq 0)
  }
  Assert-True $r6SampleOk ($r6Names.SampleSet + " ($r6SampleMsg)")
}

Write-Host '== R7: one version number in panel .ver, preflight header + banner, CHANGELOG first heading ==' -ForegroundColor Cyan
$r7Want = 'v4.0.0'
$r7Names = [ordered]@{
  Panel   = 'R7 [panel] claude-panel.html has exactly one <span class="ver">vX.Y.Z</span>'
  Header  = 'R7 [preflight] header comment (.SYNOPSIS) carries one version vX.Y.Z'
  Banner  = 'R7 [preflight] startup banner "Claude 桌面版 启动前检查 vX.Y.Z" appears exactly once'
  Heading = 'R7 [changelog] first "## " heading is a dated version heading (not Unreleased): ## vX.Y.Z（YYYY-MM-DD）'
  Same    = 'R7 [all] panel .ver, preflight header, preflight banner and CHANGELOG first version heading carry the same version'
  Want    = ('R7 [all] that version is ' + $r7Want)
  Order   = 'R7 [changelog] no "## Unreleased" heading remains anywhere in CHANGELOG.md'
}
$r7Setup = $null; $r7Panel = @(); $r7Hdr = @(); $r7Ban = @(); $r7Chg = $null; $r7ChgFirst = ''
try {
  $r7PanelRaw = [IO.File]::ReadAllText((Join-Path $root 'claude-panel.html'), [Text.Encoding]::UTF8)
  $r7PfRaw = [IO.File]::ReadAllText((Join-Path $root 'claude-preflight.ps1'), [Text.Encoding]::UTF8)
  $r7ChgRaw = [IO.File]::ReadAllText((Join-Path $root 'CHANGELOG.md'), [Text.Encoding]::UTF8)
  $r7Panel = @([regex]::Matches($r7PanelRaw, '<span class="ver">(v\d+\.\d+\.\d+)</span>') | ForEach-Object { $_.Groups[1].Value })
  $r7Hdr = @([regex]::Matches($r7PfRaw, '(?s)\A\W*<#\s*\.SYNOPSIS\s*[^\r\n]*?[（(](v\d+\.\d+\.\d+)[）)]') | ForEach-Object { $_.Groups[1].Value })
  $r7Ban = @([regex]::Matches($r7PfRaw, "(?m)^Write-Host '\s*Claude 桌面版 启动前检查 (v\d+\.\d+\.\d+)'") | ForEach-Object { $_.Groups[1].Value })
  $r7Lines = $r7ChgRaw -split "`r?`n"
  $r7ChgFirst = [string]($r7Lines | Where-Object { $_ -match '^## ' } | Select-Object -First 1)
  $r7Chg = [regex]::Match($r7ChgFirst, '^## (v\d+\.\d+\.\d+)（\d{4}-\d{2}-\d{2}）\s*$')
  $r7Unrel = @($r7Lines | Where-Object { $_ -match '^##\s+Unreleased' }).Count
} catch { $r7Setup = [string]$_.Exception.Message }
Assert-True ($null -eq $r7Setup -and $null -ne $r7Chg) 'R7 setup: panel, preflight and CHANGELOG read (setup failure counts once; dependents are skipped)'
if ($null -ne $r7Setup -or $null -eq $r7Chg) {
  Skip-CslDependents 'R7 setup' @($r7Names.Values)
} else {
  Assert-True ($r7Panel.Count -eq 1) ($r7Names.Panel + " (found=$($r7Panel.Count))")
  Assert-True ($r7Hdr.Count -eq 1) ($r7Names.Header + " (found=$($r7Hdr.Count))")
  Assert-True ($r7Ban.Count -eq 1) ($r7Names.Banner + " (found=$($r7Ban.Count))")
  Assert-True ($r7Chg.Success) ($r7Names.Heading + " (first heading=[$r7ChgFirst])")
  $r7All = @($r7Panel) + @($r7Hdr) + @($r7Ban)
  if ($r7Chg.Success) { $r7All += $r7Chg.Groups[1].Value }
  $r7Distinct = @($r7All | Select-Object -Unique)
  Assert-True ($r7All.Count -eq 4 -and $r7Distinct.Count -eq 1) ($r7Names.Same + " (panel=[$($r7Panel -join ',')] header=[$($r7Hdr -join ',')] banner=[$($r7Ban -join ',')] changelog=[$(if ($r7Chg.Success) { $r7Chg.Groups[1].Value })])")
  Assert-True ($r7All.Count -eq 4 -and $r7Distinct.Count -eq 1 -and $r7Distinct[0] -eq $r7Want) ($r7Names.Want + " (got=[$($r7Distinct -join ',')])")
  Assert-True ($r7Unrel -eq 0) ($r7Names.Order + " (Unreleased headings=$r7Unrel)")
}

Write-Host ''
if ($script:Skipped.Count -gt 0) { Write-Host ("SKIPPED (setup failed): {0} assertion(s): {1}" -f $script:Skipped.Count, ($script:Skipped -join '; ')) -ForegroundColor Yellow }
if ($script:Fail -gt 0 -or $script:Uncaught -gt 0 -or $script:Skipped.Count -gt 0) {
  Write-Host "FAILED: $($script:Fail) assertion(s), $($script:Uncaught) uncaught error(s)" -ForegroundColor Red
  exit 1
}
Write-Host 'ALL PASSED' -ForegroundColor Green
exit 0
