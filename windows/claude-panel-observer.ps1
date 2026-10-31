#Requires -Version 5.1
param([switch]$Observe, [string]$OutputPath)

if ($Observe) {
  # This child only reads process/socket metadata and existing logs.
  . (Join-Path $PSScriptRoot 'claude-common.ps1')
  . (Join-Path $PSScriptRoot 'claude-diagnostics.ps1')
  . (Join-Path $PSScriptRoot 'claude-risk.ps1')
  $temp=$OutputPath+'.tmp'
  try {
    if (-not $OutputPath) { exit 2 }
    $summary=Get-CslRuntimeRiskSummary (Load-Config)
    [IO.File]::WriteAllText($temp,($summary|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $OutputPath) { [IO.File]::Replace($temp,$OutputPath,[NullString]::Value) }
    else { [IO.File]::Move($temp,$OutputPath) }
    exit 0
  } catch { exit 2 }
  finally { if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue} }
}

function Read-CslPanelObservation([string]$Path, [int]$MaxAgeSeconds=90) {
  try {
    $file=Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.Length -gt 65536) { return $null }
    $candidate=(Read-CslLogTail $Path 65536)|ConvertFrom-Json
    $age=([datetime]::UtcNow-([datetime]$candidate.timestampUtc).ToUniversalTime()).TotalSeconds
    if ($age -lt -5 -or $age -gt $MaxAgeSeconds -or -not $candidate.active) { return $null }
    if (-not $candidate.routes.message -or -not $candidate.account.message) { return $null }
    return $candidate
  } catch { return $null }
}

function New-CslPanelObserver([string]$Directory) {
  return @{
    process=$null;startedUtc=[datetime]::MinValue;nextUtc=[datetime]::MinValue
    timeoutSeconds=20;state='idle';summary=$null;directory=$Directory
    result=(Join-Path ([IO.Path]::GetTempPath()) ('csl-observer-'+[guid]::NewGuid().ToString('n')+'.json'))
  }
}

function Stop-CslPanelObserver($Observer) {
  if ($Observer.process) {
    # The stored handle belongs only to our observer child, never to Claude.
    try { if (-not $Observer.process.HasExited) { $Observer.process.Kill() } } catch {}
    try { $Observer.process.Dispose() } catch {}
    $Observer.process=$null
  }
  foreach($path in @($Observer.result,($Observer.result+'.tmp'))){
    if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue}
  }
}

function Update-CslPanelObserver($Observer, [switch]$AllowStart, [datetime]$NowUtc=[datetime]::UtcNow) {
  if ($Observer.process) {
    if ($Observer.process.HasExited) {
      $summary=Read-CslPanelObservation $Observer.result 60
      $Observer.summary=$summary
      $Observer.state=$(if($summary){'ready'}else{'failed'})
      $Observer.nextUtc=$NowUtc.AddSeconds($(if($summary){15}else{30}))
      Stop-CslPanelObserver $Observer
    } elseif (($NowUtc-$Observer.startedUtc).TotalSeconds -ge $Observer.timeoutSeconds) {
      Stop-CslPanelObserver $Observer
      $Observer.state='timed_out';$Observer.nextUtc=$NowUtc.AddSeconds(30)
    }
  }
  if (-not $AllowStart -or $Observer.process -or $NowUtc -lt $Observer.nextUtc) { return }
  try {
    $worker=Join-Path $Observer.directory 'claude-panel-observer.ps1'
    $Observer.process=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -WindowStyle Hidden -PassThru -ArgumentList @(
      '-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$worker+'"'),'-Observe','-OutputPath',('"'+$Observer.result+'"'))
    [void]$Observer.process.Handle
    $Observer.startedUtc=$NowUtc;$Observer.state='running'
  } catch { $Observer.state='failed';$Observer.nextUtc=$NowUtc.AddSeconds(30) }
}

function Get-CslPanelObservationResponse($Observer) {
  $monitor=Read-CslPanelObservation (Join-Path $Observer.directory 'monitor-risk.json') 90
  if ($monitor -and $monitor.checkEvents) { return @{ok=$true;active=$true;pending=$false;summary=$monitor} }
  Update-CslPanelObserver $Observer -AllowStart
  $summary=$Observer.summary
  if ($summary) {
    $age=([datetime]::UtcNow-([datetime]$summary.timestampUtc).ToUniversalTime()).TotalSeconds
    if ($age -gt 60 -or $age -lt -5) { $summary=$null }
  }
  $message=switch($Observer.state){
    'timed_out' {'只读观测超时，已停止本次后台检查，稍后自动重试；面板可继续操作'}
    'failed' {'只读观测暂不可用，稍后自动重试；面板可继续操作'}
    default {'后台正在只读观测，面板可继续操作'}
  }
  return @{ok=$true;active=[bool]$summary;pending=[bool]$Observer.process;summary=$summary;state=$Observer.state;message=$message}
}
