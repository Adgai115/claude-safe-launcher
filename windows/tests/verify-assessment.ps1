#Requires -Version 5.1
param([string]$ArtifactRoot)
$ErrorActionPreference='Stop'
$sourceRoot=Split-Path -Parent $PSScriptRoot
if(-not $ArtifactRoot){$ArtifactRoot=Join-Path ([IO.Path]::GetTempPath()) ('claude-score-qa-'+[guid]::NewGuid().ToString('n'))}
New-Item -ItemType Directory -Path $ArtifactRoot -Force|Out-Null
. (Join-Path $sourceRoot 'claude-common.ps1')
. (Join-Path $sourceRoot 'claude-diagnostics.ps1')
. (Join-Path $sourceRoot 'claude-risk.ps1')
$ErrorActionPreference='Stop'
$script:Passed=0
function Assert($yes,$name){if(-not $yes){throw "FAIL: $name"};$script:Passed++;Write-Host "PASS: $name"}
$stages=@([regex]::Matches([IO.File]::ReadAllText((Join-Path $sourceRoot 'claude-preflight.ps1')),"(?m)^Say-Head '([^']+)'" )|ForEach-Object{$_.Groups[1].Value})
function Event($number,$level,$weight,$text){return [pscustomobject]@{Group=$stages[$number-1];Level=$level;Weight=$weight;Text=$text}}
$events=@(1..15|ForEach-Object{Event $_ 'PASS' 0 ('合成检查通过 '+$_)})
$events[1]=Event 2 'WARN' 8 '系统时区与标准不一致'
$events[2]=Event 3 'FAIL' 25 '节点与预设不一致'
foreach($number in @(5,7,10,15)){$events[$number-1]=Event $number 'INFO' 0 '参考项或无可用数据'}
$events[13]=Event 14 'UNKNOWN' 0 'Claude 尚未运行，连接待观测'
$events+=@(Event 1 'PASS' 0 '同组第二条通过信息不增加通过组数')
$assessment=Get-CslCheckAssessment $events
Assert ($assessment.score -eq 67) 'score equals actual timezone and node penalties'
Assert ($assessment.counts.pass -eq 8 -and $assessment.counts.reference -eq 4 -and $assessment.counts.unknown -eq 1) 'counts represent groups rather than log rows'
Assert ($assessment.checkedGroups -eq 15) 'all fifteen groups share the same coverage'
$path=Join-Path $ArtifactRoot 'weighted-report.json'
Write-CslCheckReport -Path $path -RunId 'score-run' -Complete $true -Result 'FAIL' -Score 67 -ExitCode 1 -Stages $stages -Events $events
$report=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
$report.timestamp=[datetime]::UtcNow.AddMinutes(-2).ToString('o')
Assert (Test-CslCompletedReport $report 'score-run' 1) 'weighted report is accepted when all numbers agree'
$report.score=100
Assert (-not(Test-CslCompletedReport $report 'score-run' 1)) 'a score inconsistent with its evidence is rejected'
$report.score=67
[IO.File]::WriteAllText($path,($report|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
$progress1=@{schemaVersion=2;runId='score-run';complete=$false;sequence=1;stages=@($stages[0..1]);events=@($events[0],$events[1],$events[15]);assessmentVersion=1}
$progress1.assessment=Get-CslCheckAssessment $progress1.events
$progress2=@{schemaVersion=2;runId='score-run';complete=$false;sequence=2;stages=@($stages[0..2]);events=@($events[0..2]);assessmentVersion=1}
$progress2.assessment=Get-CslCheckAssessment $progress2.events
[IO.File]::WriteAllText((Join-Path $ArtifactRoot 'progress.json'),(@($progress1,$progress2)|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
# Live core checks are isolated from the real network and Windows configuration.
$script:Zone='UTC';$script:Tun='Up';$script:Node='fixture-node';$script:Exit='203.0.113.10'
function Get-TimeZone{return [pscustomobject]@{Id=$script:Zone}}
function Get-ProxyCore{return [pscustomobject]@{ProcessName='fixture-mihomo'}}
function Get-TunAdapter{return [pscustomobject]@{Status=$script:Tun}}
function Ctl-Get{param($Cfg,$Path)return @{proxies=@{Claude=@{now=$script:Node};Main=@{now='fixture-node'}}}}
function Get-Trace{param($Url)return @{ip=$script:Exit;loc='US'}}
function Get-CslRegionSnapshot{param([switch]$Offline)return @{status='available';countries=@('US')}}
function Get-CslLiveClaudeRoutes{param($Cfg)return @{status='observed';code='route_observed';observed=2;processCount=9;message='合成连接核对通过'}}
function Get-CslClientAccountEvidence{return @{status='unavailable';code='no_recent_client_logs';message='合成无可用日志';signals=@()}}
function Ctl-SelectNode{throw 'Live checks must not change nodes'}
function Enable-CslTun{throw 'Live checks must not change TUN'}
$cfg=[pscustomobject]@{timezone='UTC';expectedNode='fixture-node';claudeGroup='Claude';pinMainGroup=$true;mainGroup='Main';expectedIp='203.0.113.10';expectedLoc='US'}
$live=Get-CslRuntimeRiskSummary $cfg
Assert ($live.assessment.score -eq 100 -and $live.assessment.checkedGroups -eq 7) 'read-only live snapshot checks seven groups with one shared scoring policy'
$script:Zone='different-zone';$live=Get-CslRuntimeRiskSummary $cfg
Assert ($live.assessment.score -eq 92 -and $live.assessment.counts.warn -eq 1) 'real timezone drift is represented as an eight-point live deduction'
$script:Tun='Down';$live=Get-CslRuntimeRiskSummary $cfg
Assert ($live.assessment.score -eq 67 -and $live.assessment.counts.fail -eq 1) 'a TUN outage changes both the live state and score'
$script:Node='other-node';$live=Get-CslRuntimeRiskSummary $cfg
Assert ($live.assessment.score -eq 42 -and $live.assessment.counts.fail -eq 2) 'a strategy group deviation adds its confirmed deduction'
$script:Exit='203.0.113.20';$live=Get-CslRuntimeRiskSummary $cfg
Assert ($live.assessment.score -eq 17) 'a confirmed egress mismatch is linked to scoring'
$script:Zone='UTC';$script:Tun='Up';$script:Node='fixture-node';$script:Exit='203.0.113.10';$live=Get-CslRuntimeRiskSummary $cfg
Assert ($live.assessment.score -eq 100 -and $live.assessment.counts.fail -eq 0 -and $live.assessment.counts.warn -eq 0) 'observed recovery clears only the superseded deductions'
[pscustomobject]@{Passed=$script:Passed;Artifacts=$ArtifactRoot}|ConvertTo-Json -Compress
