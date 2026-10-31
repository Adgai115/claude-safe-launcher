#Requires -Version 5.1
param([string]$ArtifactRoot)
$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path -Parent $PSScriptRoot
if (-not $ArtifactRoot) { $ArtifactRoot = Join-Path ([IO.Path]::GetTempPath()) ('claude-launcher-qa-' + [guid]::NewGuid().ToString('n')) }
New-Item -ItemType Directory -Path $ArtifactRoot -Force | Out-Null
$script:Passed = 0
function Assert([bool]$Condition, [string]$Name) {
  if (-not $Condition) { throw "FAIL: $Name" }
  $script:Passed++; Write-Host "PASS: $Name"
}
. (Join-Path $sourceRoot 'claude-common.ps1')
. (Join-Path $sourceRoot 'claude-envfix.ps1')
. (Join-Path $sourceRoot 'claude-diagnostics.ps1')
$ErrorActionPreference = 'Stop'
$script:Root = Join-Path $ArtifactRoot 'backup-tests'
New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
Assert (Test-CslOfficialEndpoint '') 'unset endpoint is not a relay'
Assert (Test-CslOfficialEndpoint 'https://api.anthropic.com') 'official endpoint accepted'
Assert (-not (Test-CslOfficialEndpoint 'https://api.anthropic.com.example.invalid')) 'lookalike endpoint rejected'
Assert (-not (Test-CslOfficialEndpoint 'http://api.anthropic.com')) 'plaintext endpoint not classified as official'
Assert (-not (Test-CslOfficialEndpoint 'https://example.invalid')) 'custom endpoint classified separately'

$reportPath = Join-Path $ArtifactRoot 'report.json'
$stages = @(1..15 | ForEach-Object { "stage-$_" })
$events=@($stages | ForEach-Object { [pscustomobject]@{Group=$_;Level='PASS';Text='synthetic check'} })
Write-CslCheckReport -Path $reportPath -RunId 'run-1' -Complete $true -Result 'PASS' -Score 100 -ExitCode 0 -Stages $stages -Events $events
$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
Assert (Test-CslCompletedReport $report 'run-1' 0) 'complete result accepted'
Assert (-not (Test-CslCompletedReport $null 'run-1' 0)) 'missing result rejected'
Assert (-not (Test-CslCompletedReport $report 'wrong-run' 0)) 'stale result rejected'
Assert (-not (Test-CslCompletedReport $report 'run-1' 2)) 'abnormal process exit rejected'
$report.complete = $false
Assert (-not (Test-CslCompletedReport $report 'run-1' 0)) 'partial result rejected'

$now = [datetime]::UtcNow
Assert ((Get-CslMonitorAlertDecision 'changed' 'changed' $now $now 30) -eq 'quiet') 'duplicate monitor notification suppressed'
Assert ((Get-CslMonitorAlertDecision 'changed' 'changed' $now.AddMinutes(-31) $now 30) -eq 'notify') 'monitor cooldown expires'
Assert ((Get-CslMonitorAlertDecision '' 'changed' $now $now 30) -eq 'healthy') 'monitor recovery recognized'
$gate = Test-CslPanelApiRequest -Method POST -HostHeader 'localhost:47831' -Origin 'http://localhost:47831' -ContentType 'application/json' -TokenHeader 'unit-session' -ExpectedToken 'unit-session' -IsApiPath
Assert $gate.ok 'same-origin authenticated API request accepted'
$gate = Test-CslPanelApiRequest -Method POST -HostHeader 'localhost:47831' -ContentType 'application/json' -TokenHeader 'unit-session' -ExpectedToken 'unit-session' -IsApiPath
Assert (-not $gate.ok) 'API request with missing Origin rejected'
$gate = Test-CslPanelApiRequest -Method GET -HostHeader 'localhost:47831' -ExpectedToken 'unit-session' -IsApiPath
Assert (-not $gate.ok) 'API request with missing session marker rejected'
Assert (-not (Test-CslPanelHostAllowed -HostHeader 'example.invalid:47831' -Port 47831)) 'unexpected Host header rejected'

# Import the monitor's check function only; never execute its loop or real notifications.
$tokens=$null; $parseErrors=$null
$monitorAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot 'claude-monitor.ps1'),[ref]$tokens,[ref]$parseErrors)
$checkFunction=$monitorAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Check'},$true)
. ([scriptblock]::Create($checkFunction.Extent.Text))
$cfg=[pscustomobject]@{monitorRetryCount=3;monitorAutoRepair=$false;monitorAlertCooldownMin=30;monitorKillOnChange=$false}
$script:AlertKey='';$script:LastAlertUtc=[datetime]::MinValue;$script:NotificationCount=0;$script:ProbeIndex=0
$healthy=@{problems=@();codes=@();ctlOk=$true}
$unhealthy=@{problems=@('synthetic mismatch');codes=@('trace:changed');ctlOk=$true}
$script:ProbeStates=@($unhealthy,$unhealthy,$healthy)
function Test-State { $state=$script:ProbeStates[[Math]::Min($script:ProbeIndex,$script:ProbeStates.Count-1)];$script:ProbeIndex++;return $state }
function Show-Alert { param($Title,$Text) $script:NotificationCount++ }
function Write-Log { param($Line) }
function Start-Sleep { param($Seconds,$Milliseconds) }
function Ctl-SelectNode { throw 'Monitor unexpectedly mutated a proxy group' }
$Once=$false;$DryRun=$false
Invoke-Check
Assert ($script:ProbeIndex -eq 3 -and $script:NotificationCount -eq 0) 'transient monitor failures recover before notification'
$script:ProbeStates=@($unhealthy);$script:ProbeIndex=0
Invoke-Check
Assert ($script:ProbeIndex -eq 3 -and $script:NotificationCount -eq 1) 'persistent monitor failure notifies after retries'
Invoke-Check
Assert ($script:NotificationCount -eq 1) 'monitor loop merges repeated notifications'
$script:ProbeStates=@($healthy)
Invoke-Check
Assert ($script:NotificationCount -eq 2 -and -not $script:AlertKey) 'monitor recovery notifies once and clears failure state'
Invoke-Check
Assert ($script:NotificationCount -eq 2) 'healthy monitor loop remains quiet'
$cfg=[pscustomobject]@{monitorRetryCount=3;monitorAutoRepair=$true;monitorAlertCooldownMin=30;monitorKillOnChange=$false;expectedNode='fixture-node';claudeGroup='Claude';mainGroup='FixtureMain';pinMainGroup=$true;timezone='Eastern Standard Time'}
$needsRepair=@{problems=@('synthetic standard mismatch');codes=@('trace:changed','timezone:changed','tun:unavailable');ctlOk=$true}
$script:ProbeStates=@($needsRepair,$needsRepair,$needsRepair,$healthy);$script:ProbeIndex=0
$script:NodeRepairs=0;$script:TimezoneRepairs=0;$script:TunRepairs=0
function Ctl-SelectNode { param($Cfg,$Group,$Node) $script:NodeRepairs++;return $true }
function tzutil.exe { $script:TimezoneRepairs++ }
function Enable-CslTun { $script:TunRepairs++;return @{ok=$true;changed=$true} }
Invoke-Check
Assert ($script:NodeRepairs -eq 2 -and $script:TimezoneRepairs -eq 1 -and $script:TunRepairs -eq 1 -and $script:ProbeIndex -eq 4) 'monitor repairs the standard and then verifies recovery'

# Synthetic data only. Never read or mutate a real credential/environment variable.
$document = [pscustomobject]@{id='20990101T000000000-test';undone=$false;entries=@([pscustomobject]@{name='CSL_TEST_ANTHROPIC_AUTH_TOKEN';before='synthetic-backup-value';kind='ExpandString';after=$null;existed=$true})}
$backupFile = Write-CslEnvBackup $document
$envelope = Get-Content -LiteralPath $backupFile -Raw | ConvertFrom-Json
Assert ($envelope.format -eq 'CSL-DPAPI-1') 'new backup uses DPAPI envelope'
Assert (-not ([IO.File]::ReadAllText($backupFile).Contains('synthetic-backup-value'))) 'plaintext value absent from backup'
$decoded = Read-CslEnvBackupFile -Path $backupFile -Strict
Assert ($decoded.ok -and $decoded.data.entries[0].before -eq 'synthetic-backup-value' -and $decoded.data.entries[0].kind -eq 'ExpandString') 'backup round trip preserves value and registry type'
Assert ((Get-Acl -LiteralPath $backupFile).AreAccessRulesProtected) 'backup file ACL inheritance disabled'
Assert ((Get-Acl -LiteralPath (Split-Path -Parent $backupFile)).AreAccessRulesProtected) 'backup directory ACL inheritance disabled'
$legacyFile = Join-Path (Get-CslEnvBackupDir) 'envfix-20980101T000000000-test.json'
[IO.File]::WriteAllText($legacyFile, ($document | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
Assert ((Read-CslEnvBackupFile $legacyFile -Strict).ok) 'legacy backup remains readable'
$envelope.payload = 'invalid'
[IO.File]::WriteAllText($backupFile, ($envelope | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
Assert (-not (Read-CslEnvBackupFile $backupFile -Strict).ok) 'damaged ciphertext rejected'

$script:Root = Join-Path $ArtifactRoot 'undo-tests'
$storage = @{
  CSL_TEST_ANTHROPIC_AUTH_TOKEN = [pscustomobject]@{Value='synthetic-original';Kind='ExpandString'}
  CSL_TEST_ANTHROPIC_MODEL = [pscustomobject]@{Value='';Kind='String'}
}
$store = [pscustomobject]@{
  ListUserNames = { @($storage.Keys) }.GetNewClosure()
  ListMachineNames = { @() }
  GetUserEntry = { param($Name) if($storage.ContainsKey($Name)) { $storage[$Name] } else { $null } }.GetNewClosure()
  GetMachine = { param($Name) $null }
  SetUserEntry = { param($Name,$Value,$Kind) if($null -eq $Value){$storage.Remove($Name)}else{$storage[$Name]=[pscustomobject]@{Value=[string]$Value;Kind=$Kind}} }.GetNewClosure()
}
function Broadcast-CslEnvironmentChange {}
$preview = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_*') -TestMode -Store $store -DryRun
Assert ($preview.ok -and $storage.Count -eq 2 -and -not (Test-Path -LiteralPath (Get-CslEnvBackupDir))) 'variable preview writes neither environment nor backup'
$fixed = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_*') -TestMode -Store $store
Assert ($fixed.ok -and $storage.Count -eq 0) 'explicit cleanup applies only to the synthetic store'
$undo = Invoke-CslEnvUndo -Id $fixed.id -TestMode -Store $store -NoPause
Assert ($undo.ok -and $storage.Count -eq 2) 'encrypted backup supports full undo'
Assert ($storage.CSL_TEST_ANTHROPIC_AUTH_TOKEN.Value -eq 'synthetic-original' -and $storage.CSL_TEST_ANTHROPIC_AUTH_TOKEN.Kind -eq 'ExpandString') 'undo preserves original value and expansion type'
Assert ($storage.CSL_TEST_ANTHROPIC_MODEL.Value -ceq '') 'undo preserves an empty string value'
$updatedBackup = Join-Path (Get-CslEnvBackupDir) ("envfix-$($fixed.id).json")
Assert ((Get-Content -LiteralPath $updatedBackup -Raw | ConvertFrom-Json).format -eq 'CSL-DPAPI-1') 'marking undo never writes plaintext backup'
$again = Invoke-CslEnvUndo -Id $fixed.id -TestMode -Store $store -NoPause
Assert ($again.ok -and $again.alreadyUndone) 'repeating undo is idempotent'
$rollback = Invoke-CslEnvFix -Patterns @('CSL_TEST_ANTHROPIC_*') -TestMode -Store $store -FailAtIndex 2
Assert (-not $rollback.ok -and $rollback.rolledBack -and $storage.Count -eq 2) 'partial cleanup failure rolls back the synthetic store'

$fixture = Join-Path $ArtifactRoot 'fixture'
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
foreach ($file in @('claude-common.ps1','claude-diagnostics.ps1','claude-risk.ps1','claude-envfix.ps1','claude-issueexport.ps1','claude-preflight.ps1','claude-panel-observer.ps1','claude-panel.ps1','claude-panel.html')) {
  Copy-Item -LiteralPath (Join-Path $sourceRoot $file) -Destination (Join-Path $fixture $file)
}
$config = @{expectedIp='203.0.113.10';expectedLoc='US';expectedNode='fixture-node';timezone='Eastern Standard Time';claudeAumid='Fixture!Claude';claudeGroup='Claude';mainGroup='FixtureMain';pinMainGroup=$true;clashExe='fixture.exe';monitorIntervalMin=5;npmGlobalDir='';envFixEnabled=$true}
[IO.File]::WriteAllText((Join-Path $fixture 'preflight.json'), ($config | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
$riskMocks = @'
function Get-CslRegionSnapshot { return @{status='available';countries=@('US');ageDays=0} }
function Get-CslLiveClaudeRoutes { param($Cfg) return @{status='unknown';code='client_not_running';message='Synthetic client not running';observed=0;bad=@()} }
function Get-CslClientAccountEvidence { return @{status='unknown';code='account_unverified';message='Synthetic account status unverified';signals=@()} }
'@
[IO.File]::AppendAllText((Join-Path $fixture 'claude-risk.ps1'), "`r`n"+$riskMocks, [Text.UTF8Encoding]::new($false))
$commonMocks = @'
# Isolated QA fixture: all external/system operations are replaced in this temporary copy.
$env:USERPROFILE = Join-Path $PSScriptRoot 'fake-user'
$env:APPDATA = Join-Path $PSScriptRoot 'fake-appdata'
$env:LOCALAPPDATA = Join-Path $PSScriptRoot 'fake-localappdata'
function Read-VergeRuntime { return @{} }
function Find-NpmGlobalDir { return '' }
function Get-ProxyCore { return [pscustomobject]@{ ProcessName='fixture-mihomo'; Id=42 } }
function Get-TunAdapter { return [pscustomobject]@{ Name='FixtureTun'; Status='Up' } }
function Get-Process { return $null }
function Get-ClaudeProcesses { return $null }
function Get-TimeZone { return [pscustomobject]@{ Id='UTC' } }
function Get-ItemProperty { return [pscustomobject]@{ Start=4 } }
function Ctl-Get { return [pscustomobject]@{version='fixture'} }
function Ctl-GetGroup { return [pscustomobject]@{now='fixture-node'} }
function Ctl-SelectNode { throw 'Unexpected proxy mutation during read-only check' }
function Start-Process { throw 'Unexpected process launch during read-only check' }
function tzutil.exe { throw 'Unexpected timezone mutation during read-only check' }
function Get-Trace { return @{ip='203.0.113.10';loc='US';colo='TEST'} }
function Resolve-DnsName { return [pscustomobject]@{IPAddress='203.0.113.100'} }
function Invoke-Curl { return '{"ip":"198.51.100.10","country":"US","status":"ok","203.0.113.10":{"risk":99,"proxy":"yes","type":"VPN"}}' }
function curl.exe { $global:LASTEXITCODE=0; if ($args -contains '-6') { return '2001:db8::10' }; return '405' }
'@
[IO.File]::AppendAllText((Join-Path $fixture 'claude-common.ps1'), "`r`n"+$commonMocks, [Text.UTF8Encoding]::new($false))
$envMocks = @'
function Find-CslRelayEnvTargets {
 return @{ok=$true;user=@([pscustomobject]@{Name='ANTHROPIC_API_KEY';Value='synthetic-official-key';Kind='String'},[pscustomobject]@{Name='ANTHROPIC_MODEL';Value='synthetic-model';Kind='String'},[pscustomobject]@{Name='ANTHROPIC_BASE_URL';Value='https://api.anthropic.com';Kind='String'});machineOnly=@()}
}
'@
[IO.File]::AppendAllText((Join-Path $fixture 'claude-envfix.ps1'), "`r`n"+$envMocks, [Text.UTF8Encoding]::new($false))
$browser = @{ts=[datetime]::UtcNow.ToString('o');webrtc=@{srflx=@('198.51.100.20');host=@();ipv6=@()};timezone='America/New_York';language='zh-CN';webdriver=$false}
[IO.File]::WriteAllText((Join-Path $fixture 'browser-check.json'), ($browser | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
$beforeHash = (Get-FileHash -LiteralPath (Join-Path $fixture 'preflight.json')).Hash
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
foreach ($mode in @('quick','full')) {
  $output = & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fixture 'claude-preflight.ps1') -NoLaunch -NoPause -CheckMode $mode -ResultPath $reportPath -RunId "fixture-$mode" 2>&1
  $childExit = $LASTEXITCODE
  $output | Set-Content -LiteralPath (Join-Path $ArtifactRoot ("preflight-$mode.log")) -Encoding UTF8
  $result = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
  Assert ($childExit -eq 0) "$mode check exits successfully"
  Assert (Test-CslCompletedReport $result "fixture-$mode" $childExit) "$mode check completes all 15 stages"
  Assert (@($result.items | Where-Object Level -eq 'FAIL').Count -eq 0) "$mode IPv6, WebRTC, official variables and split routing do not block launch"
  Assert ($result.score -eq 92 -and $result.assessment.score -eq 92) "$mode known timezone drift deducts eight points in both report and assessment"
  Assert (@($result.events|Where-Object{$_.Weight -gt 0 -and $_.Group -ne '2. 系统时区'}).Count -eq 0) "$mode reference-only findings do not deduct score"
  Assert ((Get-FileHash -LiteralPath (Join-Path $fixture 'preflight.json')).Hash -eq $beforeHash) "$mode check preserves settings file bytes"
  Assert (-not (Test-Path -LiteralPath (Join-Path $fixture 'backups'))) "$mode check creates no variable backup"
}
$failingFixture = Join-Path $ArtifactRoot 'fixture-crash'
New-Item -ItemType Directory -Path $failingFixture -Force | Out-Null
Get-ChildItem -LiteralPath $fixture -File | Copy-Item -Destination $failingFixture
[IO.File]::AppendAllText((Join-Path $failingFixture 'claude-common.ps1'), "`r`nfunction Get-TimeZone { throw 'Synthetic early termination' }", [Text.UTF8Encoding]::new($false))
$output = & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $failingFixture 'claude-preflight.ps1') -NoLaunch -NoPause -ResultPath $reportPath -RunId 'fixture-crash' 2>&1
$childExit = $LASTEXITCODE
$result = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
Assert ($childExit -eq 2 -and -not $result.complete -and $null -eq $result.score) 'early termination produces an incomplete result with no score'
$originalConfig = [IO.File]::ReadAllText((Join-Path $fixture 'preflight.json'))
$output = & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $failingFixture 'claude-preflight.ps1') -NoLaunch -NoPause -Relearn -ResultPath $reportPath -RunId 'failed-relearn' 2>&1
Assert ($LASTEXITCODE -eq 2 -and (Get-FileHash -LiteralPath (Join-Path $failingFixture 'preflight.json')).Hash -eq $beforeHash) 'failed relearn leaves the original baseline unchanged'
$lateFixture=Join-Path $ArtifactRoot 'fixture-late-failure'
New-Item -ItemType Directory -Path $lateFixture -Force | Out-Null
Get-ChildItem -LiteralPath $fixture -File | Copy-Item -Destination $lateFixture
[IO.File]::AppendAllText((Join-Path $lateFixture 'claude-common.ps1'), "`r`nfunction Get-Trace { return @{} }", [Text.UTF8Encoding]::new($false))
$output = & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $lateFixture 'claude-preflight.ps1') -NoLaunch -NoPause -Relearn -ResultPath $reportPath -RunId 'late-failed-relearn' 2>&1
Assert ($LASTEXITCODE -eq 1 -and (Get-FileHash -LiteralPath (Join-Path $lateFixture 'preflight.json')).Hash -eq $beforeHash) 'a late check failure discards queued baseline changes'
$output = & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fixture 'claude-preflight.ps1') -NoLaunch -NoPause -Relearn -ResultPath $reportPath -RunId 'relearn' 2>&1
$recorded = Get-Content -LiteralPath (Join-Path $fixture 'preflight.json') -Raw | ConvertFrom-Json
Assert ($LASTEXITCODE -eq 0 -and $recorded.timezone -eq 'UTC' -and $recorded.expectedIp -eq '203.0.113.10') 'explicit relearn records current timezone and Claude domain egress'
[IO.File]::WriteAllText((Join-Path $fixture 'preflight.json'), $originalConfig, [Text.UTF8Encoding]::new($false))
$repairFixture=Join-Path $ArtifactRoot 'fixture-repair'
New-Item -ItemType Directory -Path $repairFixture -Force | Out-Null
Get-ChildItem -LiteralPath $fixture -File | Copy-Item -Destination $repairFixture
$repairMocks=@'
$script:FixtureTimezone='UTC'
$script:FixtureTun=$false
$script:FixtureNodes=@{Claude='wrong-node';FixtureMain='wrong-main'}
function Get-TimeZone { [pscustomobject]@{Id=$script:FixtureTimezone} }
function tzutil.exe { if($args[0] -eq '/s'){$script:FixtureTimezone=[string]$args[1]}elseif($args[0] -eq '/g'){$script:FixtureTimezone} }
function Get-TunAdapter { [pscustomobject]@{Name='FixtureTun';Status=$(if($script:FixtureTun){'Up'}else{'Down'})} }
function Ctl-Get { param($Cfg,$Path) if($Path -eq '/configs'){[pscustomobject]@{tun=[pscustomobject]@{enable=$script:FixtureTun}}}else{[pscustomobject]@{version='fixture'}} }
function Invoke-Ctl { param($Cfg,$Method,$Path,$Body) if($Method -eq 'PATCH' -and $Path -eq '/configs' -and $Body -eq '{"tun":{"enable":true}}'){$script:FixtureTun=$true;return @{ok=$true}};throw 'Unexpected controller mutation' }
function Ctl-GetGroup { param($Cfg,$Group) [pscustomobject]@{now=$script:FixtureNodes[$Group]} }
function Ctl-SelectNode { param($Cfg,$Group,$Node) $script:FixtureNodes[$Group]=$Node;return $true }
function Start-Sleep { param($Seconds,$Milliseconds) }
'@
[IO.File]::AppendAllText((Join-Path $repairFixture 'claude-common.ps1'),"`r`n"+$repairMocks,[Text.UTF8Encoding]::new($false))
$output=& $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repairFixture 'claude-preflight.ps1') -NoLaunch -NoPause -ApplySettings -ResultPath $reportPath -RunId 'repair' 2>&1
$repaired=Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
Assert ($LASTEXITCODE -eq 0 -and (Test-CslCompletedReport $repaired 'repair' 0)) 'standard repair completes and verifies all checks'
Assert (@($repaired.events | Where-Object Level -eq 'FIX').Count -eq 4) 'TUN, timezone and both configured strategy groups are repaired and verified'
Assert ($repaired.score -eq 100 -and @($repaired.items|Where-Object Level -eq 'FAIL').Count -eq 0) 'repaired standards pass without relaxing a blocking check'
Assert $repaired.repairMode 'repair mode is recorded separately from read-only checks'
Assert ((Get-FileHash -LiteralPath (Join-Path $repairFixture 'preflight.json')).Hash -eq $beforeHash) 'repair preserves the recorded standard instead of relearning the fault'
$refusedFixture=Join-Path $ArtifactRoot 'fixture-repair-refused'
New-Item -ItemType Directory -Path $refusedFixture -Force | Out-Null
Get-ChildItem -LiteralPath $repairFixture -File | Copy-Item -Destination $refusedFixture
$refused=@'
function tzutil.exe { if($args[0] -eq '/g'){$script:FixtureTimezone} }
function Ctl-SelectNode { return $false }
'@
[IO.File]::AppendAllText((Join-Path $refusedFixture 'claude-common.ps1'),"`r`n"+$refused,[Text.UTF8Encoding]::new($false))
$output=& $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $refusedFixture 'claude-preflight.ps1') -NoLaunch -NoPause -ApplySettings -ResultPath $reportPath -RunId 'refused-repair' 2>&1
$refusedReport=Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
Assert ($LASTEXITCODE -eq 1 -and $refusedReport.complete -and $refusedReport.result -eq 'FAIL') 'a refused repair remains a blocking failure'
Assert (@($refusedReport.events|Where-Object Level -eq 'FIX').Count -eq 1) 'failed attempts are not counted as successful repairs'
$unsupportedFixture=Join-Path $ArtifactRoot 'fixture-unsupported'
New-Item -ItemType Directory -Path $unsupportedFixture -Force|Out-Null
Get-ChildItem -LiteralPath $fixture -File|Copy-Item -Destination $unsupportedFixture
[IO.File]::AppendAllText((Join-Path $unsupportedFixture 'claude-risk.ps1'),"`r`nfunction Get-CslRegionSnapshot { return @{status='available';countries=@('GB');ageDays=0} }",[Text.UTF8Encoding]::new($false))
$output=& $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $unsupportedFixture 'claude-preflight.ps1') -NoPause -Force -ResultPath $reportPath -RunId 'unsupported' 2>&1
$blocked=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json
Assert ($LASTEXITCODE -eq 1 -and $blocked.complete -and $blocked.launch -eq 'no') 'unsupported-region assessment blocks launch even when legacy Force is supplied'
Assert ($blocked.launchBlocks -contains 'unsupported_region') 'unsupported-region evidence remains explicit in the result'
$unknownFixture=Join-Path $ArtifactRoot 'fixture-policy-unknown'
New-Item -ItemType Directory -Path $unknownFixture -Force|Out-Null
Get-ChildItem -LiteralPath $fixture -File|Copy-Item -Destination $unknownFixture
[IO.File]::AppendAllText((Join-Path $unknownFixture 'claude-risk.ps1'),"`r`nfunction Get-CslRegionSnapshot { return @{status='unknown';countries=@()} }",[Text.UTF8Encoding]::new($false))
$output=& $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $unknownFixture 'claude-preflight.ps1') -NoPause -Force -ResultPath $reportPath -RunId 'policy-unknown' 2>&1
$blocked=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json
Assert ($LASTEXITCODE -eq 3 -and $blocked.complete -and $blocked.result -eq 'WARN' -and $blocked.launch -eq 'no') 'unverified policy data has a distinct blocking outcome instead of a false violation or pass'
Assert (Test-CslCompletedReport $blocked 'policy-unknown' 3) 'a complete but blocked assessment is distinct from an interrupted check'
Assert ($blocked.riskSummary.unknown -ge 3) 'unknown policy, process route and account evidence remain visible'
[pscustomobject]@{Passed=$script:Passed;ArtifactRoot=$ArtifactRoot;Fixture=$fixture;CrashFixture=$failingFixture} | ConvertTo-Json
