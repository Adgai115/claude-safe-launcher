#Requires -Version 5.1
# Risk observations use public policy data, live connection metadata and allowlisted log signals.
# Never return raw client log lines, cookies, credentials, request bodies or unrelated connections.
$script:CslRegionSource = 'https://support.claude.com/en/articles/8461763-where-can-i-access-claude'

function ConvertTo-CslCountryNameKey([string]$Name) {
  $decomposed = $Name.Normalize([Text.NormalizationForm]::FormD)
  return ([regex]::Replace($decomposed, '\p{M}', '') -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
}

function ConvertFrom-CslRegionsHtml {
  param([string]$Html, $NameMap, [datetime]$NowUtc = [datetime]::UtcNow)
  $anchor = $Html.IndexOf('You can access Claude in the following locations:', [StringComparison]::Ordinal)
  if ($anchor -lt 0) { throw '官方地区页面结构无法识别，保留原缓存' }
  $start = $Html.IndexOf('<ul', $anchor, [StringComparison]::OrdinalIgnoreCase)
  $end = $Html.IndexOf('</ul>', [Math]::Max(0,$start), [StringComparison]::OrdinalIgnoreCase)
  if ($start -lt 0 -or $end -le $start) { throw '官方地区名单不完整，保留原缓存' }
  $codes = New-Object 'System.Collections.Generic.HashSet[string]'
  $entries = [regex]::Matches($Html.Substring($start,$end-$start), '(?is)<li\b[^>]*>(.*?)</li>')
  foreach ($entry in $entries) {
    $name = [Net.WebUtility]::HtmlDecode(([regex]::Replace($entry.Groups[1].Value, '<[^>]*>', ''))).Trim()
    $key = ConvertTo-CslCountryNameKey $name
    $code = $null
    if ($NameMap -is [Collections.IDictionary]) { $code = $NameMap[$key] }
    else { $property = $NameMap.PSObject.Properties[$key]; if ($property) { $code = $property.Value } }
    if (-not $code -or [string]$code -notmatch '^[A-Z]{2}$') { throw '官方名单出现尚未识别的地区，保留原缓存并等待更新映射' }
    [void]$codes.Add([string]$code)
  }
  if ($codes.Count -lt 100 -or $codes.Count -gt 250) { throw '官方名单数量异常，保留原缓存' }
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $digest = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Html)))).Replace('-','').ToLowerInvariant() }
  finally { $sha.Dispose() }
  return [pscustomobject]@{ schemaVersion=1;source=$script:CslRegionSource;fetchedAtUtc=$NowUtc.ToString('o');contentSha256=$digest;countries=@($codes | Sort-Object);sourceEntryCount=$entries.Count }
}

function Test-CslRegionSnapshot($Snapshot, [datetime]$NowUtc = [datetime]::UtcNow) {
  if (-not $Snapshot -or $Snapshot.schemaVersion -ne 1 -or $Snapshot.source -cne $script:CslRegionSource) { return $false }
  $when = [datetime]::MinValue
  if (-not [datetime]::TryParse([string]$Snapshot.fetchedAtUtc, [ref]$when)) { return $false }
  if ($when.ToUniversalTime() -gt $NowUtc.AddMinutes(5)) { return $false }
  $codes = @($Snapshot.countries)
  if ($codes.Count -lt 100 -or $codes.Count -gt 250 -or @($codes | Where-Object { $_ -notmatch '^[A-Z]{2}$' }).Count) { return $false }
  return (@($codes | Select-Object -Unique).Count -eq $codes.Count)
}

function Get-CslRegionSnapshot {
  param([string]$DataDirectory = (Join-Path $script:Root 'data'), [switch]$Offline, [datetime]$NowUtc = [datetime]::UtcNow)
  $path = Join-Path $DataDirectory 'supported-regions.json'
  $cached = $null
  try { $cached = [IO.File]::ReadAllText($path,[Text.Encoding]::UTF8) | ConvertFrom-Json } catch {}
  $valid = Test-CslRegionSnapshot $cached $NowUtc
  $age = [double]::PositiveInfinity
  if ($valid) { $age = ($NowUtc - ([datetime]$cached.fetchedAtUtc).ToUniversalTime()).TotalDays }
  $refreshed = $false
  if (-not $Offline -and $age -ge 1) {
    try {
      $body = (& curl.exe --noproxy '*' --proto '=https' --proto-redir '=https' --location --max-redirs 3 --silent --fail --max-time 12 $script:CslRegionSource 2>$null | Out-String)
      if ($LASTEXITCODE -ne 0 -or $body.Length -gt 2097152) { throw '官方名单下载失败' }
      $map = [IO.File]::ReadAllText((Join-Path $DataDirectory 'country-name-map.json'),[Text.Encoding]::UTF8) | ConvertFrom-Json
      $fresh = ConvertFrom-CslRegionsHtml -Html $body -NameMap $map -NowUtc $NowUtc
      $temp = $path + '.' + [guid]::NewGuid().ToString('n') + '.tmp'
      try {
        [IO.File]::WriteAllText($temp,($fresh | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $path) { [IO.File]::Replace($temp,$path,[NullString]::Value) } else { [IO.File]::Move($temp,$path) }
      } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
      $cached=$fresh;$valid=$true;$age=0;$refreshed=$true
    } catch { }
  }
  if (-not $valid -or $age -gt 7) { return @{status='unknown';source=$script:CslRegionSource;countries=@();ageDays=$age;refreshed=$false} }
  return @{status='available';source=$script:CslRegionSource;countries=@($cached.countries);ageDays=[Math]::Round($age,2);refreshed=$refreshed;checkedAtUtc=$cached.fetchedAtUtc}
}

function Get-CslRegionAssessment($Snapshot, [string]$Country) {
  if ($Snapshot.status -ne 'available' -or $Country -notmatch '^[A-Z]{2}$') {
    return @{status='unknown';blocksLaunch=$true;code='region_unverified';message='官方名单或探测地区无法确认，暂不自动启动；请重试并核对官方支持范围'}
  }
  if ($Country -notin @($Snapshot.countries)) {
    return @{status='risk';blocksLaunch=$true;code='unsupported_region';message='探测地区不在当前官方支持名单内；停止自动启动，需在受支持地区使用'}
  }
  return @{status='observed';blocksLaunch=$false;code='region_observed';message='探测出口位于官方名单中的地区；真实使用资格仍需用户确认，出口位置不能替代资格验证'}
}

function Test-CslServiceHost([string]$HostName) {
  # Official desktop network requirements: code.claude.com/docs/en/desktop#network-access-requirements
  return ($HostName -match '(?i)^(?:[a-z0-9-]+\.)*(?:claude\.ai|anthropic\.com|claude\.com|claude\.app|claudeusercontent\.com|claudemcpcontent\.com)$')
}

function Get-CslClaudeRouteAssessment {
  param([object[]]$Connections, [object[]]$Processes, [string]$ExpectedNode, [bool]$ControllerAvailable=$true, [object[]]$TcpConnections=@())
  if (-not $Processes.Count) { return @{status='unknown';code='client_not_running';message='Claude 未运行；实际客户端连接将在启动后及监控中复查';observed=0;bad=@();ambiguous=0} }
  if (-not $ControllerAvailable) { return @{status='unknown';code='connections_unavailable';message='无法读取代理连接元数据，实际进程路径尚未核实';observed=0;bad=@();ambiguous=0} }
  $bad=New-Object 'System.Collections.Generic.List[object]';$observed=0;$ambiguous=0;$ipv6=0;$tcpAttributed=0
  foreach ($connection in @($Connections)) {
    if (-not $connection -or -not $connection.metadata) { continue }
    $metadata=$connection.metadata
    if (-not (Test-CslServiceHost ([string]$metadata.host))) { continue }
    $owner=$null
    foreach ($process in @($Processes | Sort-Object CreationDate)) {
      $idMatch = $metadata.processId -and ([string]$metadata.processId -eq [string]$process.ProcessId)
      $pathMatch = $metadata.processPath -and $process.ExecutablePath -and ([string]$metadata.processPath).Equals([string]$process.ExecutablePath,[StringComparison]::OrdinalIgnoreCase)
      if (($metadata.processId -and $idMatch -and (-not $metadata.processPath -or $pathMatch)) -or (-not $metadata.processId -and $pathMatch)) { $owner=$process;break }
    }
    # Read-only OS ownership fallback when the controller supplies neither PID nor path.
    # Match both local address and port; a port alone does not establish ownership.
    if (-not $owner -and -not $metadata.processId -and -not $metadata.processPath -and
        (-not $metadata.process -or $metadata.process -match '(?i)^claude(?:\.exe)?$') -and
        $metadata.network -eq 'tcp') {
      $sourceIp=$null
      try { $sourceIp=([Net.IPAddress]::Parse([string]$metadata.sourceIP)).MapToIPv6().ToString() } catch {}
      foreach ($socket in @($TcpConnections)) {
        if (-not $sourceIp -or [string]$socket.LocalPort -ne [string]$metadata.sourcePort) { continue }
        $localIp=$null
        try { $localIp=([Net.IPAddress]::Parse([string]$socket.LocalAddress)).MapToIPv6().ToString() } catch {}
        if ($localIp -ne $sourceIp -or ($metadata.destinationPort -and [string]$socket.RemotePort -ne [string]$metadata.destinationPort)) { continue }
        $owner=@($Processes | Where-Object { [string]$_.ProcessId -eq [string]$socket.OwningProcess } | Select-Object -First 1)[0]
        if ($owner) { $tcpAttributed++;break }
      }
    }
    if (-not $owner) { if ($metadata.process -match '(?i)^claude(?:\.exe)?$') { $ambiguous++ };continue }
    if ($connection.start -and $owner.CreationDate) {
      try { if (([datetime]$connection.start).ToUniversalTime() -lt ([datetime]$owner.CreationDate).ToUniversalTime().AddSeconds(-1)) { $ambiguous++;continue } } catch { $ambiguous++;continue }
    }
    $chains=@($connection.chains | Where-Object { $_ })
    if (-not $chains.Count) { $ambiguous++;continue }
    $observed++
    if ([string]$metadata.destinationIP -match ':') { $ipv6++ }
    $reason=$null
    if ($chains -contains 'DIRECT' -and (-not $ExpectedNode -or $chains -notcontains $ExpectedNode)) { $reason='direct' }
    elseif ($ExpectedNode -and $chains -notcontains $ExpectedNode) { $reason='node_mismatch' }
    if ($reason) { [void]$bad.Add([pscustomobject]@{id=[string]$connection.id;reason=$reason}) }
  }
  $result=@{status='observed';code='route_observed';message="Claude 已运行；已核对 $observed 条官方服务连接，均经过预设节点（只读观测）";observed=$observed;bad=@($bad.ToArray());ambiguous=$ambiguous;ipv6=$ipv6;processCount=$Processes.Count;tcpAttributed=$tcpAttributed}
  if ($bad.Count) { $result.status='risk';$result.code='route_mismatch';$result.message='已观测到 Claude 官方服务连接直连或未使用预设节点；请检查代理路径，本工具不会断开连接' }
  elseif (-not $observed -or $ambiguous) { $result.status='unknown';$result.code='route_incomplete';$result.message='Claude 已运行；当前暂无完整的官方服务连接证据，正常联网后会自动复查' }
  return $result
}

function Get-CslLiveClaudeRoutes($Cfg) {
  $processes=@(Get-ClaudeProcesses)
  if (-not $processes.Count) { return Get-CslClaudeRouteAssessment -Connections @() -Processes @() -ExpectedNode $Cfg.expectedNode }
  $snapshot=Ctl-Get $Cfg '/connections'
  $sockets=@()
  try { $ids=@($processes | ForEach-Object {$_.ProcessId});$sockets=@(Get-NetTCPConnection -State Established -ErrorAction Stop | Where-Object {$_.OwningProcess -in $ids}) } catch {}
  return Get-CslClaudeRouteAssessment -Connections @($snapshot.connections) -Processes $processes -ExpectedNode $Cfg.expectedNode -ControllerAvailable ([bool]($snapshot -and $null -ne $snapshot.connections)) -TcpConnections $sockets
}

function Repair-CslClaudeRoutes($Cfg, $Assessment) {
  # Compatibility entry point. Client connections are strictly read-only.
  return @{attempted=$false;closed=0;assessment=$Assessment;mode='read-only'}
}

function Get-CslClientLogDirectories {
  $paths=@((Join-Path $env:APPDATA 'Claude\logs'),(Join-Path $env:LOCALAPPDATA 'Claude\logs'),
    (Join-Path $env:LOCALAPPDATA 'Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\logs'))
  return @($paths | Select-Object -Unique)
}

function Get-CslAccountSignal([string]$Line) {
  # Restrict to error/response/auth contexts; ordinary conversation text is not evidence.
  if ($Line -notmatch '(?i)(?:\berror\b|APIError|http[_ ]?status|request failed|auth(?:entication)?[ _-]?(?:error|failed)|response[ _-]?(?:error|status))') { return $null }
  if ($Line -match '(?i)(?:account_(?:disabled|suspended|banned)|your account (?:has been|is) (?:disabled|suspended|banned))') { return 'account_restriction' }
  if ($Line -match '(?i)(?:unsupported_(?:country|region|location)|not available in your (?:country|region)|not supported in your (?:country|region))') { return 'region_restriction' }
  if ($Line -match '(?i)(?:billing_error|payment_required|status["\s:_=-]*402\b)') { return 'billing_issue' }
  if ($Line -match '(?i)(?:rate_limit_error|status["\s:_=-]*429\b|HTTP\s+429\b)') { return 'rate_limit' }
  if ($Line -match '(?i)(?:authentication_error|status["\s:_=-]*401\b|HTTP\s+401\b)') { return 'authentication_issue' }
  if ($Line -match '(?i)(?:permission_error|status["\s:_=-]*403\b|HTTP\s+403\b)') { return 'permission_issue' }
  return $null
}

function Get-CslLogTimestamp([string]$Line) {
  $match=[regex]::Match($Line, '^.{0,3}(\d{4}-\d{2}-\d{2}[T ][0-9:.]+(?:Z|[+-]\d{2}:?\d{2})?)')
  if (-not $match.Success) { return $null }
  try { return ([datetime]::Parse($match.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeLocal)).ToUniversalTime() } catch { return $null }
}

function Read-CslLogTail([string]$Path, [int]$MaxBytes=262144) {
  $stream=$null;$reader=$null
  try {
    $stream=[IO.File]::Open($Path,'Open','Read','ReadWrite,Delete')
    $offset=[Math]::Max(0,$stream.Length-$MaxBytes);[void]$stream.Seek($offset,'Begin')
    $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
    if ($offset -gt 0) { [void]$reader.ReadLine() }
    return $reader.ReadToEnd()
  } finally { if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() } }
}

function Get-CslClientAccountEvidence {
  param([string[]]$LogDirectories = (Get-CslClientLogDirectories), [datetime]$NowUtc=[datetime]::UtcNow)
  $signals=New-Object 'System.Collections.Generic.List[object]';$readable=0;$recent=0
  foreach ($directory in $LogDirectories) {
    foreach ($name in @('main.log','claude.ai-web.log')) {
      $path=Join-Path $directory $name
      if (-not (Test-Path -LiteralPath $path)) { continue }
      try {
        $file=Get-Item -LiteralPath $path -ErrorAction Stop
        if ($file.LastWriteTimeUtc -lt $NowUtc.AddHours(-2)) { continue }
        $tail=Read-CslLogTail $path;$readable++
        foreach ($line in ($tail -split '\r?\n')) {
          $timestamp=Get-CslLogTimestamp $line
          if (-not $timestamp -or $timestamp -lt $NowUtc.AddHours(-2) -or $timestamp -gt $NowUtc.AddMinutes(5)) { continue }
          $recent++
          $kind=Get-CslAccountSignal $line
          if ($kind) { [void]$signals.Add([pscustomobject]@{kind=$kind;timestampUtc=$timestamp.ToString('o');file=$name}) }
        }
      } catch { }
    }
  }
  $unique=@($signals.ToArray() | Sort-Object kind,timestampUtc -Descending | Group-Object kind | ForEach-Object {$_.Group[0]})
  if ($unique.Count) { return @{status='risk';code='client_log_warning';signals=$unique;readableFiles=$readable;message='近期客户端日志出现账号、权限或用量类告警；可能已处理或属于其他会话，请在客户端确认当前状态'} }
  if ($recent -gt 0) { return @{status='observed';code='no_recent_alerts';signals=@();readableFiles=$readable;message='已扫描最近两小时的客户端日志，未发现相关告警；此项仅报告日志扫描结果'} }
  return @{status='unavailable';code='no_recent_client_logs';signals=@();readableFiles=$readable;message='暂无最近两小时的可用客户端日志；跳过告警扫描，无需手动核实账号'}
}

function ConvertTo-CslObservationEvent([string]$Group,$Observation,[switch]$LogScan) {
  $level=switch($Observation.status){'risk' {if($LogScan){'WARN'}else{'FAIL'}} 'unknown' {'UNKNOWN'} 'observed' {'PASS'} default {'INFO'}}
  return [pscustomobject]@{Group=$Group;Level=$level;Text=$Observation.message;Weight=$(if($level -eq 'FAIL'){25}else{0})}
}

function Get-CslLiveStandardEvents($Cfg) {
  $events=New-Object 'System.Collections.Generic.List[object]'
  $core=Get-ProxyCore;$adapter=Get-TunAdapter
  if($core -and $adapter -and $adapter.Status -eq 'Up'){
    [void]$events.Add([pscustomobject]@{Group='1. Clash Verge 与 TUN 模式';Level='PASS';Text='实时复查：代理内核运行中，TUN 网卡已启用';Weight=0})
  }else{
    if(-not $core){[void]$events.Add([pscustomobject]@{Group='1. Clash Verge 与 TUN 模式';Level='FAIL';Text='实时复查：代理内核未运行';Weight=25})}
    if(-not $adapter -or $adapter.Status -ne 'Up'){[void]$events.Add([pscustomobject]@{Group='1. Clash Verge 与 TUN 模式';Level='FAIL';Text='实时复查：TUN 网卡未就绪';Weight=25})}
  }
  $zone=(Get-TimeZone).Id
  $level='PASS';$weight=0;$message='实时复查：系统时区与记录的标准一致'
  if(-not $Cfg.timezone){$level='UNKNOWN';$message='尚未记录时区标准，无法核对'}
  elseif($zone -ne $Cfg.timezone){$level='WARN';$weight=8;$message='实时复查：系统时区与记录的标准不一致，可按标准修复'}
  [void]$events.Add([pscustomobject]@{Group='2. 系统时区';Level=$level;Text=$message;Weight=$weight})
  $snapshot=Ctl-Get $Cfg '/proxies'
  $groups=@($Cfg.claudeGroup);if($Cfg.pinMainGroup -and $Cfg.mainGroup){$groups+=@($Cfg.mainGroup)}
  foreach($group in @($groups|Where-Object{$_}|Select-Object -Unique)){
    $level='PASS';$weight=0;$message='实时复查：'+$group+' 策略组与预设节点一致'
    if(-not $snapshot -or -not $snapshot.proxies -or -not $Cfg.expectedNode){$level='UNKNOWN';$message='实时复查：无法读取策略组或预设标准，节点状态待核实'}
    else{
      $entry=$null
      if($snapshot.proxies -is [Collections.IDictionary]){$entry=$snapshot.proxies[$group]}else{$property=$snapshot.proxies.PSObject.Properties[$group];if($property){$entry=$property.Value}}
      if(-not $entry -or $entry.now -ne $Cfg.expectedNode){$level='FAIL';$weight=25;$message='实时复查：'+$group+' 策略组与预设节点不一致'}
    }
    [void]$events.Add([pscustomobject]@{Group='3. 节点锁定';Level=$level;Text=$message;Weight=$weight})
  }
  $trace=Get-Trace 'https://claude.ai/cdn-cgi/trace'
  $level='PASS';$weight=0;$message='实时复查：Claude 域名探测出口与记录的标准一致'
  if(-not $trace.ip -or -not $Cfg.expectedIp){$level='UNKNOWN';$message='实时复查：无法确认 Claude 域名探测出口或缺少出口标准'}
  elseif($trace.ip -ne $Cfg.expectedIp -or ($Cfg.expectedLoc -and $trace.loc -ne $Cfg.expectedLoc)){$level='FAIL';$weight=25;$message='实时复查：Claude 域名探测出口与记录的标准不一致'}
  [void]$events.Add([pscustomobject]@{Group='4. 出口 IP 三方对比（本机实测 / 期望 / Claude 边缘）';Level=$level;Text=$message;Weight=$weight})
  $region=Get-CslRegionAssessment (Get-CslRegionSnapshot -Offline) ([string]$trace.loc)
  [void]$events.Add((ConvertTo-CslObservationEvent '13. 官方支持地区核对' $region))
  return $events.ToArray()
}

function Get-CslRuntimeRiskSummary($Cfg) {
  $checks=@(Get-CslLiveStandardEvents $Cfg)
  $routes=Get-CslLiveClaudeRoutes $Cfg
  $account=Get-CslClientAccountEvidence
  $checks+=@(ConvertTo-CslObservationEvent '14. Claude 实际进程连接' $routes)
  $checks+=@(ConvertTo-CslObservationEvent '15. 客户端告警扫描' $account -LogScan)
  $assessment=Get-CslCheckAssessment $checks
  $unknown=$assessment.counts.unknown;$remaining=$assessment.counts.fail
  return @{
    timestampUtc=[datetime]::UtcNow.ToString('o');active=$true
    status=$(if($remaining -or $assessment.counts.warn){'risk'}elseif($unknown){'unknown'}else{'observed'})
    remaining=$remaining;unknown=$unknown;fixed=0
    attention=$assessment.counts.warn;checkEvents=$checks;assessmentVersion=1;assessment=$assessment
    routes=@{status=$routes.status;code=$routes.code;message=$routes.message;observed=$routes.observed;processCount=$routes.processCount;tcpAttributed=$routes.tcpAttributed}
    account=@{status=$account.status;code=$account.code;message=$account.message;readableFiles=$account.readableFiles;categories=@($account.signals|ForEach-Object{$_.kind})}
  }
}
