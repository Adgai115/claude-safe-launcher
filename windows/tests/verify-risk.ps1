#Requires -Version 5.1
param([string]$ArtifactRoot)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if(-not $ArtifactRoot){$ArtifactRoot=Join-Path ([IO.Path]::GetTempPath()) ('claude-risk-qa-'+[guid]::NewGuid().ToString('n'))}
New-Item -ItemType Directory -Path $ArtifactRoot -Force|Out-Null
. (Join-Path $root 'claude-common.ps1')
. (Join-Path $root 'claude-diagnostics.ps1')
. (Join-Path $root 'claude-risk.ps1')
$ErrorActionPreference='Stop'
$script:Count=0
function Assert([bool]$Condition,[string]$Name){if(-not $Condition){throw "FAIL: $Name"};$script:Count++;Write-Host "PASS: $Name"}
$now=[datetime]::UtcNow
$snapshot=Get-Content -LiteralPath (Join-Path $root 'data\supported-regions.json') -Raw|ConvertFrom-Json
Assert (Test-CslRegionSnapshot $snapshot $now) 'bundled official snapshot has valid provenance and structure'
$policy=@{status='available';countries=@($snapshot.countries)}
Assert ((Get-CslRegionAssessment $policy 'US').status -eq 'observed') 'supported exit country is recognized'
Assert ((Get-CslRegionAssessment $policy 'CN').blocksLaunch) 'unsupported exit country blocks automatic launch'
Assert ((Get-CslRegionAssessment $policy '').status -eq 'unknown') 'missing country is not treated as supported'
Assert ((Get-CslRegionAssessment @{status='unknown'} 'US').blocksLaunch) 'unavailable policy data blocks automatic launch without claiming a region violation'
$snapshot.source='https://example.invalid'
Assert (-not(Test-CslRegionSnapshot $snapshot $now)) 'non-official policy provenance is rejected'
$snapshot.source=$script:CslRegionSource;$snapshot.fetchedAtUtc=$now.AddHours(1).ToString('o')
Assert (-not(Test-CslRegionSnapshot $snapshot $now)) 'future-dated cache is rejected'
$snapshot.fetchedAtUtc=$now.AddDays(-8).ToString('o')
$cacheDir=Join-Path $ArtifactRoot 'cache';New-Item -ItemType Directory -Path $cacheDir|Out-Null
[IO.File]::WriteAllText((Join-Path $cacheDir 'supported-regions.json'),($snapshot|ConvertTo-Json -Depth 4))
Assert ((Get-CslRegionSnapshot -DataDirectory $cacheDir -Offline -NowUtc $now).status -eq 'unknown') 'expired policy cache is not considered current'
$snapshot.fetchedAtUtc=$now.AddDays(-2).ToString('o')
[IO.File]::WriteAllText((Join-Path $cacheDir 'supported-regions.json'),($snapshot|ConvertTo-Json -Depth 4))
Assert ((Get-CslRegionSnapshot -DataDirectory $cacheDir -Offline -NowUtc $now).status -eq 'available') 'recent policy cache supports an offline check'
$names=@{};$list=@()
for($i=0;$i -lt 110;$i++){$code=$snapshot.countries[$i];$name='Country'+$i;$names[(ConvertTo-CslCountryNameKey $name)]=$code;$list+="<li><p>$name</p></li>"}
$html='<p>You can access Claude in the following locations:</p><ul>'+($list-join '')+'</ul><ul><li>Navigation</li></ul>'
$parsed=ConvertFrom-CslRegionsHtml -Html $html -NameMap $names -NowUtc $now
Assert ($parsed.countries.Count -eq 110) 'HTML extraction ignores unrelated navigation lists'
$rejected=$false;try{ConvertFrom-CslRegionsHtml -Html '<html>Challenge</html>' -NameMap $names|Out-Null}catch{$rejected=$true}
Assert $rejected 'challenge pages do not overwrite the official cache'
$rejected=$false;try{ConvertFrom-CslRegionsHtml -Html ($html.Replace('Country0','UnmappedCountry')) -NameMap $names|Out-Null}catch{$rejected=$true}
Assert $rejected 'unmapped policy entries cause a failed update rather than an incomplete allowlist'

$process=[pscustomobject]@{ProcessId=42;ExecutablePath='C:\Fixture\Claude\Claude.exe';CreationDate=$now.AddHours(-1)}
function New-Connection([string]$Id,[string[]]$Chains,[string]$HostName='api.anthropic.com',[int]$OwnerId=42,[string]$OwnerPath='C:\Fixture\Claude\Claude.exe'){
 return [pscustomobject]@{id=$Id;start=$now.ToString('o');chains=$Chains;metadata=[pscustomobject]@{processId=$OwnerId;processPath=$OwnerPath;process='Claude.exe';host=$HostName;destinationIP='203.0.113.10'}}
}
$good=New-Connection 'owned-good' @('fixture-node','Claude')
Assert (Test-CslServiceHost 'bridge.claudeusercontent.com') 'official desktop bridge host is covered'
Assert (Test-CslServiceHost 'sso.claude.com') 'official desktop authentication host is covered'
Assert (-not(Test-CslServiceHost 'claudeusercontent.com.example.invalid')) 'a lookalike content domain is excluded'
$direct=New-Connection 'owned-direct' @('DIRECT')
$wrong=New-Connection 'owned-wrong' @('other-node','Claude')
Assert ((Get-CslClaudeRouteAssessment @($good) @($process) 'fixture-node').status -eq 'observed') 'owned service connection using the standard node is recognized'
$dialer=New-Connection 'proxy-with-dialer' @('DIRECT','fixture-node','Claude')
Assert ((Get-CslClaudeRouteAssessment @($dialer) @($process) 'fixture-node').status -eq 'observed') 'a direct transport hop does not invalidate an observed standard proxy node'
Assert ((Get-CslClaudeRouteAssessment @($direct) @($process) 'fixture-node').status -eq 'risk') 'owned DIRECT service connection is flagged'
Assert ((Get-CslClaudeRouteAssessment @($wrong) @($process) 'fixture-node').bad[0].reason -eq 'node_mismatch') 'owned service connection through another node is flagged'
Assert ((Get-CslClaudeRouteAssessment @($direct) @() 'fixture-node').status -eq 'unknown') 'client not running is not a successful route check'
Assert ((Get-CslClaudeRouteAssessment @($good) @($process) 'fixture-node' $false).status -eq 'unknown') 'missing controller data is explicitly unverified'
$unrelated=New-Connection 'other-app' @('DIRECT') 'api.anthropic.com' 99 'C:\Other\app.exe'
Assert ((Get-CslClaudeRouteAssessment @($unrelated) @($process) 'fixture-node').bad.Count -eq 0) 'another application connection is never attributed to Claude'
$otherPid=New-Connection 'other-pid' @('DIRECT') 'api.anthropic.com' 99
Assert ((Get-CslClaudeRouteAssessment @($otherPid) @($process) 'fixture-node').bad.Count -eq 0) 'path similarity does not override a conflicting process ID'
$external=New-Connection 'mcp-service' @('DIRECT') 'example.invalid'
Assert ((Get-CslClaudeRouteAssessment @($external) @($process) 'fixture-node').bad.Count -eq 0) 'third-party integrations are outside the official-service route rule'
$lookalike=New-Connection 'lookalike' @('DIRECT') 'api.anthropic.com.example.invalid'
Assert ((Get-CslClaudeRouteAssessment @($lookalike) @($process) 'fixture-node').bad.Count -eq 0) 'lookalike domains are not mistaken for official hosts'
$noChain=New-Connection 'no-chain' @()
Assert ((Get-CslClaudeRouteAssessment @($noChain) @($process) 'fixture-node').status -eq 'unknown') 'missing proxy-chain evidence is not treated as safe'
$reused=New-Connection 'old-pid' @('DIRECT');$reused.start=$now.AddDays(-1).ToString('o')
Assert ((Get-CslClaudeRouteAssessment @($reused) @($process) 'fixture-node').bad.Count -eq 0) 'connections older than the current process are excluded'
$initial=Get-CslClaudeRouteAssessment @($direct) @($process) 'fixture-node'
$verified=Get-CslClaudeRouteAssessment @($good) @($process) 'fixture-node'
$tcp=New-Connection 'tcp-fallback' @('fixture-node','Claude')
$tcp.metadata.processId=$null;$tcp.metadata.processPath='';$tcp.metadata.process=''
$tcp.metadata|Add-Member -NotePropertyMembers @{network='tcp';sourceIP='192.0.2.2';sourcePort=54321;destinationPort=443}
$socket=[pscustomobject]@{LocalAddress='192.0.2.2';LocalPort=54321;RemotePort=443;OwningProcess=42}
$matched=Get-CslClaudeRouteAssessment @($tcp) @($process) 'fixture-node' $true @($socket)
Assert ($matched.status -eq 'observed' -and $matched.tcpAttributed -eq 1) 'Windows TCP ownership fills in missing controller process metadata'
$socket.LocalAddress='192.0.2.3'
Assert ((Get-CslClaudeRouteAssessment @($tcp) @($process) 'fixture-node' $true @($socket)).observed -eq 0) 'a matching source port with a different source address is excluded'
$socket.LocalAddress='192.0.2.2';$socket.OwningProcess=99
Assert ((Get-CslClaudeRouteAssessment @($tcp) @($process) 'fixture-node' $true @($socket)).observed -eq 0) 'another Windows process is excluded from TCP fallback'
$socket.OwningProcess=42;$socket.RemotePort=80
Assert ((Get-CslClaudeRouteAssessment @($tcp) @($process) 'fixture-node' $true @($socket)).observed -eq 0) 'a conflicting destination port is excluded'
$socket.RemotePort=443;$tcp.metadata.network='udp'
Assert ((Get-CslClaudeRouteAssessment @($tcp) @($process) 'fixture-node' $true @($socket)).observed -eq 0) 'TCP fallback does not attribute UDP traffic'
$tcp.metadata.network='tcp';$tcp.metadata.processId=99
Assert ((Get-CslClaudeRouteAssessment @($tcp) @($process) 'fixture-node' $true @($socket)).observed -eq 0) 'TCP fallback never overrides a conflicting controller PID'
$tcp.metadata.processId=$null;$tcp.metadata.processPath='C:\Other\app.exe'
Assert ((Get-CslClaudeRouteAssessment @($tcp) @($process) 'fixture-node' $true @($socket)).observed -eq 0) 'TCP fallback never overrides a conflicting controller executable path'
$script:RouteCalls=0;$script:Deletes=New-Object 'System.Collections.Generic.List[string]'
function Ctl-SelectNode{throw 'Client observations must not mutate proxy groups'}
function Get-CslLiveClaudeRoutes{param($Cfg)$script:RouteCalls++;if($script:RouteCalls -eq 1){return $initial}else{return $verified}}
function Invoke-Ctl{param($Cfg,$Method,$Path,$Body)if($Method -eq 'DELETE'){[void]$script:Deletes.Add($Path)};return @{ok=$true}}
$cfg=[pscustomobject]@{claudeGroup='Claude';mainGroup='Main';pinMainGroup=$true;expectedNode='fixture-node'}
$repair=Repair-CslClaudeRoutes $cfg $initial
Assert (-not $repair.attempted -and $repair.closed -eq 0 -and $repair.assessment.status -eq 'risk') 'compatibility repair entry preserves a reported risk without touching the client'
Assert ($script:Deletes.Count -eq 0 -and $script:RouteCalls -eq 0) 'client observation never closes connections or selects proxy groups'
$script:RouteCalls=0;$script:Deletes.Clear()
function Get-CslLiveClaudeRoutes{param($Cfg)return $verified}
$repair=Repair-CslClaudeRoutes $cfg $initial
Assert ($repair.closed -eq 0) 'stale or no-longer-owned connections are not closed'
$script:RouteCalls=0;$script:Waits=0
$pending=@{status='unknown';message='awaiting a reconnect';bad=@();observed=0}
function Get-CslLiveClaudeRoutes{param($Cfg)$script:RouteCalls++;if($script:RouteCalls -eq 1){return $initial}else{return $pending}}
function Start-Sleep{param($Milliseconds,$Seconds)$script:Waits++}
$pendingRepair=Repair-CslClaudeRoutes $cfg $initial
Assert ($pendingRepair.closed -eq 0 -and -not $pendingRepair.attempted) 'compatibility repair cannot interrupt a client reconnect'
Assert ($script:RouteCalls -eq 0 -and $script:Waits -eq 0) 'read-only observation introduces no forced reconnect waits'

Assert ((Get-CslAccountSignal '[error] HTTP 403 permission_error') -eq 'permission_issue') '403 is classified as permission trouble, not an account ban'
Assert ((Get-CslAccountSignal '[error] HTTP 429 rate_limit_error') -eq 'rate_limit') '429 is classified as rate limiting, not an account ban'
Assert ((Get-CslAccountSignal '[error] authentication_error') -eq 'authentication_issue') 'authentication failure remains distinct from account restriction'
Assert ((Get-CslAccountSignal '[error] account_disabled') -eq 'account_restriction') 'an explicit account restriction signal is recognized'
Assert ((Get-CslAccountSignal '[error] unsupported_country') -eq 'region_restriction') 'an explicit regional error is recognized'
Assert ($null -eq (Get-CslAccountSignal 'User asked whether their account is suspended')) 'ordinary conversation text is not an account alert'
Assert ($null -eq (Get-CslAccountSignal '[error] HTTP 500 internal_server_error')) 'generic server failures do not imply an account restriction'
$logDir=Join-Path $ArtifactRoot 'logs';New-Item -ItemType Directory -Path $logDir|Out-Null
$logPath=Join-Path $logDir 'main.log'
$line='['+$now.ToString('o')+'] [error] account_disabled sensitive=synthetic-private-value person@example.invalid'
[IO.File]::WriteAllText($logPath,$line)
$evidence=Get-CslClientAccountEvidence -LogDirectories @($logDir) -NowUtc $now
Assert ($evidence.status -eq 'risk' -and $evidence.signals[0].kind -eq 'account_restriction') 'recent client error yields a reviewable alert category'
$serialized=$evidence|ConvertTo-Json -Depth 6
Assert (-not $serialized.Contains('synthetic-private-value') -and -not $serialized.Contains('person@example.invalid')) 'raw log messages and private values never enter the result'
$old='['+$now.AddDays(-1).ToString('o')+'] [error] account_disabled'
[IO.File]::WriteAllText($logPath,$old)
Assert ((Get-CslClientAccountEvidence -LogDirectories @($logDir) -NowUtc $now).status -eq 'unavailable') 'old alerts do not produce a current account verification task'
[IO.File]::WriteAllText($logPath,'['+$now.ToString('o')+'] [info] session active')
$clean=Get-CslClientAccountEvidence -LogDirectories @($logDir) -NowUtc $now
Assert ($clean.status -eq 'observed' -and $clean.code -eq 'no_recent_alerts' -and $clean.message -match '仅报告日志扫描结果') 'a successful log scan reports no recent alerts without claiming account health'
Assert ((Get-CslClientAccountEvidence -LogDirectories @((Join-Path $ArtifactRoot 'missing')) -NowUtc $now).status -eq 'unavailable') 'missing client logs are a neutral unavailable state'

$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'claude-monitor.ps1'),[ref]$tokens,[ref]$parseErrors)
$function=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-RuntimeRiskCheck'},$true)
. ([scriptblock]::Create($function.Extent.Text))
$script:Root=Join-Path $ArtifactRoot 'monitor';New-Item -ItemType Directory -Path $script:Root|Out-Null
$script:RuntimeAlertKey='';$script:RuntimeLastAlertUtc=[datetime]::MinValue;$script:Alerts=0
$cfg=[pscustomobject]@{monitorAutoRepair=$false;monitorAlertCooldownMin=30}
$script:MockRoute=@{status='unknown';observed=0;bad=@()}
$script:MockAccount=@{status='unknown';signals=@()}
function Get-CslLiveClaudeRoutes{param($Cfg)return $script:MockRoute}
function Get-CslClientAccountEvidence{return $script:MockAccount}
function Show-Alert{param($Title,$Text)$script:Alerts++}
function Write-Log{param($Line)}
Invoke-RuntimeRiskCheck
$runtime=Get-Content -LiteralPath (Join-Path $script:Root 'monitor-risk.json') -Raw|ConvertFrom-Json
Assert ($runtime.status -eq 'unknown' -and $runtime.unknown -eq 2 -and $script:Alerts -eq 0) 'unknown runtime evidence is recorded without repetitive alerts'
$script:MockRoute=$initial
Invoke-RuntimeRiskCheck
Invoke-RuntimeRiskCheck
Assert ($script:Alerts -eq 1) 'runtime risk notifications are merged during the cooldown'
$cfg.monitorAutoRepair=$true
function Repair-CslClaudeRoutes{throw 'Runtime scan must never repair client connections'}
Invoke-RuntimeRiskCheck
$runtime=Get-Content -LiteralPath (Join-Path $script:Root 'monitor-risk.json') -Raw|ConvertFrom-Json
Assert ($runtime.fixed -eq 0 -and $runtime.unknown -eq 1 -and $runtime.status -eq 'risk') 'runtime scan remains read-only even with standard auto repair enabled'
$script:MockRoute=$verified;$script:MockAccount=@{status='risk';signals=@([pscustomobject]@{kind='permission_issue'})}
Invoke-RuntimeRiskCheck
$runtime=Get-Content -LiteralPath (Join-Path $script:Root 'monitor-risk.json') -Raw|ConvertFrom-Json
Assert ($runtime.account.categories -contains 'permission_issue' -and $runtime.unknown -eq 0 -and $runtime.status -eq 'risk') 'runtime log warnings remain warnings without an invented account verification failure'
$script:MockAccount=@{status='unavailable';signals=@()}
Invoke-RuntimeRiskCheck
$runtime=Get-Content -LiteralPath (Join-Path $script:Root 'monitor-risk.json') -Raw|ConvertFrom-Json
Assert ($runtime.unknown -eq 0 -and $runtime.status -eq 'observed') 'missing logs do not turn a verified connection into an unverified account'
[pscustomobject]@{Passed=$script:Count;ArtifactRoot=$ArtifactRoot}|ConvertTo-Json
