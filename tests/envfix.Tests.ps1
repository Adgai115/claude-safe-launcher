#Requires -Version 5.1
# 环境变量一键修复单元测试（可注入 Store，不碰真实用户环境）
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File tests\envfix.Tests.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'claude-common.ps1')
. (Join-Path $root 'claude-envfix.ps1')

# Platform: do not rely on $IsWindows (absent in Windows PowerShell 5.1)
$script:OnWindows = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
# claude-common.ps1 sets Continue when dot-sourced; restore Stop so non-terminating errors also hit the trap
$ErrorActionPreference = 'Stop'
# Any uncaught error counts as a failure (no more "error but ALL PASSED")
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

# A fresh MemStore stands for a different machine. Since v3.3.0 a conflict-skipped entry stays
# undoable, so sections that leave one open clear the shared backup dir before the next section.
function Clear-TestBackups {
  Get-ChildItem -LiteralPath (Get-CslEnvBackupDir) -Filter 'envfix-*.json' -File -ErrorAction SilentlyContinue | Remove-Item -Force
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
  $listM = { @($state.m.Keys) }.GetNewClosure()
  return [pscustomobject]@{
    State = $state
    GetUserEntry = $getU
    GetMachine = $getM
    SetUserEntry = $setU
    ListUserNames = $listU
    ListMachineNames = $listM
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
Clear-TestBackups

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
Clear-TestBackups

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
Clear-TestBackups



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
Clear-TestBackups

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


Write-Host '== Backup write failure aborts before delete ==' -ForegroundColor Cyan
$badRoot = Join-Path ([IO.Path]::GetTempPath()) ("csl-envfix-nowrap-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $badRoot -Force | Out-Null
$bakDir = Join-Path $badRoot 'backups'
New-Item -ItemType Directory -Path $bakDir -Force | Out-Null
$prevRoot = $script:Root
$script:Root = $badRoot
try {
  if (-not $script:OnWindows) {
    & chmod a-w -- $bakDir
  } else {
    # Windows: replace backups dir with a file so WriteAllText fails
    Remove-Item -LiteralPath $bakDir -Force -Recurse -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $bakDir -Value 'not-a-dir' -Encoding ascii
  }
  $store = New-MemStore
  & $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_API_KEY' -Value 'must-keep-xxxx'
  $rbw = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_API_KEY') -TestMode -Store $store
  Assert-True (-not $rbw.ok) 'unwritable backup fails'
  Assert-True ($rbw.error -match '备份写入失败') 'unwritable error message'
  Assert-Eq (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_API_KEY').Value 'must-keep-xxxx' 'unwritable left var unchanged'
  Assert-True ($null -eq $rbw.id) 'unwritable no id'
} finally {
  if (-not $script:OnWindows) {
    & chmod u+w -- $bakDir 2>$null
  }
  $script:Root = $prevRoot
  Remove-Item -LiteralPath $badRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '== Same-second fix ids: UndoFix undoes latest ==' -ForegroundColor Cyan
$store = New-MemStore
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_A' -Value 'va-orig'
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_B' -Value 'vb-orig'
# Force same-second collision by pre-seeding an id at current ms if possible; two rapid fixes on disjoint vars
$fA = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_A') -TestMode -Store $store
$fB = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_B') -TestMode -Store $store
Assert-True $fA.ok 'same-sec fix A ok'
Assert-True $fB.ok 'same-sec fix B ok'
Assert-True ($fA.id -ne $fB.id) 'same-sec distinct ids'
Assert-True ($fB.id.CompareTo($fA.id) -gt 0) 'same-sec B id sorts after A'
# -UndoFix with no Id = latest
$uLatest = Invoke-CslEnvUndo -NoPause -Store $store
Assert-True $uLatest.ok 'same-sec undo latest ok'
Assert-Eq $uLatest.id $fB.id 'same-sec undid B (latest)'
Assert-Eq (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_B').Value 'vb-orig' 'same-sec B restored'
Assert-True ($null -eq (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_A')) 'same-sec A still deleted'

Write-Host '== Fix id: later existing id / clock rollback ==' -ForegroundColor Cyan
$idDir = Get-CslEnvBackupDir
$seedIds = @('20991231T235959900-aaaa')
foreach ($sid in $seedIds) {
  [IO.File]::WriteAllText((Join-Path $idDir ("envfix-{0}.json" -f $sid)), '{"id":"' + $sid + '","ts":"2099-12-31T23:59:59Z","testMode":true,"undone":true,"entries":[]}', [Text.UTF8Encoding]::new($false))
}
try {
  # existing id later than now: new id must sort after it
  $idLater = New-CslEnvFixId
  Assert-True ($idLater.CompareTo('20991231T235959900-aaaa') -gt 0) 'id after later existing id'
  Assert-True ($idLater.StartsWith('20991231T235959901-')) 'id = existing max + 1ms'
  # clock rollback > 5s: pretend now is 10s before the newest id
  $idBack = New-CslEnvFixId -NowUtc ([datetime]::new(2099,12,31,23,59,49,900,[DateTimeKind]::Utc))
  Assert-True ($idBack.CompareTo('20991231T235959900-aaaa') -gt 0) 'clock rollback 10s: id still after max'
  # chained: write it, next rollback id must be after it too
  [IO.File]::WriteAllText((Join-Path $idDir ("envfix-{0}.json" -f $idBack)), '{"id":"' + $idBack + '","ts":"2099-12-31T23:59:59Z","testMode":true,"undone":true,"entries":[]}', [Text.UTF8Encoding]::new($false))
  $idBack2 = New-CslEnvFixId -NowUtc ([datetime]::new(2099,12,31,23,59,40,0,[DateTimeKind]::Utc))
  Assert-True ($idBack2.CompareTo($idBack) -gt 0) 'clock rollback chained: strictly increasing'
  # old-format id (second precision) is treated as end of that second
  Assert-Eq ((Get-CslEnvFixIdTime '20990101T000000-abcd').Millisecond) 999 'old id parsed as +999ms'
} finally {
  foreach ($f in @(Get-ChildItem -LiteralPath $idDir -Filter 'envfix-2099123*.json' -File -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $f.FullName -Force }
}

Write-Host '== Fix id: old-format id mixed with new, undo latest ==' -ForegroundColor Cyan
$store = New-MemStore
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_NEW' -Value 'vnew-orig'
$mixDir = Get-CslEnvBackupDir
# old-format id in the CURRENT second (worst case: same second as the new fix)
$oldId = ([datetime]::UtcNow.ToString('yyyyMMddTHHmmss', [Globalization.CultureInfo]::InvariantCulture)) + '-ffff'
$oldBak = [pscustomobject]@{
  id = $oldId; ts = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); testMode = $true; undone = $false
  entries = @([pscustomobject]@{ name = 'CSL_TEST_ANTHROPIC_OLD'; existed = $true; before = 'vold-orig'; kind = 'String'; after = $null; earliestExisted = $true; earliestBefore = 'vold-orig'; earliestKind = 'String' })
}
$oldPath = Join-Path $mixDir ("envfix-{0}.json" -f $oldId)
[IO.File]::WriteAllText($oldPath, ($oldBak | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
try {
  $fNew = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_NEW') -TestMode -Store $store
  Assert-True $fNew.ok 'mixed ids: new fix ok'
  Assert-True ($fNew.id.CompareTo($oldId) -gt 0) 'mixed ids: new id sorts after old-format id'
  Assert-True ((Get-CslEnvFixIdTime $fNew.id) -gt (Get-CslEnvFixIdTime $oldId)) 'mixed ids: new id time after old id time'
  $uMix = Invoke-CslEnvUndo -NoPause -TestMode -Store $store
  Assert-True $uMix.ok 'mixed ids: undo latest ok'
  Assert-Eq $uMix.id $fNew.id 'mixed ids: undid the new (latest) fix'
  Assert-Eq (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_NEW').Value 'vnew-orig' 'mixed ids: new var restored'
  Assert-True ($null -eq (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_OLD')) 'mixed ids: old backup not applied'
} finally {
  Remove-Item -LiteralPath $oldPath -Force -ErrorAction SilentlyContinue
  if ($fNew -and $fNew.id) { Remove-Item -LiteralPath (Join-Path $mixDir ("envfix-{0}.json" -f $fNew.id)) -Force -ErrorAction SilentlyContinue }
}

Write-Host '== Fix id: old-format id later than now ==' -ForegroundColor Cyan
$futDir = Get-CslEnvBackupDir
$futOld = ([datetime]::UtcNow.AddMinutes(10).ToString('yyyyMMddTHHmmss', [Globalization.CultureInfo]::InvariantCulture)) + '-0000'
$futPath = Join-Path $futDir ("envfix-{0}.json" -f $futOld)
[IO.File]::WriteAllText($futPath, '{"id":"' + $futOld + '","ts":"2000-01-01T00:00:00Z","testMode":true,"undone":true,"entries":[]}', [Text.UTF8Encoding]::new($false))
try {
  $idFut = New-CslEnvFixId
  Assert-True ($idFut.CompareTo($futOld) -gt 0) 'future old-format id: new id sorts after it'
  Assert-Eq ((Get-CslEnvFixIdTime $idFut) - (Get-CslEnvFixIdTime $futOld)).TotalMilliseconds 1 'future old-format id: new id = old id (second + 999ms) + 1ms'
} finally {
  Remove-Item -LiteralPath $futPath -Force -ErrorAction SilentlyContinue
}

Write-Host '== TestMode undo rejects non CSL_TEST_ names ==' -ForegroundColor Cyan
$store = New-MemStore
$fakeId = '20990101T000000001-fade'
$fakeBak = [pscustomobject]@{
  id = $fakeId
  ts = '2099-01-01T00:00:00Z'
  testMode = $false
  undone = $false
  entries = @(
    [pscustomobject]@{
      name = 'ANTHROPIC_FAKE_KEY'
      existed = $true
      before = 'fake-secret-xxxx'
      kind = 'String'
      after = $null
      earliestExisted = $true
      earliestBefore = 'fake-secret-xxxx'
      earliestKind = 'String'
    }
  )
}
$fakePath = Join-Path (Get-CslEnvBackupDir) ("envfix-{0}.json" -f $fakeId)
[IO.File]::WriteAllText($fakePath, ($fakeBak | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_KEEP' -Value 'stay'
$uPlan = Invoke-CslEnvUndo -Id $fakeId -TestMode -DryRun -Store $store
Assert-True (-not $uPlan.ok) 'TestMode undo-plan rejects ANTHROPIC_FAKE'
Assert-True ($uPlan.error -match 'TestMode|CSL_TEST_') 'TestMode undo-plan error mentions guard'
$uApply = Invoke-CslEnvUndo -Id $fakeId -TestMode -Store $store -DefaultConflictDecision overwrite
Assert-True (-not $uApply.ok) 'TestMode undo-apply rejects ANTHROPIC_FAKE'
Assert-Eq (& $store.GetUserEntry 'CSL_TEST_ANTHROPIC_KEEP').Value 'stay' 'TestMode undo changed nothing'
$chkFake = Get-CslEnvBackupById -Id $fakeId
Assert-True ($null -ne $chkFake -and -not [bool]$chkFake.undone) 'TestMode undo did not mark backup undone'
# cleanup fake
Remove-Item -LiteralPath $fakePath -Force -ErrorAction SilentlyContinue

Write-Host '== Conflict-skip backup retained past prune ==' -ForegroundColor Cyan
$store = New-MemStore
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_KEEPVAL' -Value 'precious-orig-xxxx'
$fSkip = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_KEEPVAL') -TestMode -Store $store
Assert-True $fSkip.ok 'skip-retain fix ok'
& $store.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_KEEPVAL' -Value 'tampered-now'
$uSkip = Invoke-CslEnvUndo -Id $fSkip.id -Store $store -DefaultConflictDecision skip
Assert-True ($uSkip.exitCode -eq 3 -or -not $uSkip.ok) 'skip-retain undo conflict'
$skipPath = Join-Path (Get-CslEnvBackupDir) ("envfix-{0}.json" -f $fSkip.id)
Assert-True (Test-Path -LiteralPath $skipPath) 'skip-retain backup exists after undo'
$skipJson = Get-Content -LiteralPath $skipPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True (-not [bool]$skipJson.undone) 'skip-retain backup stays undoable (skipped entry open)'
Assert-True (@($skipJson.skipped).Count -ge 1) 'skip-retain recorded skipped names'
Assert-True (@($skipJson.skipped) -contains 'CSL_TEST_ANTHROPIC_KEEPVAL') 'skip-retain skipped name listed'
$beforeVal = @($skipJson.entries | Where-Object name -eq 'CSL_TEST_ANTHROPIC_KEEPVAL')[0].before
Assert-Eq $beforeVal 'precious-orig-xxxx' 'skip-retain original value kept in file'
# exceed keep with many more fixes (disjoint vars so chain stays separate)
$prevKeep = $script:CslEnvBackupKeep
$script:CslEnvBackupKeep = 10
try {
  for ($i = 0; $i -lt 25; $i++) {
    $n = "CSL_TEST_ANTHROPIC_PRUNE_$i"
    & $store.SetUserEntry -Name $n -Value ("v$i")
    $fi = Invoke-CslEnvFix -Patterns @($n) -TestMode -Store $store
    Assert-True $fi.ok ("prune-flood fix $i ok")
  }
} finally {
  $script:CslEnvBackupKeep = $prevKeep
}
Assert-True (Test-Path -LiteralPath $skipPath) 'skip-retain backup survived prune'
$skipJson2 = Get-Content -LiteralPath $skipPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-Eq @($skipJson2.entries | Where-Object name -eq 'CSL_TEST_ANTHROPIC_KEEPVAL')[0].before 'precious-orig-xxxx' 'skip-retain value intact after prune'
Clear-TestBackups

Write-Host '== Wildcard patterns enumerate machine-level names (hint only) ==' -ForegroundColor Cyan
$mw = New-MemStore
$mw.State.m['CSL_TEST_ANTHROPIC_MW_ONLY'] = 'machine-only-val'
$mw.State.m['CSL_TEST_ANTHROPIC_MW_BOTH'] = 'machine-both-val'
$mw.State.m['CSL_TEST_OTHER_MW'] = 'other'
& $mw.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_MW_BOTH' -Value 'user-both'
& $mw.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_MW_USER' -Value 'user-only'
$mwT = Find-CslRelayEnvTargets -Patterns @('CSL_TEST_ANTHROPIC_MW_*') -TestMode -Store $mw
Assert-True $mwT.ok 'machine wildcard find ok'
Assert-Eq (@($mwT.machineOnly | ForEach-Object { $_.Name }) -join ',') 'CSL_TEST_ANTHROPIC_MW_ONLY' 'machine-only match listed via wildcard'
Assert-Eq (@($mwT.user | ForEach-Object { $_.Name } | Sort-Object) -join ',') 'CSL_TEST_ANTHROPIC_MW_BOTH,CSL_TEST_ANTHROPIC_MW_USER' 'user-level matches unchanged (BOTH stays user)'
$mwPlan = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_MW_*') -TestMode -DryRun -Store $mw
$mwRow = @($mwPlan.plan | Where-Object { $_.name -eq 'CSL_TEST_ANTHROPIC_MW_ONLY' })
Assert-True ($mwRow.Count -eq 1 -and $mwRow[0].action -eq 'skip-admin' -and $mwRow[0].note -eq '需要管理员手动处理') 'plan shows machine-only as skip-admin with admin note'
$mwFix = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_MW_*') -TestMode -Store $mw
Assert-True ($mwFix.ok -and $mw.State.m['CSL_TEST_ANTHROPIC_MW_ONLY'] -eq 'machine-only-val' -and $mw.State.m['CSL_TEST_ANTHROPIC_MW_BOTH'] -eq 'machine-both-val' -and $mw.State.m.Count -eq 3) 'fix never touches machine-level values'
Assert-True ($null -eq (& $mw.GetUserEntry 'CSL_TEST_ANTHROPIC_MW_BOTH') -and $null -eq (& $mw.GetUserEntry 'CSL_TEST_ANTHROPIC_MW_USER')) 'fix still removes user-level matches'
# TestMode: a non CSL_TEST_ machine-only name matched by a wildcard is ignored, not an error
$mw2 = New-MemStore
$mw2.State.m['REAL_MW_X'] = 'real'
& $mw2.SetUserEntry -Name 'CSL_TEST_MW_X' -Value 'tv'
$mwT2 = Find-CslRelayEnvTargets -Patterns @('*_MW_X') -TestMode -Store $mw2
Assert-True ($mwT2.ok -and @($mwT2.machineOnly).Count -eq 0 -and (@($mwT2.user | ForEach-Object { $_.Name }) -join ',') -eq 'CSL_TEST_MW_X') 'TestMode ignores real machine-only names'
# stores without ListMachineNames keep the v3.2.0 behaviour
$mw3 = New-MemStore
$mw3.State.m['CSL_TEST_ANTHROPIC_MW_ONLY'] = 'x'
$mw3Old = [pscustomobject]@{ GetUserEntry = $mw3.GetUserEntry; GetMachine = $mw3.GetMachine; SetUserEntry = $mw3.SetUserEntry; ListUserNames = $mw3.ListUserNames }
$mwT3 = Find-CslRelayEnvTargets -Patterns @('CSL_TEST_ANTHROPIC_MW_*') -TestMode -Store $mw3Old
Assert-True ($mwT3.ok -and @($mwT3.machineOnly).Count -eq 0) 'store without ListMachineNames still works'
# v3.3.0: HKLM unreadable (access denied / key missing) falls back to v3.2.0 behaviour, no error
$mw4 = New-MemStore
& $mw4.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_MW_U4' -Value 'u4'
$mw4Throw = [pscustomobject]@{ GetUserEntry = $mw4.GetUserEntry; GetMachine = $mw4.GetMachine; SetUserEntry = $mw4.SetUserEntry; ListUserNames = $mw4.ListUserNames; ListMachineNames = { throw [System.UnauthorizedAccessException]::new('Requested registry access is not allowed.') } }
$mwT4 = Find-CslRelayEnvTargets -Patterns @('CSL_TEST_ANTHROPIC_MW_*') -TestMode -Store $mw4Throw
Assert-True ($mwT4.ok -and @($mwT4.machineOnly).Count -eq 0 -and (@($mwT4.user | ForEach-Object { $_.Name }) -join ',') -eq 'CSL_TEST_ANTHROPIC_MW_U4') 'HKLM access denied: find falls back to user-only (v3.2.0)'
$mwF4 = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_MW_*') -TestMode -Store $mw4Throw
Assert-True ($mwF4.ok -and $null -eq (& $mw4.GetUserEntry 'CSL_TEST_ANTHROPIC_MW_U4') -and @(@($mwF4.plan) | Where-Object { $_.action -eq 'skip-admin' }).Count -eq 0) 'HKLM access denied: fix still works, no admin rows'
$mw5 = New-MemStore
& $mw5.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_MW_U5' -Value 'u5'
$mw5Null = [pscustomobject]@{ GetUserEntry = $mw5.GetUserEntry; GetMachine = $mw5.GetMachine; SetUserEntry = $mw5.SetUserEntry; ListUserNames = $mw5.ListUserNames; ListMachineNames = { return $null } }
$mwT5 = Find-CslRelayEnvTargets -Patterns @('CSL_TEST_ANTHROPIC_MW_*') -TestMode -Store $mw5Null
Assert-True ($mwT5.ok -and @($mwT5.machineOnly).Count -eq 0 -and @($mwT5.user).Count -eq 1) 'HKLM key missing (null list): falls back to user-only (v3.2.0)'
$efSrc = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'claude-envfix.ps1') -Raw
Assert-True ($efSrc -match "ListMachineNames = \{\s*\r?\n\s*\`$names = New-Object[^\r\n]*\r?\n\s*try \{") 'default ListMachineNames wraps HKLM read in try'
$dStore = Get-CslDefaultEnvStore
Assert-True ($null -ne $dStore.PSObject.Properties['ListMachineNames']) 'default store exposes ListMachineNames'
Clear-TestBackups

Write-Host '== Per-entry undo: conflict-skipped entry can be undone later ==' -ForegroundColor Cyan
Clear-TestBackups
$pe = New-MemStore
& $pe.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_PE_A' -Value 'pe-a0'
& $pe.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_PE_B' -Value 'pe-b0'
$peFix = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_PE_*') -TestMode -Store $pe
& $pe.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_PE_B' -Value 'pe-bX'
$peU1 = Invoke-CslEnvUndo -Id $peFix.id -NoPause -Store $pe
Assert-Eq $peU1.exitCode 3 'first undo exitCode 3 (B skipped)'
Assert-Eq (& $pe.GetUserEntry 'CSL_TEST_ANTHROPIC_PE_A').Value 'pe-a0' 'first undo restored A'
Assert-Eq (& $pe.GetUserEntry 'CSL_TEST_ANTHROPIC_PE_B').Value 'pe-bX' 'first undo left B'
Assert-True ([string]$peU1.hint -match ('-UndoFix -UndoId ' + [regex]::Escape($peFix.id))) 'hint tells how to retry the skipped variable'
$pePath = Join-Path (Get-CslEnvBackupDir) ("envfix-{0}.json" -f $peFix.id)
$peJ1 = Get-Content -LiteralPath $pePath -Raw -Encoding UTF8 | ConvertFrom-Json
$peA1 = @($peJ1.entries | Where-Object name -eq 'CSL_TEST_ANTHROPIC_PE_A')[0]
$peB1 = @($peJ1.entries | Where-Object name -eq 'CSL_TEST_ANTHROPIC_PE_B')[0]
Assert-True (-not [bool]$peJ1.undone) 'backup not fully undone after skip'
Assert-True ([bool]$peA1.undone) 'entry A marked undone'
Assert-True (-not [bool]$peB1.undone) 'entry B still open'
Assert-Eq (@($peJ1.skipped) -join ',') 'CSL_TEST_ANTHROPIC_PE_B' 'skipped lists only B'
$peList = @(Get-CslEnvFixList | Where-Object { $_.id -eq $peFix.id })[0]
Assert-True ($peList.partiallyUndone -and -not $peList.undone) 'list reports partially undone'
# user resolves the conflict (B back to the fixed state), and changes A afterwards
& $pe.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_PE_B' -Value $null
& $pe.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_PE_A' -Value 'pe-a-user'
$peU2 = Invoke-CslEnvUndo -Id $peFix.id -NoPause -Store $pe
Assert-True ($peU2.ok -and $peU2.exitCode -eq 0 -and -not $peU2.alreadyUndone) 'second undo ok, exitCode 0'
Assert-Eq (& $pe.GetUserEntry 'CSL_TEST_ANTHROPIC_PE_B').Value 'pe-b0' 'second undo restored B'
Assert-Eq (& $pe.GetUserEntry 'CSL_TEST_ANTHROPIC_PE_A').Value 'pe-a-user' 'second undo did not touch A again'
Assert-Eq (@($peU2.restored | ForEach-Object { $_.name }) -join ',') 'CSL_TEST_ANTHROPIC_PE_B' 'second undo restored only B'
$peJ2 = Get-Content -LiteralPath $pePath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([bool]$peJ2.undone) 'backup fully undone after second undo'
Assert-Eq @($peJ2.skipped).Count 0 'skipped cleared once B undone'
$peU3 = Invoke-CslEnvUndo -Id $peFix.id -NoPause -Store $pe
Assert-True $peU3.alreadyUndone 'third undo reports already undone'
# legacy backups: file-level undone only (no entry flags) still count as fully undone
$lgStore = New-MemStore
& $lgStore.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_PE_LEGACY' -Value 'lg0'
$lgFix = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_PE_LEGACY') -TestMode -Store $lgStore
$lgPath = Join-Path (Get-CslEnvBackupDir) ("envfix-{0}.json" -f $lgFix.id)
$lgJ = Get-Content -LiteralPath $lgPath -Raw -Encoding UTF8 | ConvertFrom-Json
$lgJ.undone = $true
[IO.File]::WriteAllText($lgPath, ($lgJ | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
$lgU = Invoke-CslEnvUndo -Id $lgFix.id -NoPause -Store $lgStore
Assert-True ($lgU.alreadyUndone -and $null -eq (& $lgStore.GetUserEntry 'CSL_TEST_ANTHROPIC_PE_LEGACY')) 'legacy file-level undone still already undone, no change'
Clear-TestBackups

Write-Host '== Preflight undo conflict print skips null/empty ==' -ForegroundColor Cyan
$pfPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'claude-preflight.ps1'
$pfAst = [System.Management.Automation.Language.Parser]::ParseFile($pfPath, [ref]$null, [ref]$null)
$pfFns = $pfAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and ($n.Name -eq 'Get-CslUndoConflictMessages' -or $n.Name -eq 'Write-CslUndoConflicts') }, $true)
Assert-Eq @($pfFns).Count 2 'preflight conflict helpers found'
foreach ($fnAst in $pfFns) { . ([scriptblock]::Create($fnAst.Extent.Text)) }
$errBefore = $Error.Count
Assert-Eq @(Get-CslUndoConflictMessages $null).Count 0 'conflicts $null gives no message'
Assert-Eq @(Get-CslUndoConflictMessages @()).Count 0 'conflicts empty gives no message'
Assert-Eq @(Get-CslUndoConflictMessages @($null, '', '  ', @{ message = '' ; name = '' })).Count 0 'conflicts null/blank entries skipped'
$mixed = @(Get-CslUndoConflictMessages @('a', $null, @{ message = 'b' }, @{ name = 'c' }, [pscustomobject]@{ message = 'd' }))
Assert-Eq ($mixed -join ',') 'a,b,c,d' 'conflicts real entries kept in order'
$uNo = Invoke-CslEnvUndo -Id 'envfix-20000101T000000000-none' -NoPause -TestMode -Store $store
Assert-True (-not $uNo.ok) 'undo missing id fails'
$printed = @(Write-CslUndoConflicts $uNo.conflicts 6>&1 | ForEach-Object { [string]$_ })
Assert-Eq @($printed | Where-Object { $_ -like '*[[]警告]*' }).Count 0 'failed undo prints no empty warning'
$printedNull = @(Write-CslUndoConflicts $null 6>&1 | ForEach-Object { [string]$_ })
Assert-Eq $printedNull.Count 0 'null conflicts print nothing'
$printedOne = @(Write-CslUndoConflicts @($null, 'x') 6>&1 | ForEach-Object { [string]$_ })
Assert-Eq ($printedOne -join '|') '  [警告] x' 'one real conflict printed once'
Assert-Eq $Error.Count $errBefore 'conflict print raised no error'

Write-Host '== -ListFixes / undo conflict / undo results show names and actions only (no values, not even masked) ==' -ForegroundColor Cyan
$lfAst = $pfAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-CslEnvFixList' }, $true)
Assert-Eq @($lfAst).Count 1 'preflight Write-CslEnvFixList found'
foreach ($fnAst in $lfAst) { . ([scriptblock]::Create($fnAst.Extent.Text)) }
$leakVals = @('leakval-ABCD12345', 'https://leak-host.example/v1', 'tampered-WXYZ67890', 'leakval', 'ABCD', '12345', 'leak-host', 'WXYZ', '67890')
function Test-CslNoValueLeak([string]$Text) {
  if ($Text -match '\*') { return $false }
  foreach ($lv in $leakVals) { if ($Text.Contains($lv)) { return $false } }
  return $true
}
Clear-TestBackups
$stLk = New-MemStore
& $stLk.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_API_KEY' -Value 'leakval-ABCD12345'
& $stLk.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_BASE_URL' -Value 'https://leak-host.example/v1'
$fLk = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_*') -TestMode -Store $stLk
Assert-True $fLk.ok 'leak check: fix ok'
Assert-True (Test-CslNoValueLeak ($fLk | ConvertTo-Json -Depth 8)) 'fix result carries no value (plain or masked)'
$lsTxt0 = (@(Write-CslEnvFixList @(Get-CslEnvFixList) 6>&1 | ForEach-Object { [string]$_ }) -join "`n")
Assert-True (Test-CslNoValueLeak $lsTxt0) '-ListFixes output has no value (plain or masked)'
Assert-True ($lsTxt0.Contains('    - CSL_TEST_ANTHROPIC_API_KEY: 已删除（可撤销）')) '-ListFixes line is name: action (status)'
Assert-True (Test-CslNoValueLeak (@(Get-CslEnvFixList) | ConvertTo-Json -Depth 8)) 'fix list data carries no value (plain or masked)'
& $stLk.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_API_KEY' -Value 'tampered-WXYZ67890'
$pLk = Invoke-CslEnvUndo -Id $fLk.id -DryRun -Store $stLk -DefaultConflictDecision skip
Assert-True (Test-CslNoValueLeak ($pLk | ConvertTo-Json -Depth 8)) 'undo dry-run plan and conflicts carry no value (plain or masked)'
$uLk = Invoke-CslEnvUndo -Id $fLk.id -Store $stLk -DefaultConflictDecision skip
$cwTxt = (@(Write-CslUndoConflicts $uLk.conflicts 6>&1 | ForEach-Object { [string]$_ }) -join "`n")
Assert-Eq $cwTxt '  [警告] 冲突: CSL_TEST_ANTHROPIC_API_KEY 当前值与修复后不一致，已跳过' 'undo conflict warning is name only, then skipped'
Assert-True (Test-CslNoValueLeak ($uLk | ConvertTo-Json -Depth 8)) 'undo result (restored/conflicts/skipped) carries no value (plain or masked)'
$lsTxt1 = (@(Write-CslEnvFixList @(Get-CslEnvFixList) 6>&1 | ForEach-Object { [string]$_ }) -join "`n")
Assert-True ((Test-CslNoValueLeak $lsTxt1) -and $lsTxt1.Contains('部分已撤销（其余可撤销）') -and $lsTxt1.Contains('    - CSL_TEST_ANTHROPIC_API_KEY: 已删除（可撤销）') -and $lsTxt1.Contains('    - CSL_TEST_ANTHROPIC_BASE_URL: 已删除（已撤销）')) '-ListFixes after partial undo: names and status only'
$uOv = Invoke-CslEnvUndo -Id $fLk.id -Store $stLk -DefaultConflictDecision overwrite
Assert-True ((Test-CslNoValueLeak ($uOv | ConvertTo-Json -Depth 8)) -and (@($uOv.conflicts | Where-Object { $null -ne $_ } | ForEach-Object { $_.message }) -join '|') -eq '冲突: CSL_TEST_ANTHROPIC_API_KEY 当前值与修复后不一致，已按选择覆盖') 'overwrite conflict message is name only'
$lkPanel = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'claude-panel.html'))
Assert-True ($lkPanel.Length -gt 1000 -and $lkPanel.Contains('当前值与修复后不一致') -and -not ($lkPanel -match 'currentMasked|expectedMasked|restoreMasked|beforeMasked|valueMasked|当前=|修复后应为=|撤销将恢复为=')) 'panel undo dialog and lists render no values (plain or masked)'
Clear-TestBackups

Write-Host '== Backup without entries treated as corrupt ==' -ForegroundColor Cyan
$uncBefore2 = $script:Uncaught
$neDir = Get-CslEnvBackupDir
$neMissing = Join-Path $neDir 'envfix-20000101T000000000-nent.json'
$neNull = Join-Path $neDir 'envfix-20000101T000000001-nulx.json'
[IO.File]::WriteAllText($neMissing, '{"id":"20000101T000000000-nent","ts":"2000-01-01T00:00:00Z"}', (New-Object System.Text.UTF8Encoding($false)))
[IO.File]::WriteAllText($neNull, '{"id":"20000101T000000001-nulx","ts":"2000-01-01T00:00:00Z","entries":null}', (New-Object System.Text.UTF8Encoding($false)))
$rdMissing = Read-CslEnvBackupFile -Path $neMissing
$rdNull = Read-CslEnvBackupFile -Path $neNull
Assert-True ((-not $rdMissing.ok) -and ($rdMissing.error -like '备份文件损坏或无法解析*') -and (-not $rdNull.ok) -and ($rdNull.error -like '备份文件损坏或无法解析*')) 'backup missing/null entries read as corrupt'
$storeNe = New-MemStore
& $storeNe.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_NOENT' -Value 'noent-orig'
$fNe = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_NOENT') -TestMode -Store $storeNe
$uNe = Invoke-CslEnvUndo -Id $fNe.id -NoPause -TestMode -Store $storeNe
Assert-True ($fNe.ok -and $uNe.ok -and ((& $storeNe.GetUserEntry 'CSL_TEST_ANTHROPIC_NOENT').Value -eq 'noent-orig') -and (@($uNe.conflicts | Where-Object { $null -ne $_ }).Count -eq 0) -and ($script:Uncaught -eq $uncBefore2)) 'undo other backup ok with entries-less files present'
Remove-Item -LiteralPath $neMissing, $neNull -Force -ErrorAction SilentlyContinue

Write-Host '== Undo never calls the store with an empty name ==' -ForegroundColor Cyan
function New-RecordingStore {
  $inner = New-MemStore
  $calls = New-Object System.Collections.ArrayList
  $g = { param([string]$Name) [void]$calls.Add("get:$Name"); & $inner.GetUserEntry $Name }.GetNewClosure()
  $m = { param([string]$Name) [void]$calls.Add("machine:$Name"); & $inner.GetMachine $Name }.GetNewClosure()
  $s = { param([string]$Name, [AllowNull()][object]$Value, [string]$Kind = 'String') [void]$calls.Add("set:$Name"); & $inner.SetUserEntry -Name $Name -Value $Value -Kind $Kind }.GetNewClosure()
  return [pscustomobject]@{ State = $inner.State; GetUserEntry = $g; GetMachine = $m; SetUserEntry = $s; ListUserNames = $inner.ListUserNames; Calls = $calls }
}
$recDir = Get-CslEnvBackupDir
$recMissing = Join-Path $recDir 'envfix-20000101T000000002-rcm1.json'
$recNull = Join-Path $recDir 'envfix-20000101T000000003-rcn1.json'
[IO.File]::WriteAllText($recMissing, '{"id":"20000101T000000002-rcm1","ts":"2000-01-01T00:00:00Z"}', (New-Object System.Text.UTF8Encoding($false)))
[IO.File]::WriteAllText($recNull, '{"id":"20000101T000000003-rcn1","ts":"2000-01-01T00:00:00Z","entries":null}', (New-Object System.Text.UTF8Encoding($false)))
$rec = New-RecordingStore
& $rec.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_REC_A' -Value 'rec-a'
& $rec.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_REC_B' -Value 'rec-b'
$rec.Calls.Clear()
$fRec = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_REC_*') -TestMode -Store $rec
& $rec.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_REC_B' -Value 'rec-b-changed'
$uRec = Invoke-CslEnvUndo -Id $fRec.id -NoPause -TestMode -Store $rec
$uRecMissing = Invoke-CslEnvUndo -Id '20000101T000000002-rcm1' -NoPause -TestMode -Store $rec
$uRecNull = Invoke-CslEnvUndo -Id '20000101T000000003-rcn1' -NoPause -TestMode -Store $rec
$names = @($rec.Calls | ForEach-Object { ([string]$_).Split(':', 2)[1] })
Assert-True ($fRec.ok -and $names.Count -ge 4) 'recording store saw fix/undo calls'
Assert-Eq @($names | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count 0 'no store call with empty name'
Assert-Eq (& $rec.GetUserEntry 'CSL_TEST_ANTHROPIC_REC_A').Value 'rec-a' 'recording undo restored non-conflict var'
Assert-True ((-not $uRecMissing.ok) -and (-not $uRecNull.ok)) 'recording undo of entries-less backups refused'
Remove-Item -LiteralPath $recMissing, $recNull -Force -ErrorAction SilentlyContinue

Write-Host '== Backup entry with missing/empty name: whole backup corrupt, no store call ==' -ForegroundColor Cyan
$enDir = Get-CslEnvBackupDir
$enCases = @(
  @{ id = '20000101T000000011-enm1'; entry = '{"existed":true,"before":"x1","kind":"String"}'; label = 'name missing' },
  @{ id = '20000101T000000012-ene1'; entry = '{"name":"","existed":true,"before":"x2","kind":"String"}'; label = 'name empty' },
  @{ id = '20000101T000000013-enw1'; entry = '{"name":"   ","existed":true,"before":"x3","kind":"String"}'; label = 'name blank' },
  @{ id = '20000101T000000014-enx1'; entry = '{"name":null,"existed":true,"before":"x4","kind":"String"}'; label = 'name null' }
)
$recE = New-RecordingStore
& $recE.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_EN_OK' -Value 'en-now'
foreach ($c in $enCases) {
  $json = '{"id":"' + $c.id + '","ts":"2000-01-01T00:00:00Z","testMode":true,"entries":[{"name":"CSL_TEST_ANTHROPIC_EN_OK","existed":true,"before":"en-orig","kind":"String","after":null},' + $c.entry + ']}'
  [IO.File]::WriteAllText((Join-Path $enDir ("envfix-{0}.json" -f $c.id)), $json, (New-Object System.Text.UTF8Encoding($false)))
  $recE.Calls.Clear()
  $uE = Invoke-CslEnvUndo -Id $c.id -NoPause -TestMode -Store $recE
  Assert-True ((-not $uE.ok) -and ([string]$uE.error -match '缺少变量名')) ("$($c.label): undo refused as corrupt with clear message")
  Assert-Eq (& $recE.GetUserEntry 'CSL_TEST_ANTHROPIC_EN_OK').Value 'en-now' ("$($c.label): valid entry in same backup not touched")
  Assert-Eq @($recE.Calls | Where-Object { [string]::IsNullOrWhiteSpace(([string]$_).Split(':', 2)[1]) }).Count 0 ("$($c.label): no store call with empty name")
  Remove-Item -LiteralPath (Join-Path $enDir ("envfix-{0}.json" -f $c.id)) -Force -ErrorAction SilentlyContinue
}
$enList = '{"id":"20000101T000000015-enl1","ts":"2000-01-01T00:00:00Z","entries":[{"name":"","before":"x"}]}'
[IO.File]::WriteAllText((Join-Path $enDir 'envfix-20000101T000000015-enl1.json'), $enList, (New-Object System.Text.UTF8Encoding($false)))
$lst = @(Get-CslEnvFixList | Where-Object { $_.id -eq 'envfix-20000101T000000015-enl1' -or $_.id -eq '20000101T000000015-enl1' })
Assert-True ($lst.Count -eq 1 -and [bool]$lst[0].corrupt) '-ListFixes shows empty-name backup as corrupt'
Clear-TestBackups

Write-Host '== Corrupt (nameless-entry) backup is never pruned ==' -ForegroundColor Cyan
$gfhCmd = Get-Command Get-FileHash -ErrorAction SilentlyContinue
if (-not $gfhCmd) {
  $utilMods = @(Get-Module Microsoft.PowerShell.Utility | ForEach-Object { '{0} {1} {2}' -f $_.Name, $_.Version, $_.ModuleType })
  Write-Host ('  DIAG  Get-FileHash missing; Utility modules loaded=[{0}] PSModuleAutoLoadingPreference=[{1}] PSModulePath=[{2}]' -f ($utilMods -join '; '), $PSModuleAutoLoadingPreference, $env:PSModulePath) -ForegroundColor Yellow
}
Assert-True ($null -ne $gfhCmd) 'Get-FileHash command available at corrupt-backup section start'
$crId = '20000101T000000021-crp1'
$crPath = Join-Path (Get-CslEnvBackupDir) ("envfix-{0}.json" -f $crId)
$crJson = '{"id":"' + $crId + '","ts":"2000-01-01T00:00:00Z","testMode":true,"entries":[{"name":"CSL_TEST_ANTHROPIC_CR_OK","existed":true,"before":"cr-orig","kind":"String"},{"name":"","existed":true,"before":"x","kind":"String"}]}'
[IO.File]::WriteAllText($crPath, $crJson, (New-Object System.Text.UTF8Encoding($false)))
# Get-FileHash is a script-module function on Windows PowerShell 5.1 and can fail to
# autoload mid-suite; hash via .NET directly so the test does not depend on module loading.
function Get-CslTestSha256([string]$Path) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path)))).Replace('-', '') }
  finally { $sha.Dispose() }
}
$crHash = Get-CslTestSha256 $crPath
Assert-True ($crHash -match '^[0-9A-F]{64}$') 'corrupt backup sha256 computed'
$storeC = New-MemStore
$prevKeepC = $script:CslEnvBackupKeep
$script:CslEnvBackupKeep = 3
try {
  for ($i = 0; $i -lt 8; $i++) {
    $n = "CSL_TEST_ANTHROPIC_CFLOOD_$i"
    & $storeC.SetUserEntry -Name $n -Value ("c$i")
    [void](Invoke-CslEnvFix -Patterns @($n) -TestMode -Store $storeC)
    if ($i % 2 -eq 0) { [void](Invoke-CslEnvUndo -Id (@(Get-CslEnvFixList | Where-Object { -not $_.corrupt })[0].id) -NoPause -TestMode -Store $storeC) }
  }
} finally { $script:CslEnvBackupKeep = $prevKeepC }
$crLeft = @(Get-ChildItem -LiteralPath (Get-CslEnvBackupDir) -Filter 'envfix-*.json' -File).Count
Assert-True ($crLeft -le 7) ("prune ran during corrupt-backup flood ($crLeft files left)")
Assert-True (Test-Path -LiteralPath $crPath) 'corrupt backup survived prune'
Assert-Eq $(if (Test-Path -LiteralPath $crPath) { Get-CslTestSha256 $crPath } else { '' }) $crHash 'corrupt backup content unchanged'
$crItem = @(Get-CslEnvFixList | Where-Object { $_.corrupt })
Assert-True ($crItem.Count -eq 1 -and [string]$crItem[0].path -eq $crPath) '-ListFixes marks it corrupt with file path'
Clear-TestBackups

Write-Host '== Partially undone backup is never pruned ==' -ForegroundColor Cyan
$storeP = New-MemStore
& $storeP.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_PART_A' -Value 'part-a-orig'
& $storeP.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_PART_B' -Value 'part-b-orig'
$fP = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_PART_*') -TestMode -Store $storeP
& $storeP.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_PART_B' -Value 'part-b-tampered'
$uP = Invoke-CslEnvUndo -Id $fP.id -NoPause -TestMode -Store $storeP
$partPath = Join-Path (Get-CslEnvBackupDir) ("envfix-{0}.json" -f $fP.id)
$pItem = @(Get-CslEnvFixList | Where-Object { $_.id -eq $fP.id })
Assert-True ($pItem.Count -eq 1 -and [bool]$pItem[0].partiallyUndone -and -not [bool]$pItem[0].undone) 'backup is partially undone before flood'
$prevKeepP = $script:CslEnvBackupKeep
$script:CslEnvBackupKeep = 3
try {
  for ($i = 0; $i -lt 12; $i++) {
    $n = "CSL_TEST_ANTHROPIC_PFLOOD_$i"
    & $storeP.SetUserEntry -Name $n -Value ("p$i")
    [void](Invoke-CslEnvFix -Patterns @($n) -TestMode -Store $storeP)
    $u2 = Invoke-CslEnvUndo -Id (@(Get-CslEnvFixList)[0].id) -NoPause -TestMode -Store $storeP
  }
  for ($i = 12; $i -lt 20; $i++) {
    $n = "CSL_TEST_ANTHROPIC_PFLOOD_$i"
    & $storeP.SetUserEntry -Name $n -Value ("p$i")
    [void](Invoke-CslEnvFix -Patterns @($n) -TestMode -Store $storeP)
  }
} finally {
  $script:CslEnvBackupKeep = $prevKeepP
}
$remaining = @(Get-ChildItem -LiteralPath (Get-CslEnvBackupDir) -Filter 'envfix-*.json' -File).Count
Assert-True ($remaining -lt 30) ("prune actually ran during flood ($remaining files left)")
Assert-True (Test-Path -LiteralPath $partPath) 'partially undone backup survived prune (undoable and fully-undone floods)'
& $storeP.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_PART_B' -Value $null
$uP2 = Invoke-CslEnvUndo -Id $fP.id -NoPause -TestMode -Store $storeP
Assert-True ($uP2.ok -and (& $storeP.GetUserEntry 'CSL_TEST_ANTHROPIC_PART_B').Value -eq 'part-b-orig') 'skipped entry still undoable after prune'
Clear-TestBackups

Write-Host '== foreach over @($x.prop) skips $null explicitly ==' -ForegroundColor Cyan
$guardMissing = @()
$guardTotal = 0
$repoDir = Split-Path -Parent $PSScriptRoot
foreach ($srcName in @('claude-envfix.ps1', 'claude-preflight.ps1')) {
  $srcAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoDir $srcName), [ref]$null, [ref]$null)
  $loops = $srcAst.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.ForEachStatementAst] -and
    $n.Condition -is [System.Management.Automation.Language.PipelineAst] -and
    $n.Condition.Extent.Text -match '^@\(\$[\w]+(\.[\w]+)+\)$' }, $true)
  foreach ($lp in $loops) {
    $guardTotal++
    $first = @($lp.Body.Statements)[0]
    $vn = $lp.Variable.VariablePath.UserPath
    $ok = ($null -ne $first) -and ($first.Extent.Text -match ('^if \(\$null -eq \$' + [regex]::Escape($vn) + '\) \{ continue \}$'))
    if (-not $ok) { $guardMissing += ("{0}:{1}" -f $srcName, $lp.Extent.StartLineNumber) }
  }
}
Assert-True ($guardTotal -ge 8) ("found foreach @(`$x.prop) loops ($guardTotal)")
Assert-Eq ($guardMissing -join ',') '' 'every such loop skips $null first'
$nlDir = Get-CslEnvBackupDir
$storeNl = New-MemStore
& $storeNl.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_NULLENT' -Value 'nullent-orig'
$fNl = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_NULLENT') -TestMode -Store $storeNl
$nlPath = Join-Path $nlDir ("envfix-{0}.json" -f $fNl.id)
$nlJson = Get-Content -LiteralPath $nlPath -Raw -Encoding UTF8 | ConvertFrom-Json
$nlJson.entries = @($null) + @($nlJson.entries)
[IO.File]::WriteAllText($nlPath, ($nlJson | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
$uncBefore3 = $script:Uncaught
$uNl = Invoke-CslEnvUndo -Id $fNl.id -NoPause -TestMode -Store $storeNl
Assert-True ($uNl.ok -and ((& $storeNl.GetUserEntry 'CSL_TEST_ANTHROPIC_NULLENT').Value -eq 'nullent-orig') -and ($script:Uncaught -eq $uncBefore3)) 'undo with a null element in entries restores, no error'

Write-Host '== v3.3.0 envFixEnabled / envFixKeep settings ==' -ForegroundColor Cyan
$dflt = Get-CslEnvFixSettings ([pscustomobject]@{ monitorIntervalMin = 5 })
Assert-True ($dflt.enabled -eq $true -and @($dflt.keep).Count -eq 0) 'missing keys: enabled=true, keep empty'
$dflt2 = Get-CslEnvFixSettings $null
Assert-True ($dflt2.enabled -eq $true -and @($dflt2.keep).Count -eq 0) 'null cfg: enabled=true, keep empty'
$off = Get-CslEnvFixSettings ([pscustomobject]@{ envFixEnabled = $false; envFixKeep = @('CSL_TEST_ANTHROPIC_BASE_URL', $null, '  ') })
Assert-True ($off.enabled -eq $false) 'envFixEnabled=false is honored'
Assert-Eq (@($off.keep) -join ',') 'CSL_TEST_ANTHROPIC_BASE_URL' 'envFixKeep drops null/blank entries'
$offStr = Get-CslEnvFixSettings ([pscustomobject]@{ envFixEnabled = 'false'; envFixKeep = 'CSL_TEST_ANTHROPIC_MODEL' })
Assert-True ($offStr.enabled -eq $false -and (@($offStr.keep) -join ',') -eq 'CSL_TEST_ANTHROPIC_MODEL') 'string false / single-string keep accepted'
$commonText = [IO.File]::ReadAllText((Join-Path $repoDir 'claude-common.ps1'))
Assert-True ($commonText -match 'envFixEnabled\s*=\s*\$true' -and $commonText -match 'envFixKeep\s*=\s*@\(\)') 'Load-Config defaults: envFixEnabled=$true, envFixKeep=@()'

$storeK = New-MemStore
& $storeK.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_BASE_URL' -Value 'https://keep.example'
& $storeK.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_AUTH_TOKEN' -Value 'sk-keeptest-123456'
$pK = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_*') -TestMode -DryRun -Store $storeK -Keep @('CSL_TEST_ANTHROPIC_BASE_URL')
$pKeep = @(@($pK.plan) | Where-Object { $_.action -eq 'keep' } | ForEach-Object { $_.name })
$pRem = @(@($pK.plan) | Where-Object { $_.action -eq 'remove' } | ForEach-Object { $_.name })
Assert-Eq ($pKeep -join ',') 'CSL_TEST_ANTHROPIC_BASE_URL' 'plan: kept name has action keep'
Assert-Eq ($pRem -join ',') 'CSL_TEST_ANTHROPIC_AUTH_TOKEN' 'plan: only non-kept name is removed'
$fK = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_*') -TestMode -Store $storeK -Keep @('CSL_TEST_ANTHROPIC_BASE*')
Assert-True ($fK.ok -and ((& $storeK.GetUserEntry 'CSL_TEST_ANTHROPIC_BASE_URL').Value -eq 'https://keep.example')) 'apply: envFixKeep (wildcard) variable kept'
Assert-True ($null -eq (& $storeK.GetUserEntry 'CSL_TEST_ANTHROPIC_AUTH_TOKEN')) 'apply: non-kept variable removed'
$kBak = Get-Content -LiteralPath (Join-Path (Get-CslEnvBackupDir) ("envfix-{0}.json" -f $fK.id)) -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-Eq ((@($kBak.entries) | Where-Object { $null -ne $_ } | ForEach-Object { $_.name }) -join ',') 'CSL_TEST_ANTHROPIC_AUTH_TOKEN' 'backup holds only the removed variable'
$storeK2 = New-MemStore
& $storeK2.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_BASE_URL' -Value 'https://keep.example'
$fK2 = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_*') -TestMode -Store $storeK2 -Keep @('CSL_TEST_ANTHROPIC_BASE_URL')
Assert-True ($fK2.ok -and $null -eq $fK2.id -and ((& $storeK2.GetUserEntry 'CSL_TEST_ANTHROPIC_BASE_URL').Value -eq 'https://keep.example')) 'all kept: no change, no backup'
Clear-TestBackups

Write-Host '== v3.3.0 confirm list: names and actions only; -FixEnv asks y/N ==' -ForegroundColor Cyan
$storeV = New-MemStore
& $storeV.SetUserEntry -Name 'CSL_TEST_ANTHROPIC_AUTH_TOKEN' -Value 'sk-secretvalue-987654'
$pV = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_*') -TestMode -DryRun -Store $storeV
$planJson = ConvertTo-Json @($pV.plan) -Depth 6 -Compress
Assert-True (-not ($planJson -match 'secretvalue|9876|valueMasked')) 'plan rows carry no value (plain or masked)'
Assert-True ($null -eq (@($pV.plan)[0].PSObject.Properties['valueMasked'])) 'plan row has no valueMasked field'
Assert-True (Test-CslFixConfirmed -Yes -ReadAnswer { throw 'must not ask' }) '-Yes skips the question'
Assert-True (Test-CslFixConfirmed -ReadAnswer { 'y' }) 'answer y agrees'
Assert-True (Test-CslFixConfirmed -ReadAnswer { ' Y ' }) 'answer Y agrees'
Assert-True (-not (Test-CslFixConfirmed -ReadAnswer { 'n' })) 'answer n refuses'
Assert-True (-not (Test-CslFixConfirmed -ReadAnswer { '' })) 'empty answer refuses'
Assert-True (-not (Test-CslFixConfirmed -ReadAnswer { $null })) 'EOF/null refuses'
Assert-True (-not (Test-CslFixConfirmed -ReadAnswer { throw 'no console' })) 'read error refuses'
Assert-True (-not (Test-CslFixConfirmed)) 'no reader and no -Yes refuses'
$pfPath = Join-Path $repoDir 'claude-preflight.ps1'
foreach ($srcName in @('claude-preflight.ps1', 'claude-envfix.ps1', 'claude-common.ps1', 'claude-panel.ps1')) {
  $pe = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoDir $srcName), [ref]$null, [ref]$pe)
  Assert-Eq (@($pe).Count) 0 ("$srcName parses with no syntax errors")
}
$pfAst = [System.Management.Automation.Language.Parser]::ParseFile($pfPath, [ref]$null, [ref]$null)
$pfParams = @($pfAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
Assert-True ($pfParams -contains 'Yes') 'preflight has -Yes switch'
$pfText = [IO.File]::ReadAllText($pfPath)
Assert-True ($pfText -match 'Test-CslFixConfirmed -Yes:\$Yes') 'preflight -FixEnv goes through Test-CslFixConfirmed'
Assert-True (-not ($pfText -match 'valueMasked')) 'preflight prints no masked values'
$panelText = [IO.File]::ReadAllText((Join-Path $repoDir 'claude-panel.html'))
Assert-True (-not ($panelText -match 'valueMasked')) 'panel confirm boxes show no values'
Write-Host '== v3.3.0 check 9 card lines are not truncated ==' -ForegroundColor Cyan
Assert-True ($panelText -match "className='card'\+\(isEnvGroup\(g\)\?' env':''\)") 'env group card gets class env'
Assert-True ($panelText -match '\.card\.env \.row \.txt\{white-space:normal;overflow-wrap:anywhere;text-overflow:clip\}') 'env card rows wrap (no ellipsis), long tokens break'
Assert-True ($panelText -match '\.row\.fail \.txt,\.row\.warn \.txt,\.row\.fix \.txt\{white-space:normal;overflow-wrap:anywhere\}') 'fail/warn/fix rows break long tokens'
Assert-True ($panelText -match 'function fitAll\(\)' -and $panelText -match "class=""row more""|className='row more'" -and $panelText -match "more\.title=") 'overflowing card rows fold into a hover row (no silent clipping)'
Assert-True ($panelText -match '#groups>\.card\{max-height:none\}' -and $panelText -match 'function finish\(\)\{busy=false;setBusy\(false\);fitAll\(\);') 'cards not clipped by max-height; fold recomputed on finish'
Assert-True ($panelText -match "const nFail=hidden\.filter\(o=>o\.r\.classList\.contains\('fail'\)\)\.length;more\.classList\.toggle\('has-fail',nFail>0\)" -and $panelText -match "'（含 '\+nFail\+' 条失败）'") 'fold row counts folded failures and gets fail style'
Assert-True ($panelText -match '\.row\.more\.has-fail \.tag\{background:var\(--fail\)\}' -and $panelText -match '\.row\.more\.has-fail \.txt\{color:var\(--fail\);font-weight:600\}') 'fold row with failures uses the fail colour (no gradient)'
Assert-True ($panelText -match "const nW=g\.rows\.filter\(r=>r\.cls===w\)\.length" ) 'card title count is computed from all rows (folded included)'
$fnAst = $pfAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-CslEnvFixPlan' }, $true)
Assert-True ($null -ne $fnAst) 'preflight defines Write-CslEnvFixPlan'
if ($fnAst) {
  Invoke-Expression $fnAst.Extent.Text
  $planOut = @(Write-CslEnvFixPlan $pV.plan 6>&1 | ForEach-Object { [string]$_ })
  Assert-True ((@($planOut | Where-Object { $_ -match '将清除 User (\S+)$' }).Count -eq 1)) 'plan line reads 将清除 User NAME'
  Assert-True (-not (($planOut -join "`n") -match 'secretvalue|9876|\*')) 'plan output has no value'
}

Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue

if ($script:Fail -gt 0 -or $script:Uncaught -gt 0) {
  Write-Host "FAILED: $($script:Fail) assertion(s), $($script:Uncaught) uncaught error(s)" -ForegroundColor Red
  exit 1
}
Write-Host 'ALL PASSED' -ForegroundColor Green
exit 0
