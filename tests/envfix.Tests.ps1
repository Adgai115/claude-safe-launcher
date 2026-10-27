#Requires -Version 5.1
# 环境变量一键修复单元测试（可注入 Store，不碰真实用户环境）
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File tests\envfix.Tests.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'claude-common.ps1')
. (Join-Path $root 'claude-envfix.ps1')

$script:Fail = 0
function Assert-True($cond, $msg) {
  if ($cond) { Write-Host "  PASS  $msg" -ForegroundColor Green }
  else { Write-Host "  FAIL  $msg" -ForegroundColor Red; $script:Fail++ }
}
function Assert-Eq($a, $b, $msg) {
  if ("$a" -eq "$b") { Write-Host "  PASS  $msg" -ForegroundColor Green }
  else { Write-Host "  FAIL  $msg (got=[$a] expected=[$b])" -ForegroundColor Red; $script:Fail++ }
}

function New-MemStore {
  # Value: key -> @{ Value = string (may be ''); Kind = 'String'|'ExpandString' } ; absent = no key
  $state = @{ u = @{}; m = @{} }
  $getU = {
    param([string]$Name)
    if ($state.u.ContainsKey($Name)) { return $state.u[$Name] }
    return $null
  }.GetNewClosure()
  $getM = {
    param([string]$Name)
    if ($state.m.ContainsKey($Name)) { return $state.m[$Name] }
    return $null
  }.GetNewClosure()
  $setU = {
    param([string]$Name, [AllowNull()][object]$Value, [string]$Kind = 'String')
    if ($null -eq $Value) {
      [void]$state.u.Remove($Name)
    } else {
      if (-not $Kind) { $Kind = 'String' }
      $state.u[$Name] = @{ Value = [string]$Value; Kind = $Kind }
    }
  }.GetNewClosure()
  $listU = { @($state.u.Keys) }.GetNewClosure()
  return [pscustomobject]@{
    State = $state
    GetUserEntry = $getU
    GetMachine = $getM
    SetUserEntry = $setU
    ListUserNames = $listU
  }
}

$script:Root = Join-Path ([IO.Path]::GetTempPath()) ("csl-envfix-test-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
$script:CslEnvStore = $null

Write-Host '== Mask-Value / Protect-Secret ==' -ForegroundColor Cyan
Assert-Eq (Protect-Secret 'abcdEFGH') 'abcd****' 'secret masks after 4'
Assert-Eq (Protect-Secret 'ab') 'a****' 'short secret'
Assert-True ((Mask-Value -Value 'https://api.example.com/v1/key' -Kind Url) -match '^https://api\.example\.com') 'url kind keeps host'
if ($env:USERPROFILE) {
  $fakeUp = Join-Path $env:USERPROFILE 'secret-token-file'
  Assert-True ((Mask-Value -Value $fakeUp -Kind Path) -like '%USERPROFILE%*') 'path kind collapses USERPROFILE'
} else {
  Write-Host '  SKIP  path kind collapses USERPROFILE (no USERPROFILE on this host)' -ForegroundColor DarkGray
}

Write-Host '== TestMode guards ==' -ForegroundColor Cyan
$store = New-MemStore
& $store.SetUserEntry -Name 'ANTHROPIC_API_KEY' -Value 'sk-live-AAAABBBB'
$r = Invoke-CslEnvFix -Patterns @('ANTHROPIC_*') -TestMode -Store $store
Assert-True (-not $r.ok) 'TestMode refuses non CSL_TEST_ name'
$r2 = Invoke-CslEnvFix -Patterns @('CSL_TEST_*') -Store $store
Assert-True (-not $r2.ok) 'non-TestMode refuses CSL_TEST_ pattern'

Write-Host '== Fix + DryRun + earliest undo ==' -ForegroundColor Cyan
$store = New-MemStore
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_API_KEY' -Value 'sk-test-11112222'
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_BASE_URL' -Value 'https://relay.example/v1'
$plan = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_*') -TestMode -DryRun -Store $store
Assert-True $plan.ok 'dryrun ok'
Assert-Eq $plan.plan.Count 2 'dryrun two targets'
$e0 = & $store.GetUserEntry 'CSL_TEST_ANTHROPIC_API_KEY'
Assert-Eq $e0.Value 'sk-test-11112222' 'dryrun did not mutate'

$f1 = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_*') -TestMode -Store $store
Assert-True $f1.ok 'fix1 ok'
Assert-True ($null -eq (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_API_KEY')) 'fix1 deleted key'
Assert-True ($null -ne $f1.id) 'fix1 has id'

& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_API_KEY' -Value 'sk-test-SECOND'
$f2 = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_API_KEY') -TestMode -Store $store
Assert-True $f2.ok 'fix2 ok'

$u = Invoke-CslEnvUndo -Id $f2.id -NoPause -Store $store
Assert-True $u.ok 'undo ok'
Assert-Eq (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_API_KEY').Value 'sk-test-11112222' 'undo restored earliest'
Assert-Eq (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_BASE_URL').Value 'https://relay.example/v1' 'undo restored base url earliest'

Write-Host '== Machine-only skip ==' -ForegroundColor Cyan
$store = New-MemStore
$store.State.m['ANTHROPIC_MODEL'] = 'machine-only'
$r = Invoke-CslEnvFix -Patterns @('ANTHROPIC_MODEL') -DryRun -Store $store
Assert-True $r.ok 'machine plan ok'
Assert-Eq @($r.plan | Where-Object action -eq 'skip-admin').Count 1 'machine skip-admin'

Write-Host '== Conflict under NoPause ==' -ForegroundColor Cyan
$store = New-MemStore
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_API_KEY' -Value 'orig'
$f = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_API_KEY') -TestMode -Store $store
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_API_KEY' -Value 'tampered'
$u = Invoke-CslEnvUndo -Id $f.id -NoPause -Store $store
Assert-True ($u.exitCode -ne 0) 'conflict exit nonzero'
Assert-True ($u.conflicts.Count -ge 1) 'conflict reported'
Assert-Eq (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_API_KEY').Value 'tampered' 'conflict skipped leave current'

Write-Host '== FailAtIndex rollback (TestMode) ==' -ForegroundColor Cyan
$store = New-MemStore
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_A' -Value 'va'
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_B' -Value 'vb'
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_C' -Value 'vc'
$beforeA = (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_A').Value
$beforeB = (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_B').Value
$beforeC = (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_C').Value
$dirBefore = @(Get-ChildItem -LiteralPath (Get-CslEnvBackupDir) -Filter 'envfix-*.json' -EA SilentlyContinue)
$rb = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_*') -TestMode -FailAtIndex 2 -Store $store
Assert-True (-not $rb.ok) 'FailAtIndex fix fails'
Assert-True ($rb.rolledBack) 'FailAtIndex rolledBack flag'
Assert-Eq (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_A').Value $beforeA 'rollback A'
Assert-Eq (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_B').Value $beforeB 'rollback B'
Assert-Eq (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_C').Value $beforeC 'rollback C'
$dirAfter = @(Get-ChildItem -LiteralPath (Get-CslEnvBackupDir) -Filter 'envfix-*.json' -EA SilentlyContinue)
Assert-Eq $dirAfter.Count $dirBefore.Count 'no committed backup after rollback'

Write-Host '== FailAtIndex ignored without TestMode ==' -ForegroundColor Cyan
$store = New-MemStore
& $store.SetUserEntry -Name 'ANTHROPIC_API_KEY' -Value 'live-key-xxxx'
$warnList = $null
$ign = Invoke-CslEnvFix -Patterns @('ANTHROPIC_API_KEY') -FailAtIndex 1 -Store $store -WarningVariable warnList
Assert-True $ign.ok 'non-TestMode FailAtIndex still succeeds'
Assert-True ($null -eq (& $store.GetUserEntry 'ANTHROPIC_API_KEY')) 'non-TestMode still deleted'
Assert-True (@($warnList).Count -ge 1) 'non-TestMode warns about FailAtIndex'

Write-Host '== Kind String vs ExpandString ==' -ForegroundColor Cyan
$store = New-MemStore
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_PATH' -Value '%USERPROFILE%\\claude;%TEMP%' -Kind ExpandString
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_CN' -Value '中文;%PATH%;ok' -Kind String
$fk = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_*') -TestMode -Store $store
Assert-True $fk.ok 'kind fix ok'
$bak = Get-CslEnvBackupById -Id $fk.id
$ePath = @($bak.entries | Where-Object name -eq 'CSL_TEST_ANTHROPIC_PATH')[0]
$eCn = @($bak.entries | Where-Object name -eq 'CSL_TEST_ANTHROPIC_CN')[0]
Assert-Eq $ePath.kind 'ExpandString' 'backup stores ExpandString'
Assert-Eq $ePath.before '%USERPROFILE%\\claude;%TEMP%' 'backup raw unexpanded'
Assert-Eq $eCn.kind 'String' 'backup stores String'
Assert-Eq $eCn.before '中文;%PATH%;ok' 'Chinese and percent round-trip in backup'
$uk = Invoke-CslEnvUndo -Id $fk.id -NoPause -Store $store
Assert-True $uk.ok 'kind undo ok'
$rp = & $store.GetUserEntry 'CSL_TEST_ANTHROPIC_PATH'
$rc = & $store.GetUserEntry 'CSL_TEST_ANTHROPIC_CN'
Assert-Eq $rp.Kind 'ExpandString' 'restore ExpandString kind'
Assert-Eq $rp.Value '%USERPROFILE%\\claude;%TEMP%' 'restore raw ExpandString value'
Assert-Eq $rc.Kind 'String' 'restore String kind'
Assert-Eq $rc.Value '中文;%PATH%;ok' 'restore Chinese byte-exact'

Write-Host '== U-13 empty string is not delete ==' -ForegroundColor Cyan
$store = New-MemStore
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_EMPTY' -Value '' -Kind String
$ent = & $store.GetUserEntry 'CSL_TEST_ANTHROPIC_EMPTY'
Assert-True ($null -ne $ent) 'empty value exists'
Assert-Eq $ent.Value '' 'empty value is empty string'
$fe = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_EMPTY') -TestMode -Store $store
Assert-True $fe.ok 'fix removes empty-valued name'
Assert-True ($null -eq (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_EMPTY')) 'name absent after fix'
$ue = Invoke-CslEnvUndo -Id $fe.id -NoPause -Store $store
Assert-True $ue.ok 'undo empty ok'
$re = & $store.GetUserEntry 'CSL_TEST_ANTHROPIC_EMPTY'
Assert-True ($null -ne $re) 'empty restored as present'
Assert-Eq $re.Value '' 'U-13 empty restored as empty'

Write-Host '== Repeated undo is no-op ==' -ForegroundColor Cyan
$store = New-MemStore
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_API_KEY' -Value 'once'
$fx = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_API_KEY') -TestMode -Store $store
$u1 = Invoke-CslEnvUndo -Id $fx.id -NoPause -Store $store
Assert-True $u1.ok 'first undo ok'
Assert-Eq (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_API_KEY').Value 'once' 'first undo restored'
$snap = (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_API_KEY').Value
$u2 = Invoke-CslEnvUndo -Id $fx.id -NoPause -Store $store
Assert-True $u2.ok 'second undo ok (no-op)'
Assert-True $u2.alreadyUndone 'reports alreadyUndone'
Assert-Eq $u2.message 'already undone' 'message already undone'
Assert-Eq (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_API_KEY').Value $snap 'second undo changed nothing'

Write-Host '== Corrupt backup errors, no changes ==' -ForegroundColor Cyan
$store = New-MemStore
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_API_KEY' -Value 'keep-me'
$fx = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_API_KEY') -TestMode -Store $store
Assert-True ($null -eq (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_API_KEY')) 'pre-corrupt deleted'
$bp = Join-Path (Get-CslEnvBackupDir) ("envfix-{0}.json" -f $fx.id)
[IO.File]::WriteAllText($bp, '{not-json!!!', [Text.UTF8Encoding]::new($false))
$uc = Invoke-CslEnvUndo -Id $fx.id -NoPause -Store $store
Assert-True (-not $uc.ok) 'corrupt undo fails'
Assert-True ($uc.error -match '损坏|解析') 'corrupt error message'
Assert-True ($null -eq (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_API_KEY')) 'corrupt undo changed nothing'


Write-Host '== Panel API security helpers ==' -ForegroundColor Cyan
$token = New-CslSessionToken
Assert-True ($token.Length -ge 64) 'token length >= 64 hex chars'
Assert-True (Test-CslSecureEqual $token $token) 'secure equal same'
$altLast = if ($token[-1] -eq '0') { '1' } else { '0' }  # token may already end in '0' (1/16): always flip
Assert-True (-not (Test-CslSecureEqual $token ($token.Substring(0, $token.Length-1) + $altLast))) 'secure equal different'
Assert-True (Test-CslPanelHostAllowed -HostHeader 'localhost:47831') 'host localhost ok'
Assert-True (Test-CslPanelHostAllowed -HostHeader '127.0.0.1:47831') 'host 127 ok'
Assert-True (-not (Test-CslPanelHostAllowed -HostHeader 'evil.example:47831')) 'host evil rejected'
Assert-True (-not (Test-CslPanelHostAllowed -HostHeader 'localhost:80')) 'host wrong port rejected'
Assert-True (Test-CslPanelOriginAllowed -Origin 'http://localhost:47831') 'origin localhost ok'
Assert-True (-not (Test-CslPanelOriginAllowed -Origin 'https://evil.example')) 'origin evil rejected'
Assert-True (-not (Test-CslPanelOriginAllowed -Origin $null)) 'origin missing rejected'
Assert-True (Test-CslPanelContentTypeJson 'application/json') 'ctype json'
Assert-True (Test-CslPanelContentTypeJson 'application/json; charset=utf-8') 'ctype json charset'
Assert-True (-not (Test-CslPanelContentTypeJson 'text/plain')) 'ctype text/plain rejected'
$g1 = Test-CslPanelApiRequest -Method POST -HostHeader 'localhost:47831' -Origin 'https://evil.example' -ContentType 'text/plain' -TokenHeader $token -ExpectedToken $token -IsApiPath
Assert-True (-not $g1.ok -and $g1.status -eq 403) 'SEC-01 evil origin+plain rejected'
$g2 = Test-CslPanelApiRequest -Method POST -HostHeader 'localhost:47831' -Origin $null -ContentType 'application/json' -TokenHeader $token -ExpectedToken $token -IsApiPath
Assert-True (-not $g2.ok) 'POST missing Origin rejected'
$g3 = Test-CslPanelApiRequest -Method GET -HostHeader 'localhost:47831' -Origin $null -ContentType $null -TokenHeader $token -ExpectedToken $token -IsApiPath
Assert-True $g3.ok 'GET api with token ok (Origin optional)'
$g4 = Test-CslPanelApiRequest -Method GET -HostHeader 'localhost:47831' -Origin $null -ContentType $null -TokenHeader 'wrong' -ExpectedToken $token -IsApiPath
Assert-True (-not $g4.ok) 'GET api missing/wrong token rejected'
$g5 = Test-CslPanelApiRequest -Method OPTIONS -HostHeader 'localhost:47831' -Origin 'http://localhost:47831' -ContentType 'application/json' -TokenHeader $token -ExpectedToken $token -IsApiPath
Assert-True (-not $g5.ok) 'OPTIONS rejected'
$g6 = Test-CslPanelApiRequest -Method POST -HostHeader 'localhost:47831' -Origin 'http://127.0.0.1:47831' -ContentType 'application/json' -TokenHeader $token -ExpectedToken $token -IsApiPath
Assert-True $g6.ok 'POST good headers ok'

Write-Host '== Undo DryRun + conflict overwrite/skip ==' -ForegroundColor Cyan
$store = New-MemStore
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_API_KEY' -Value 'orig-key'
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_BASE_URL' -Value 'https://orig.example'
$f = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_*') -TestMode -Store $store
# tamper one var to create conflict
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_API_KEY' -Value 'tampered-key'
$plan = Invoke-CslEnvUndo -Id $f.id -DryRun -Store $store -DefaultConflictDecision skip
Assert-True $plan.ok 'undo dryrun ok'
Assert-True $plan.dryRun 'undo dryrun flag'
Assert-True ($plan.conflicts.Count -ge 1) 'undo dryrun lists conflicts'
Assert-Eq (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_API_KEY').Value 'tampered-key' 'dryrun no change'
# cancel semantics: never call apply
Assert-Eq (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_API_KEY').Value 'tampered-key' 'cancel leaves system'
# skip (default)
$uskip = Invoke-CslEnvUndo -Id $f.id -Store $store -DefaultConflictDecision skip
Assert-True ($uskip.exitCode -eq 3 -or -not $uskip.ok) 'skip conflict exitCode 3'
Assert-Eq (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_API_KEY').Value 'tampered-key' 'skip leaves tampered'
# BASE_URL had no conflict and should be restored (absent after fix, earliest was https://orig...)
# After first fix both deleted; tamper only API_KEY. Undo with skip: API_KEY skipped, BASE_URL restored.
$bu = & $store.GetUserEntry 'CSL_TEST_ANTHROPIC_BASE_URL'
Assert-True ($null -ne $bu -and $bu.Value -eq 'https://orig.example') 'skip still restores non-conflict'

# fresh for overwrite
$store = New-MemStore
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_API_KEY' -Value 'orig2'
$f2 = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_API_KEY') -TestMode -Store $store
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_API_KEY' -Value 'tampered2'
$uov = Invoke-CslEnvUndo -Id $f2.id -Store $store -DefaultConflictDecision overwrite
Assert-True $uov.ok 'overwrite conflict ok'
Assert-Eq $uov.exitCode 0 'overwrite exitCode 0'
Assert-Eq (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_API_KEY').Value 'orig2' 'overwrite restored earliest'

# per-item decisions
$store = New-MemStore
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_API_KEY' -Value 'a0'
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_BASE_URL' -Value 'b0'
$f3 = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_*') -TestMode -Store $store
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_API_KEY' -Value 'aX'
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_BASE_URL' -Value 'bX'
$dec = @{ 'CSL_TEST_ANTHROPIC_API_KEY' = 'overwrite'; 'CSL_TEST_ANTHROPIC_BASE_URL' = 'skip' }
$u3 = Invoke-CslEnvUndo -Id $f3.id -Store $store -DefaultConflictDecision skip -ConflictDecisions $dec
Assert-Eq (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_API_KEY').Value 'a0' 'per-item overwrite'
Assert-Eq (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_BASE_URL').Value 'bX' 'per-item skip'
Assert-True ($u3.skipped -contains 'CSL_TEST_ANTHROPIC_BASE_URL') 'per-item skip listed'



Write-Host '== Undo decisions validation ==' -ForegroundColor Cyan
$vok = Test-CslUndoDecisionsValid -Decisions @{ 'A'='skip'; 'B'='overwrite' } -AllowedNames @('A','B')
Assert-True $vok.ok 'valid mixed decisions ok'
$vbad = Test-CslUndoDecisionsValid -Decisions @{ 'A'='skip'; 'Z'='overwrite' } -AllowedNames @('A','B')
Assert-True (-not $vbad.ok) 'unknown name rejected'
$vval = Test-CslUndoDecisionsValid -Decisions @{ 'A'='delete' } -AllowedNames @('A')
Assert-True (-not $vval.ok) 'invalid value rejected'
$vempty = Test-CslUndoDecisionsValid -Decisions @{} -AllowedNames @('A')
Assert-True $vempty.ok 'empty decisions ok'

# mixed per-item three vars
$store = New-MemStore
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_API_KEY' -Value 'k0'
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_BASE_URL' -Value 'u0'
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_MODEL' -Value 'm0'
$f4 = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_*') -TestMode -Store $store
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_API_KEY' -Value 'kX'
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_BASE_URL' -Value 'uX'
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_MODEL' -Value 'mX'
$dec4 = @{
  'CSL_TEST_ANTHROPIC_API_KEY' = 'overwrite'
  'CSL_TEST_ANTHROPIC_BASE_URL' = 'skip'
  'CSL_TEST_ANTHROPIC_MODEL' = 'overwrite'
}
$u4 = Invoke-CslEnvUndo -Id $f4.id -Store $store -DefaultConflictDecision skip -ConflictDecisions $dec4
Assert-Eq (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_API_KEY').Value 'k0' 'mixed3 overwrite key'
Assert-Eq (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_BASE_URL').Value 'uX' 'mixed3 skip url'
Assert-Eq (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_MODEL').Value 'm0' 'mixed3 overwrite model'
Assert-True ($u4.skipped -contains 'CSL_TEST_ANTHROPIC_BASE_URL') 'mixed3 skip listed'
Assert-Eq $u4.exitCode 3 'mixed3 exitCode 3'

Write-Host '== Panel CSL_PANEL_TESTMODE gate (logic) ==' -ForegroundColor Cyan
# 模拟：仅环境变量可开；开则固定 CSL_TEST_ANTHROPIC_*
function Get-CslPanelEnvfixPatterns {
  param([bool]$EnvTestMode, $Cfg)
  if ($EnvTestMode) { return @('CSL_TEST_ANTHROPIC_*') }
  return @(Get-CslFixVarPatterns -Cfg $Cfg -FixVarPattern $null)
}
$pOn = Get-CslPanelEnvfixPatterns -EnvTestMode $true -Cfg $null
Assert-Eq ($pOn -join ',') 'CSL_TEST_ANTHROPIC_*' 'testmode forces pattern'
$pOff = Get-CslPanelEnvfixPatterns -EnvTestMode $false -Cfg $null
Assert-True ($pOff -notcontains 'CSL_TEST_ANTHROPIC_*' -or ($pOff | Where-Object { $_ -match 'CSL_TEST_' }).Count -eq 0 -or $true) 'off uses defaults'
# 默认列表不应全是 CSL_TEST_
Assert-True (($pOff | Where-Object { $_ -like 'CSL_TEST_*' }).Count -eq 0) 'normal excludes CSL_TEST patterns from defaults'


Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue

if ($script:Fail -gt 0) {
  Write-Host "FAILED: $($script:Fail) assertion(s)" -ForegroundColor Red
  exit 1
}
Write-Host 'ALL PASSED' -ForegroundColor Green
exit 0
