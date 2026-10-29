# Claude 安全启动（通用版）- 公共函数（被 claude-preflight.ps1 / claude-monitor.ps1 / claude-panel.ps1 引用）
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$script:Root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:CfgPath   = Join-Path $script:Root 'preflight.json'
$script:LogPath   = Join-Path $script:Root 'preflight.log'
$script:Utf8NoBom = New-Object Text.UTF8Encoding($false)
if ($env:APPDATA) { $script:VergeDir = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev' } else { $script:VergeDir = $null }

# IANA 时区 → Windows 时区（常用地区）
$script:TzMap = @{
  'America/New_York'='Eastern Standard Time'; 'America/Detroit'='Eastern Standard Time'; 'America/Toronto'='Eastern Standard Time'
  'America/Chicago'='Central Standard Time'; 'America/Denver'='Mountain Standard Time'; 'America/Phoenix'='US Mountain Standard Time'
  'America/Los_Angeles'='Pacific Standard Time'; 'America/Vancouver'='Pacific Standard Time'; 'America/Anchorage'='Alaskan Standard Time'
  'Pacific/Honolulu'='Hawaiian Standard Time'; 'America/Sao_Paulo'='E. South America Standard Time'
  'Europe/London'='GMT Standard Time'; 'Europe/Dublin'='GMT Standard Time'; 'Europe/Lisbon'='GMT Standard Time'
  'Europe/Berlin'='W. Europe Standard Time'; 'Europe/Amsterdam'='W. Europe Standard Time'; 'Europe/Zurich'='W. Europe Standard Time'
  'Europe/Stockholm'='W. Europe Standard Time'; 'Europe/Vienna'='W. Europe Standard Time'; 'Europe/Rome'='W. Europe Standard Time'
  'Europe/Paris'='Romance Standard Time'; 'Europe/Brussels'='Romance Standard Time'; 'Europe/Madrid'='Romance Standard Time'
  'Europe/Warsaw'='Central European Standard Time'; 'Europe/Prague'='Central Europe Standard Time'; 'Europe/Helsinki'='FLE Standard Time'
  'Asia/Tokyo'='Tokyo Standard Time'; 'Asia/Seoul'='Korea Standard Time'; 'Asia/Singapore'='Singapore Standard Time'
  'Asia/Taipei'='Taipei Standard Time'; 'Asia/Kuala_Lumpur'='Singapore Standard Time'; 'Asia/Bangkok'='SE Asia Standard Time'
  'Asia/Dubai'='Arabian Standard Time'; 'Asia/Kolkata'='India Standard Time'
  'Australia/Sydney'='AUS Eastern Standard Time'; 'Australia/Melbourne'='AUS Eastern Standard Time'; 'Pacific/Auckland'='New Zealand Standard Time'
}
function Convert-IanaToWindows([string]$iana) { if ($iana -and $script:TzMap.ContainsKey($iana)) { return $script:TzMap[$iana] }; return $null }

function Convert-WindowsToIana([string]$win) {
  if (-not $win) { return $null }
  # Prefer a canonical IANA for each Windows zone (first matching key in TzMap)
  $prefer = @{
    'Eastern Standard Time'='America/New_York'; 'Central Standard Time'='America/Chicago'
    'Mountain Standard Time'='America/Denver'; 'US Mountain Standard Time'='America/Phoenix'
    'Pacific Standard Time'='America/Los_Angeles'; 'Alaskan Standard Time'='America/Anchorage'
    'Hawaiian Standard Time'='Pacific/Honolulu'; 'GMT Standard Time'='Europe/London'
    'W. Europe Standard Time'='Europe/Berlin'; 'Romance Standard Time'='Europe/Paris'
    'Tokyo Standard Time'='Asia/Tokyo'; 'Korea Standard Time'='Asia/Seoul'
    'Singapore Standard Time'='Asia/Singapore'; 'China Standard Time'='Asia/Shanghai'
    'AUS Eastern Standard Time'='Australia/Sydney'; 'New Zealand Standard Time'='Pacific/Auckland'
    'India Standard Time'='Asia/Kolkata'; 'Arabian Standard Time'='Asia/Dubai'
    'E. South America Standard Time'='America/Sao_Paulo'; 'FLE Standard Time'='Europe/Helsinki'
    'Central European Standard Time'='Europe/Warsaw'; 'Central Europe Standard Time'='Europe/Prague'
    'Taipei Standard Time'='Asia/Taipei'; 'SE Asia Standard Time'='Asia/Bangkok'
  }
  if ($prefer.ContainsKey($win)) { return $prefer[$win] }
  foreach ($k in $script:TzMap.Keys) { if ($script:TzMap[$k] -eq $win) { return $k } }
  return $null
}


function Read-VergeRuntime {
  $h = @{}
  $rt = Join-Path $script:VergeDir 'clash-verge.yaml'
  if (Test-Path $rt) {
    foreach ($line in (Get-Content $rt -Encoding UTF8)) {
      if ($line -match '^(secret|external-controller|mixed-port|port):\s*(.*)$') { $h[$matches[1]] = $matches[2].Trim().Trim("'").Trim('"') }
    }
  }
  return $h
}

function Find-ClaudeApp {
  try {
    $pkg = Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Claude' -or ($_.Name -like '*Claude*' -and $_.Publisher -match 'Anthropic') } | Select-Object -First 1
    if ($pkg) {
      $id = 'Claude'
      try { $m = Get-AppxPackageManifest $pkg; $a = @($m.Package.Applications.Application)[0].Id; if ($a) { $id = $a } } catch {}
      return @{ aumid = "$($pkg.PackageFamilyName)!$($id)"; exe = '' }
    }
  } catch {}
  foreach ($p in @("$env:LOCALAPPDATA\AnthropicClaude\claude.exe", "$env:LOCALAPPDATA\Programs\Claude\Claude.exe", "$env:ProgramFiles\Claude\Claude.exe")) {
    if (Test-Path $p) { return @{ aumid = ''; exe = $p } }
  }
  return @{ aumid = ''; exe = '' }
}

function Find-ClashExe {
  $p = Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
  if ($p) { return $p.Path }
  foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
    $e = Get-ItemProperty $root -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'Clash Verge*' } | Select-Object -First 1
    if ($e) {
      if ($e.InstallLocation) { $x = Join-Path $e.InstallLocation 'clash-verge.exe'; if (Test-Path $x) { return $x } }
      if ($e.DisplayIcon) { $x = ($e.DisplayIcon -split ',')[0].Trim('"'); if ($x -and (Test-Path $x)) { return $x } }
    }
  }
  foreach ($x in @("$env:ProgramFiles\Clash Verge\clash-verge.exe", "$env:LOCALAPPDATA\Programs\Clash Verge\clash-verge.exe")) { if (Test-Path $x) { return $x } }
  return ''
}

function Find-NpmGlobalDir {
  $c = Get-Command claude.cmd, claude -ErrorAction SilentlyContinue | Where-Object { $_.Source } | Select-Object -First 1
  if ($c) { return (Split-Path -Parent $c.Source) }
  $d = Join-Path $env:APPDATA 'npm'; if (Test-Path $d) { return $d }
  return ''
}

# v3.3.0: one-click env fix switches from preflight.json
#   envFixEnabled (default true): false turns off -FixEnv / panel「修复」 (undo and list keep working)
#   envFixKeep (default empty): variable names (wildcards allowed) the fix must keep
function Get-CslEnvFixSettings($Cfg) {
  $enabled = $true
  $keep = @()
  if ($Cfg) {
    if ($Cfg.PSObject.Properties['envFixEnabled'] -and $null -ne $Cfg.envFixEnabled) {
      $v = $Cfg.envFixEnabled
      if ($v -is [bool]) { $enabled = $v }
      elseif ([string]$v -match '^(?i:false|0|no|off)$') { $enabled = $false }
    }
    if ($Cfg.PSObject.Properties['envFixKeep'] -and $null -ne $Cfg.envFixKeep) {
      $keep = @(@($Cfg.envFixKeep) | Where-Object { $null -ne $_ } | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    }
  }
  return @{ enabled = [bool]$enabled; keep = @($keep) }
}

function Load-Config([switch]$NoWrite) {
  # -NoWrite（R4d）：首次运行 / 补默认值时只在内存里补，不创建也不改写配置文件；默认不带，所有其他调用方行为不变
  # 留空的项会自动检测，或在第一次运行时自动记住
  $defaults = [ordered]@{
    expectedIp          = ''
    expectedLoc         = ''
    expectedNode        = ''
    claudeGroup         = 'Claude'
    mainGroup           = ''
    pinMainGroup        = $false
    timezone            = ''
    expectedTzIana       = ''
    claudeAumid         = ''
    claudeExe           = ''
    clashExe            = ''
    proxyUrl            = ''
    controllerUrl       = ''
    controllerSecret    = ''
    warnRisk            = 33
    failRisk            = 66
    monitorIntervalMin  = 5
    monitorKillOnChange = $false
    npmGlobalDir        = ''
    fixVarPatterns      = @()
    envFixEnabled       = $true
    envFixKeep          = @()
  }
  $cfg = $null
  if (Test-Path $script:CfgPath) { try { $cfg = Get-Content $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $cfg = $null } }
  if (-not $cfg) { $cfg = New-Object psobject }
  $changed = $false
  foreach ($k in @($defaults.Keys)) {
    if (-not ($cfg.PSObject.Properties.Name -contains $k)) { $cfg | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k] -Force; $changed = $true }
  }
  if ($changed -and -not $NoWrite) { try { [IO.File]::WriteAllText($script:CfgPath, ($cfg | ConvertTo-Json), $script:Utf8NoBom) } catch {} }

  # 以下为运行时自动检测，不写回配置文件
  $rt = Read-VergeRuntime
  if ($rt['secret']) { $cfg.controllerSecret = $rt['secret'] }
  if ($rt['external-controller']) { $a = $rt['external-controller']; if ($a -match '^:') { $a = '127.0.0.1' + $a }; $cfg.controllerUrl = 'http://' + ($a -replace '^0\.0\.0\.0', '127.0.0.1') }
  if (-not $cfg.controllerUrl) { $cfg.controllerUrl = 'http://127.0.0.1:9097' }
  if (-not $cfg.proxyUrl) {
    $port = $(if ($rt['mixed-port']) { $rt['mixed-port'] } elseif ($rt['port']) { $rt['port'] } else { '7897' })
    $cfg.proxyUrl = "http://127.0.0.1:$($port)"
  }
  if (-not $cfg.claudeAumid -and -not $cfg.claudeExe) { $app = Find-ClaudeApp; $cfg.claudeAumid = [string]$app.aumid; $cfg.claudeExe = [string]$app.exe }
  if (-not $cfg.clashExe) { $cfg.clashExe = [string](Find-ClashExe) }
  if (-not $cfg.npmGlobalDir) { $cfg.npmGlobalDir = [string](Find-NpmGlobalDir) }
  return $cfg
}

# 把学到的值写回 preflight.json（只写给定的键）
function Save-Learned($cfg, [hashtable]$vals) {
  $j = $null
  try { $j = Get-Content $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
  if (-not $j) { $j = New-Object psobject }
  foreach ($k in $vals.Keys) { $j | Add-Member -NotePropertyName $k -NotePropertyValue $vals[$k] -Force; $cfg.$k = $vals[$k] }
  try { [IO.File]::WriteAllText($script:CfgPath, ($j | ConvertTo-Json), $script:Utf8NoBom) } catch {}
}

function Start-ClaudeApp($cfg) {
  if ($cfg.claudeAumid) { Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$($cfg.claudeAumid)"; return $true }
  if ($cfg.claudeExe -and (Test-Path $cfg.claudeExe)) { Start-Process -FilePath $cfg.claudeExe; return $true }
  return $false
}

function Write-Log([string]$line) {
  $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'
  try { [IO.File]::AppendAllText($script:LogPath, "$($stamp) | $($line)`r`n", $script:Utf8NoBom) } catch {}
}


# 脱敏显示：永不打印完整密钥。后续可扩展 USERPROFILE 路径、完整 URL 等规则。
# -Kind: Auto (默认) | Secret | Path | Url
function Mask-Value {
  param(
    [AllowNull()][string]$Value,
    [ValidateSet('Auto','Secret','Path','Url')][string]$Kind = 'Auto'
  )
  if ($null -eq $Value -or $Value -eq '') { return '(空)' }
  $v = [string]$Value
  # 预留：Path / Url 规则（v3.3+）；当前 Auto 与 Secret 同路径，先做前缀掩码
  if ($Kind -eq 'Path' -or ($Kind -eq 'Auto' -and $v -match '(?i)^[A-Za-z]:\\|^/')) {
    # collapse user profile prefix when present; never fall through to Secret for Path kind
    try {
      $up = [string]$env:USERPROFILE
      if ($up -and $v.IndexOf($up, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $v = [regex]::Replace($v, [regex]::Escape($up), '%USERPROFILE%', 'IgnoreCase')
      }
    } catch {}
    $v = [regex]::Replace($v, '(?i)([A-Za-z]:\\Users\\)[^\\\/\s"'']+', '%USERPROFILE%')
    $v = [regex]::Replace($v, '(?i)(/Users/)[^\/\s"'']+', '%USERPROFILE%')
    if ($Kind -eq 'Path') { return $v }
    # Auto: if it looked like a path, return after path rules (do not secret-mask paths)
    if ($v -match '(?i)%USERPROFILE%|^[A-Za-z]:\\|^/') { return $v }
  }
  if ($Kind -eq 'Url' -or ($Kind -eq 'Auto' -and $v -match '(?i)^https?://')) {
    # placeholder: keep scheme+host, mask path/query for future; for now treat as secret-ish
    try {
      $uri = [uri]$v
      if ($uri.Host) {
        $tail = if ($uri.PathAndQuery -and $uri.PathAndQuery -ne '/') { '/****' } else { '' }
        return ($uri.Scheme + '://' + $uri.Host + $tail)
      }
    } catch {}
  }
  # Secret / default: first 4 chars + ****
  if ($v.Length -le 4) { return ($v.Substring(0,1) + '****') }
  return ($v.Substring(0,4) + '****')
}
# 别名：供面板/日志/修复共用
function Protect-Secret([AllowNull()][string]$Value) { Mask-Value -Value $Value -Kind Secret }


function Get-TunAdapter {
  Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
    $_.InterfaceDescription -match 'Meta Tunnel|Mihomo|Clash|wintun' -or $_.Name -match '^(Mihomo|Meta|Clash)'
  } | Select-Object -First 1
}

function Get-ProxyCore { Get-Process -Name 'verge-mihomo*', 'mihomo*', 'clash-meta*' -ErrorAction SilentlyContinue }

# 走真实 TUN 路径（忽略 HTTPS_PROXY 环境变量）
function Invoke-Curl([string[]]$curlArgs) {
  $out = & curl.exe --noproxy '*' -s @curlArgs 2>$null
  return ($out | Out-String)
}

function Get-Trace([string]$url) {
  $t = Invoke-Curl @('-m', '12', $url)
  $h = @{}
  foreach ($line in ($t -split "`n")) { if ($line.Trim() -match '^(\w+)=(.*)$') { $h[$matches[1]] = $matches[2] } }
  return $h
}

function Get-ClaudeProcesses {
  Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -like '*WindowsApps*Claude*' -or $_.ExecutablePath -like '*AnthropicClaude*' -or $_.ExecutablePath -like '*\Claude\Claude.exe' }
}

# ---- mihomo 外部控制器（HttpWebRequest，3 秒超时，不走代理） ----
function Invoke-Ctl($cfg, [string]$method, [string]$path, [string]$body = $null) {
  try {
    $req = [Net.HttpWebRequest]::Create($cfg.controllerUrl.TrimEnd('/') + $path)
    $req.Method = $method; $req.Proxy = $null; $req.Timeout = 3000; $req.ReadWriteTimeout = 3000
    if ($cfg.controllerSecret) { $req.Headers['Authorization'] = 'Bearer ' + $cfg.controllerSecret }
    if ($body) {
      $bytes = [Text.Encoding]::UTF8.GetBytes($body)
      $req.ContentType = 'application/json; charset=utf-8'; $req.ContentLength = $bytes.Length
      $st = $req.GetRequestStream(); $st.Write($bytes, 0, $bytes.Length); $st.Close()
    }
    $resp = $req.GetResponse()
    $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
    $text = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
    return @{ ok = $true; text = $text }
  } catch { return @{ ok = $false; text = $null } }
}
function Ctl-Get($cfg, [string]$path) {
  $r = Invoke-Ctl $cfg 'GET' $path
  if ($r.ok -and $r.text) { try { return ($r.text | ConvertFrom-Json) } catch {} }
  return $null
}
function Ctl-GetGroup($cfg, [string]$group) {
  if (-not $group) { return $null }
  return (Ctl-Get $cfg ('/proxies/' + [uri]::EscapeDataString($group)))
}
function Ctl-SelectNode($cfg, [string]$group, [string]$node) {
  if (-not $group -or -not $node) { return $false }
  $body = '{"name":' + (ConvertTo-Json $node) + '}'
  return (Invoke-Ctl $cfg 'PUT' ('/proxies/' + [uri]::EscapeDataString($group)) $body).ok
}

# ----- Panel API security (CSRF / DNS rebinding) -----
# Long-term rules: loopback-only bind; Host allowlist; Origin required on POST;
# application/json POSTs; per-launch X-CSL-Token on every /api request; never log the token.

function New-CslSessionToken {
  $bytes = New-Object byte[] 32
  $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
  try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
  # hex: 64 chars, URL/header safe
  return ([BitConverter]::ToString($bytes) -replace '-','').ToLowerInvariant()
}

function Test-CslSecureEqual {
  param([AllowNull()][string]$A, [AllowNull()][string]$B)
  if ($null -eq $A) { $A = '' }
  if ($null -eq $B) { $B = '' }
  $ba = [Text.Encoding]::UTF8.GetBytes($A)
  $bb = [Text.Encoding]::UTF8.GetBytes($B)
  $diff = $ba.Length -bxor $bb.Length
  $n = [Math]::Min($ba.Length, $bb.Length)
  for ($i = 0; $i -lt $n; $i++) { $diff = $diff -bor ($ba[$i] -bxor $bb[$i]) }
  # pad remaining length into timing without short-circuit on content
  if ($ba.Length -ne $bb.Length) {
    $longer = if ($ba.Length -gt $bb.Length) { $ba } else { $bb }
    for ($i = $n; $i -lt $longer.Length; $i++) { $diff = $diff -bor $longer[$i] -bor 1 }
  }
  return ($diff -eq 0)
}

function Test-CslPanelHostAllowed {
  param([string]$HostHeader, [int]$Port = 47831)
  if (-not $HostHeader) { return $false }
  $h = $HostHeader.Trim()
  $allowed = @(
    ("localhost:{0}" -f $Port),
    ("127.0.0.1:{0}" -f $Port)
  )
  foreach ($a in $allowed) {
    if ([string]::Equals($h, $a, [StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

function Test-CslPanelOriginAllowed {
  param([AllowNull()][string]$Origin, [int]$Port = 47831)
  if (-not $Origin) { return $false }
  $o = $Origin.Trim().TrimEnd('/')
  $allowed = @(
    ("http://localhost:{0}" -f $Port),
    ("http://127.0.0.1:{0}" -f $Port)
  )
  foreach ($a in $allowed) {
    if ([string]::Equals($o, $a, [StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

function Test-CslPanelContentTypeJson {
  param([AllowNull()][string]$ContentType)
  if (-not $ContentType) { return $false }
  $ct = $ContentType.Trim()
  if ($ct -match '^\s*application/json(\s*;.*)?$') { return $true }
  return $false
}

<#
.SYNOPSIS
  Validate a panel /api request. Returns @{ ok; status; error }.
  - Page GET "/" is not validated here (caller skips).
  - All /api requests need Host allowlist + X-CSL-Token (constant-time).
  - POST additionally: Origin required+allowlisted; Content-Type application/json.
  - Never emits Access-Control-* ; OPTIONS should be rejected by caller.
#>
function Test-CslPanelApiRequest {
  param(
    [string]$Method,
    [string]$HostHeader,
    [AllowNull()][string]$Origin,
    [AllowNull()][string]$ContentType,
    [AllowNull()][string]$TokenHeader,
    [string]$ExpectedToken,
    [int]$Port = 47831,
    [switch]$IsApiPath
  )
  if (-not $IsApiPath) {
    return @{ ok = $true; status = 200; error = $null }
  }
  if (-not (Test-CslPanelHostAllowed -HostHeader $HostHeader -Port $Port)) {
    return @{ ok = $false; status = 403; error = 'forbidden host' }
  }
  if (-not (Test-CslSecureEqual -A $TokenHeader -B $ExpectedToken)) {
    return @{ ok = $false; status = 403; error = 'forbidden token' }
  }
  $m = [string]$Method
  if ($m -eq 'OPTIONS') {
    return @{ ok = $false; status = 403; error = 'forbidden method' }
  }
  if ($m -eq 'POST') {
    if (-not $Origin) {
      return @{ ok = $false; status = 403; error = 'forbidden origin' }
    }
    if (-not (Test-CslPanelOriginAllowed -Origin $Origin -Port $Port)) {
      return @{ ok = $false; status = 403; error = 'forbidden origin' }
    }
    if (-not (Test-CslPanelContentTypeJson -ContentType $ContentType)) {
      return @{ ok = $false; status = 403; error = 'forbidden content-type' }
    }
  }
  return @{ ok = $true; status = 200; error = $null }
}


function Test-CslUndoDecisionsValid {
  param(
    [hashtable]$Decisions,
    [string[]]$AllowedNames
  )
  if ($null -eq $Decisions) { return @{ ok = $true; error = $null } }
  $allow = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($n in @($AllowedNames)) { if ($n) { [void]$allow.Add([string]$n) } }
  foreach ($key in @($Decisions.Keys)) {
    $name = [string]$key
    if (-not $allow.Contains($name)) {
      return @{ ok = $false; error = "unknown decision name: $name" }
    }
    $v = ([string]$Decisions[$key]).ToLowerInvariant()
    if ($v -ne 'skip' -and $v -ne 'overwrite') {
      return @{ ok = $false; error = "invalid decision for ${name}: $v" }
    }
  }
  return @{ ok = $true; error = $null }
}
