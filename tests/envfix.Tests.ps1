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
  $state = @{ u = @{}; m = @{} }
  $getU = { param([string]$Name) if ($state.u.ContainsKey($Name)) { $state.u[$Name] } else { $null } }.GetNewClosure()
  $getM = { param([string]$Name) if ($state.m.ContainsKey($Name)) { $state.m[$Name] } else { $null } }.GetNewClosure()
  $setU = {
    param([string]$Name, [AllowNull()][string]$Value)
    if ($null -eq $Value -or $Value -eq '') { [void]$state.u.Remove($Name) } else { $state.u[$Name] = $Value }
  }.GetNewClosure()
  $listU = { @($state.u.Keys) }.GetNewClosure()
  return [pscustomobject]@{
    State = $state
    GetUser = $getU
    GetMachine = $getM
    SetUser = $setU
    ListUserNames = $listU
  }
}

# Isolate backups under temp
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
& $store.SetUser -Name 'ANTHROPIC_API_KEY' -Value 'sk-live-AAAABBBB'
$r = Invoke-CslEnvFix -Patterns @('ANTHROPIC_*') -TestMode -Store $store
Assert-True (-not $r.ok) 'TestMode refuses non CSL_TEST_ name'
$r2 = Invoke-CslEnvFix -Patterns @('CSL_TEST_*') -Store $store
Assert-True (-not $r2.ok) 'non-TestMode refuses CSL_TEST_ pattern'

Write-Host '== Fix + DryRun + earliest undo ==' -ForegroundColor Cyan
$store = New-MemStore
& $store.SetUser -Name 'CSL_TEST_ANTHROPIC_API_KEY' -Value 'sk-test-11112222'
& $store.SetUser -Name 'CSL_TEST_ANTHROPIC_BASE_URL' -Value 'https://relay.example/v1'
$plan = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_*') -TestMode -DryRun -Store $store
Assert-True $plan.ok 'dryrun ok'
Assert-Eq $plan.plan.Count 2 'dryrun two targets'
Assert-Eq (& $store.GetUser 'CSL_TEST_ANTHROPIC_API_KEY') 'sk-test-11112222' 'dryrun did not mutate'

$f1 = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_*') -TestMode -Store $store
Assert-True $f1.ok 'fix1 ok'
Assert-True ($null -eq (& $store.GetUser 'CSL_TEST_ANTHROPIC_API_KEY')) 'fix1 deleted key'
Assert-True ($null -ne $f1.id) 'fix1 has id'

# Second "fix": recreate then clear again — undo should restore earliest
& $store.SetUser -Name 'CSL_TEST_ANTHROPIC_API_KEY' -Value 'sk-test-SECOND'
$f2 = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_API_KEY') -TestMode -Store $store
Assert-True $f2.ok 'fix2 ok'

$u = Invoke-CslEnvUndo -Id $f2.id -NoPause -Store $store
Assert-True $u.ok 'undo ok'
Assert-Eq (& $store.GetUser 'CSL_TEST_ANTHROPIC_API_KEY') 'sk-test-11112222' 'undo restored earliest'
Assert-Eq (& $store.GetUser 'CSL_TEST_ANTHROPIC_BASE_URL') 'https://relay.example/v1' 'undo restored base url earliest'

Write-Host '== Machine-only skip ==' -ForegroundColor Cyan
$store = New-MemStore
$store.State.m['ANTHROPIC_MODEL'] = 'machine-only'
$r = Invoke-CslEnvFix -Patterns @('ANTHROPIC_MODEL') -DryRun -Store $store
Assert-True $r.ok 'machine plan ok'
Assert-Eq @($r.plan | Where-Object action -eq 'skip-admin').Count 1 'machine skip-admin'

Write-Host '== Conflict under NoPause ==' -ForegroundColor Cyan
$store = New-MemStore
& $store.SetUser -Name 'CSL_TEST_ANTHROPIC_API_KEY' -Value 'orig'
$f = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_API_KEY') -TestMode -Store $store
& $store.SetUser -Name 'CSL_TEST_ANTHROPIC_API_KEY' -Value 'tampered'
$u = Invoke-CslEnvUndo -Id $f.id -NoPause -Store $store
Assert-True ($u.exitCode -ne 0) 'conflict exit nonzero'
Assert-True ($u.conflicts.Count -ge 1) 'conflict reported'
Assert-Eq (& $store.GetUser 'CSL_TEST_ANTHROPIC_API_KEY') 'tampered' 'conflict skipped leave current'

# cleanup
Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue

if ($script:Fail -gt 0) {
  Write-Host "FAILED: $($script:Fail) assertion(s)" -ForegroundColor Red
  exit 1
}
Write-Host 'ALL PASSED' -ForegroundColor Green
exit 0
