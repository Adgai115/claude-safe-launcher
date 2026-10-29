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
    # screen/CLI text keeps the masked value (unchanged); proves the canary row is a real masked item
    Assert-True ($shown -like '*CSL_TEST_CANARY=*' -and $shown.Contains('*')) 'screen text still has NAME=masked'
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
# 每个 Say-Fail / Say-Warn / Say-Note / Soft-BrowserWarn 调用点都必须带 -Id <目录里的真实 id>（函数定义内部的转发调用除外）
$sayNames = @('Say-Fail', 'Say-Warn', 'Say-Note', 'Soft-BrowserWarn')
$callAsts = @($pfAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and ($sayNames -contains $n.GetCommandName()) }, $true))
$sites = New-Object System.Collections.ArrayList
$parseSiteId = $null
$badSites = New-Object System.Collections.ArrayList
foreach ($ca in $callAsts) {
  $anc = $ca.Parent; $inFn = $false
  while ($anc) { if ($anc -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $inFn = $true; break }; $anc = $anc.Parent }
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

Write-Host '== R4b-1 node server addresses from the Clash runtime config (fake config, temp dir only) ==' -ForegroundColor Cyan
$r4bBase = Join-Path ([IO.Path]::GetTempPath()) ("csl-r4b-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $r4bBase -Force | Out-Null
try {
  $r4bNodeIp = '203.0.113.91'
  $r4bNodeIp2 = '198.51.100.67'
  $r4bNodeDom = 'r4bcanary-node.example-csl.org'
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
  $r4bHashBefore = (Get-FileHash -LiteralPath $r4bYaml -Algorithm SHA256).Hash
  $r4bNodes = Get-CslClashNodeHosts -Path $r4bYaml
  Assert-True ([bool]$r4bNodes.ok) 'R4b-1 fake config: ok'
  Assert-Eq @($r4bNodes.hosts).Count 3 'R4b-1 fake config: 3 node servers'
  Assert-True ((@($r4bNodes.hosts) -contains $r4bNodeIp) -and (@($r4bNodes.hosts) -contains $r4bNodeIp2) -and (@($r4bNodes.hosts) -contains $r4bNodeDom)) 'R4b-1 fake config: node IPs and domain read'
  Assert-True (-not ((@($r4bNodes.hosts) -join ' ') -match [regex]::Escape($r4bSecret)) -and -not ((@($r4bNodes.hosts) -join ' ') -match 'r4b-sni|9097')) 'R4b-1 reads only server, not secret / sni / controller'
  Assert-Eq ((Get-FileHash -LiteralPath $r4bYaml -Algorithm SHA256).Hash) $r4bHashBefore 'R4b-1 Clash config unchanged after read'
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

Write-Host ''
if ($script:Fail -gt 0 -or $script:Uncaught -gt 0) {
  Write-Host "FAILED: $($script:Fail) assertion(s), $($script:Uncaught) uncaught error(s)" -ForegroundColor Red
  exit 1
}
Write-Host 'ALL PASSED' -ForegroundColor Green
exit 0
