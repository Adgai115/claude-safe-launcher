#Requires -Version 5.1
# Pure result and classification helpers. No network, process, registry or configuration changes.
function Test-CslOfficialEndpoint([AllowNull()][string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
  $uri = $null
  if (-not [uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) { return $false }
  return ($uri.Scheme -eq 'https' -and $uri.Host -eq 'api.anthropic.com' -and -not $uri.UserInfo -and $uri.IsDefaultPort)
}

function Get-CslCheckAssessment {
  param([object[]]$Events=@())
  $counts=@{pass=0;warn=0;fail=0;unknown=0;fix=0;reference=0}
  $penalties=@();$lost=0
  foreach($group in @($Events|Group-Object Group)) {
    $levels=@($group.Group|ForEach-Object{$_.Level})
    if($levels -contains 'FAIL'){$counts.fail++}
    elseif($levels -contains 'UNKNOWN'){$counts.unknown++}
    elseif($levels -contains 'WARN'){$counts.warn++}
    elseif($levels -contains 'PASS' -or $levels -contains 'FIX'){$counts.pass++;if($levels -contains 'FIX'){$counts.fix++}}
    else{$counts.reference++}
    $points=0;$reasons=@()
    foreach($event in $group.Group){
      $weight=[Math]::Max(0,[int]$event.Weight);$points+=$weight
      if($weight){$reasons+=@{text=[string]$event.Text;points=$weight}}
    }
    $lost+=$points
    if($points){$penalties+=@{group=[string]$group.Name;points=$points;reasons=$reasons}}
  }
  return @{version=1;score=$(if(@($Events).Count){[Math]::Max(0,100-$lost)}else{$null});counts=$counts;checkedGroups=@($Events|Group-Object Group).Count;totalGroups=15;penalties=$penalties}
}

function Write-CslCheckReport {
  param([string]$Path, [string]$RunId, [bool]$Complete, [string]$Result,
    $Score, [int]$ExitCode, [object[]]$Items = @(), [object[]]$Stages = @(),
    [string]$Mode = 'quick', [string]$Launch = 'no', [object[]]$Events = @(), [bool]$RepairMode = $false,
    [object[]]$RiskChecks = @(), [string[]]$LaunchBlocks = @())
  if (-not $Path) { return }
  $weightedEvents=@(foreach($event in $Events){
    $weight=0
    if($null -ne $event.Weight){$weight=[int]$event.Weight}
    else{$item=@($Items|Where-Object{$_.Group -eq $event.Group -and $_.Level -eq $event.Level -and $_.Text -eq $event.Text}|Select-Object -First 1);if($item.Count){$weight=[int]$item[0].Weight}}
    [pscustomobject]@{Group=$event.Group;Level=$event.Level;Text=$event.Text;Weight=$weight}
  })
  $assessment=Get-CslCheckAssessment $weightedEvents
  $report = [ordered]@{
    schemaVersion = 2; runId = $RunId; complete = $Complete; result = $Result
    score = $Score; exitCode = $ExitCode; checkCount = $Stages.Count; expectedCheckCount = 15
    mode = $Mode; repairMode = $RepairMode; launch = $Launch; timestamp = [datetime]::UtcNow.ToString('o')
    stages = @($Stages); items = @($Items); events = $weightedEvents
    assessmentVersion=1;assessment=$assessment
    riskChecks = @($RiskChecks)
    riskSummary = @{
      fixed = $assessment.counts.fix
      remaining = $assessment.counts.fail
      attention = $assessment.counts.warn
      unknown = $assessment.counts.unknown
      launchBlocked = [bool]($LaunchBlocks.Count -gt 0 -or $assessment.counts.fail -gt 0)
    }
    launchBlocks = @($LaunchBlocks)
  }
  $temp = $Path + '.' + [guid]::NewGuid().ToString('n') + '.tmp'
  try {
    [IO.File]::WriteAllText($temp, ($report | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
    else { [IO.File]::Move($temp, $Path) }
  } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}

function Test-CslCompletedReport {
  param($Report, [string]$RunId, [int]$ExitCode)
  if ($null -eq $Report -or $Report.schemaVersion -ne 2 -or $Report.runId -cne $RunId) { return $false }
  if ($Report.complete -isnot [bool] -or -not $Report.complete) { return $false }
  if ($Report.checkCount -ne 15 -or @($Report.stages).Count -ne 15) { return $false }
  if (@($Report.stages | Select-Object -Unique).Count -ne 15) { return $false }
  if (@($Report.events).Count -lt 15) { return $false }
  foreach ($stage in $Report.stages) {
    if (@($Report.events | Where-Object { $_.Group -eq $stage }).Count -eq 0) { return $false }
  }
  if ($null -eq $Report.score -or [string]$Report.score -notmatch '^\d{1,3}$') { return $false }
  if ([int]$Report.score -lt 0 -or [int]$Report.score -gt 100) { return $false }
  if ($ExitCode -notin @(0, 1, 3) -or $Report.exitCode -ne $ExitCode) { return $false }
  if ($Report.result -notin @('PASS', 'WARN', 'FAIL')) { return $false }
  if($Report.assessmentVersion -eq 1){
    $actual=Get-CslCheckAssessment @($Report.events)
    if($actual.score -ne $Report.score -or $actual.score -ne $Report.assessment.score){return $false}
    foreach($key in @('pass','warn','fail','unknown','fix','reference')){if($actual.counts[$key] -ne $Report.assessment.counts.$key){return $false}}
  }
  if ($ExitCode -eq 1 -and $Report.result -ne 'FAIL') { return $false }
  if ($ExitCode -eq 3 -and ($Report.result -ne 'WARN' -or -not $Report.riskSummary.launchBlocked)) { return $false }
  return $true
}

function Get-CslSettingsPlan($Cfg) {
  $rows = @()
  $currentTimezone = (Get-TimeZone).Id
  if ($Cfg.timezone -and $currentTimezone -ne $Cfg.timezone) {
    $rows += "系统时区：$currentTimezone -> $($Cfg.timezone)"
  }
  $groups = @($Cfg.claudeGroup)
  if ($Cfg.pinMainGroup -and $Cfg.mainGroup) { $groups += $Cfg.mainGroup }
  foreach ($group in @($groups | Where-Object { $_ } | Select-Object -Unique)) {
    $state = Ctl-GetGroup $Cfg $group
    if ($Cfg.expectedNode -and $state -and $state.now -ne $Cfg.expectedNode) {
      $rows += "策略组 $group：$($state.now) -> $($Cfg.expectedNode)"
    } elseif (-not $state) { $rows += "策略组 $group 当前状态无法确认；应用时将重新检测" }
  }
  if (-not (Get-ProxyCore)) { $rows += '代理内核未运行：尝试启动已配置的 Clash Verge，并等待 TUN 就绪' }
  if (-not $Cfg.timezone -or -not $Cfg.expectedNode -or -not $Cfg.expectedIp) {
    $rows += '尚未记住完整环境；请先使用「记住当前环境」建立基准'
  }
  return @($rows)
}

function Get-CslMonitorAlertDecision {
  param([string]$Key, [string]$PreviousKey, [datetime]$LastAlertUtc,
    [datetime]$NowUtc = [datetime]::UtcNow, [int]$CooldownMinutes = 30)
  if (-not $Key) { return 'healthy' }
  if ($Key -ne $PreviousKey -or ($NowUtc - $LastAlertUtc).TotalMinutes -ge $CooldownMinutes) { return 'notify' }
  return 'quiet'
}
