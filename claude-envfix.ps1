# Claude 安全启动 · 用户级环境变量一键修复 / 撤销（Windows）
# 由 claude-preflight.ps1 / claude-panel.ps1 dot-source。仅操作用户级（User / HKCU\Environment）。
# 备份含原始值与 RegistryValueKind，仅用于撤销；面板与日志必须走 Protect-Secret，禁止打印明文。

if (-not $script:CslEnvFixLoaded) {

$script:CslEnvFixLoaded = $true
$script:CslDefaultFixVars = @(
  'ANTHROPIC_BASE_URL',
  'ANTHROPIC_AUTH_TOKEN',
  'ANTHROPIC_API_KEY',
  'ANTHROPIC_MODEL',
  'ANTHROPIC_SMALL_FAST_MODEL'
)
$script:CslEnvBackupKeep = 10

# 脱敏请用 claude-common.ps1 的 Protect-Secret / Mask-Value
function Mask-CslSecret([AllowNull()][string]$Value) { Protect-Secret $Value }

function Get-CslEnvBackupDir {
  $root = $script:Root
  if (-not $root) { $root = $PSScriptRoot }
  $d = Join-Path $root 'backups'
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
  return $d
}

# ----- injectable user-env store (tests replace this) -----
# GetUserEntry: $null = 不存在；@{ Value = <string, 可为 ''>; Kind = 'String'|'ExpandString' }
# SetUserEntry: Value 用 [object]；$null = 删除名；'' = 写入空字符串；Kind 默认 String
function Get-CslDefaultEnvStore {
  if ($script:CslEnvStore) { return $script:CslEnvStore }
  return [pscustomobject]@{
    GetUserEntry = {
      param([string]$Name)
      try {
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
        if (-not $k) { return $null }
        try {
          $names = $k.GetValueNames()
          if ($names -notcontains $Name) { return $null }
          $raw = $k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
          $kindObj = $k.GetValueKind($Name)
          $kind = 'String'
          if ($kindObj -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) { $kind = 'ExpandString' }
          elseif ($kindObj -eq [Microsoft.Win32.RegistryValueKind]::String) { $kind = 'String' }
          else { $kind = [string]$kindObj }
          if ($null -eq $raw) { $raw = '' }
          return @{ Value = [string]$raw; Kind = $kind }
        } finally { $k.Close() }
      } catch { return $null }
    }
    GetMachine = {
      param([string]$Name)
      try {
        $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $false)
        if (-not $k) { return $null }
        try {
          if ($k.GetValueNames() -notcontains $Name) { return $null }
          $raw = $k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
          if ($null -eq $raw) { return '' }
          return [string]$raw
        } finally { $k.Close() }
      } catch {
        return [Environment]::GetEnvironmentVariable($Name, 'Machine')
      }
    }
    SetUserEntry = {
      param(
        [string]$Name,
        [AllowNull()][object]$Value,
        [string]$Kind = 'String'
      )
      # [object] 才能区分 $null（删除名）与 ''（空字符串）；[string] 会把 $null 收成 ''
      $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
      if (-not $k) { throw '无法打开 HKCU\Environment 进行写入' }
      try {
        if ($null -eq $Value) {
          if ($k.GetValueNames() -contains $Name) {
            $k.DeleteValue($Name, $false)
          }
        } else {
          $rk = [Microsoft.Win32.RegistryValueKind]::String
          if ($Kind -eq 'ExpandString') { $rk = [Microsoft.Win32.RegistryValueKind]::ExpandString }
          $k.SetValue($Name, [string]$Value, $rk)
        }
      } finally { $k.Close() }
    }
    ListUserNames = {
      $names = New-Object System.Collections.Generic.List[string]
      try {
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
        if ($k) {
          try {
            foreach ($n in $k.GetValueNames()) { if ($n) { [void]$names.Add([string]$n) } }
          } finally { $k.Close() }
        }
      } catch {}
      return $names
    }
  }
}

function Broadcast-CslEnvironmentChange {
  try {
    if (-not ('CslNative.Win32' -as [type])) {
      Add-Type -Namespace CslNative -Name Win32 -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(
  IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
  uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
"@
    }
    $HWND_BROADCAST = [IntPtr]0xffff
    $WM_SETTINGCHANGE = 0x1A
    $SMTO_ABORTIFHUNG = 0x0002
    $result = [UIntPtr]::Zero
    [void][CslNative.Win32]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero, 'Environment', $SMTO_ABORTIFHUNG, 5000, [ref]$result)
  } catch {}
}

function Get-CslFixVarPatterns {
  param($Cfg, [string[]]$FixVarPattern)
  if ($FixVarPattern -and $FixVarPattern.Count -gt 0) {
    return @($FixVarPattern | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
  }
  if ($Cfg -and $Cfg.PSObject.Properties['fixVarPatterns'] -and $Cfg.fixVarPatterns) {
    $p = @($Cfg.fixVarPatterns | ForEach-Object { [string]$_ } | Where-Object { $_ })
    if ($p.Count -gt 0) { return $p }
  }
  return @($script:CslDefaultFixVars)
}

function Test-CslPatternsAllowed {
  param([string[]]$Patterns, [switch]$TestMode)
  foreach ($p in $Patterns) {
    if ($TestMode) {
      continue
    } else {
      if ($p -like '*CSL_TEST_*' -or $p -eq 'CSL_TEST_*' -or $p -match '(?i)CSL_TEST_') {
        return @{ ok = $false; error = "非 TestMode 下禁止配置含 CSL_TEST_ 的模式: $p" }
      }
    }
  }
  return @{ ok = $true }
}

function Test-CslVarNameAllowed {
  param([string]$Name, [switch]$TestMode)
  if (-not $Name) { return $false }
  if ($TestMode) {
    return $Name.StartsWith('CSL_TEST_')
  }
  return -not $Name.StartsWith('CSL_TEST_')
}

function Test-CslNameMatchesPatterns {
  param([string]$Name, [string[]]$Patterns)
  foreach ($p in $Patterns) {
    if ($Name -like $p) { return $true }
  }
  return $false
}

function Find-CslRelayEnvTargets {
  param([string[]]$Patterns, [switch]$TestMode, $Store)
  if (-not $Store) { $Store = Get-CslDefaultEnvStore }
  $patCheck = Test-CslPatternsAllowed -Patterns $Patterns -TestMode:$TestMode
  if (-not $patCheck.ok) {
    return @{ ok = $false; error = $patCheck.error; user = @(); machineOnly = @() }
  }
  $userHits = @()
  $machineOnly = @()
  $seen = @{}
  $names = @(& $Store.ListUserNames)
  foreach ($p in $Patterns) {
    if ($p -notmatch '[\*\?]' ) { $names += $p }
  }
  $names = @($names | Select-Object -Unique)
  foreach ($n in $names) {
    if (-not (Test-CslNameMatchesPatterns -Name $n -Patterns $Patterns)) { continue }
    if (-not (Test-CslVarNameAllowed -Name $n -TestMode:$TestMode)) {
      if ($TestMode) {
        return @{ ok = $false; error = "TestMode 拒绝非 CSL_TEST_ 变量: $n"; user = @(); machineOnly = @() }
      }
      continue
    }
    if ($seen.ContainsKey($n)) { continue }
    $seen[$n] = $true
    $entry = & $Store.GetUserEntry $n
    $mv = $null
    try { $mv = & $Store.GetMachine $n } catch {}
    if ($null -ne $entry) {
      # 存在（值可为 ''）
      $kind = 'String'
      if ($entry.Kind) { $kind = [string]$entry.Kind }
      $userHits += [pscustomobject]@{
        Name = $n
        Value = [string]$entry.Value
        Kind = $kind
        Scope = 'User'
      }
    } elseif ($null -ne $mv) {
      $machineOnly += [pscustomobject]@{ Name = $n; Scope = 'Machine' }
    }
  }
  return @{ ok = $true; user = $userHits; machineOnly = $machineOnly }
}

function Read-CslEnvBackupFile {
  param([string]$Path, [switch]$Strict)
  if (-not (Test-Path -LiteralPath $Path)) {
    if ($Strict) { return @{ ok = $false; error = "备份文件不存在: $Path" } }
    return @{ ok = $false; error = 'not found' }
  }
  try {
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
      return @{ ok = $false; error = "备份文件损坏或无法解析: $Path" }
    }
    $j = $raw | ConvertFrom-Json
    if (-not $j -or -not $j.id) {
      return @{ ok = $false; error = "备份文件损坏或无法解析: $Path" }
    }
    return @{ ok = $true; data = $j; path = $Path }
  } catch {
    return @{ ok = $false; error = "备份文件损坏或无法解析: $Path ($_)" }
  }
}

function Get-CslEarliestMap {
  # name -> @{ existed; before; kind }
  $dir = Get-CslEnvBackupDir
  $map = @{}
  $files = @(Get-ChildItem -LiteralPath $dir -Filter 'envfix-*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
  foreach ($f in $files) {
    $rd = Read-CslEnvBackupFile -Path $f.FullName
    if (-not $rd.ok) { continue }
    $j = $rd.data
    if ($j.undone) { continue }
    foreach ($e in @($j.entries)) {
      $n = [string]$e.name
      if (-not $map.ContainsKey($n)) {
        $ex = $true
        if ($e.PSObject.Properties['earliestExisted']) { $ex = [bool]$e.earliestExisted }
        elseif ($e.PSObject.Properties['existed']) { $ex = [bool]$e.existed }
        $bf = $null
        if ($e.PSObject.Properties['earliestBefore']) { $bf = $e.earliestBefore }
        else { $bf = $e.before }
        $kd = 'String'
        if ($e.PSObject.Properties['earliestKind'] -and $e.earliestKind) { $kd = [string]$e.earliestKind }
        elseif ($e.PSObject.Properties['kind'] -and $e.kind) { $kd = [string]$e.kind }
        $map[$n] = @{ existed = $ex; before = $bf; kind = $kd }
      }
    }
  }
  return $map
}

function New-CslEnvFixId {
  $t = [datetime]::UtcNow.ToString('yyyyMMddTHHmmss')
  $r = -join ((48..57 + 97..102) | Get-Random -Count 4 | ForEach-Object { [char]$_ })
  return "$t-$r"
}

function Write-CslEnvBackup($obj) {
  $dir = Get-CslEnvBackupDir
  $path = Join-Path $dir ("envfix-{0}.json" -f $obj.id)
  $json = $obj | ConvertTo-Json -Depth 6
  [IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))
  $all = @(Get-ChildItem -LiteralPath $dir -Filter 'envfix-*.json' -File | Sort-Object Name -Descending)
  $undoable = @()
  $undone = @()
  foreach ($f in $all) {
    $rd = Read-CslEnvBackupFile -Path $f.FullName
    if (-not $rd.ok) { $undone += $f; continue }
    if ($rd.data.undone) { $undone += $f } else { $undoable += $f }
  }
  if ($undoable.Count -gt $script:CslEnvBackupKeep) {
    foreach ($old in $undoable[$script:CslEnvBackupKeep..($undoable.Count - 1)]) {
      Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
    }
  }
  if ($undone.Count -gt $script:CslEnvBackupKeep) {
    foreach ($old in $undone[$script:CslEnvBackupKeep..($undone.Count - 1)]) {
      Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
    }
  }
  return $path
}

function Remove-CslEnvBackupById([string]$Id) {
  if (-not $Id) { return }
  $dir = Get-CslEnvBackupDir
  $p = Join-Path $dir ("envfix-{0}.json" -f $Id)
  if (Test-Path -LiteralPath $p) {
    Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
  }
}

function Get-CslEnvBackupById {
  param([string]$Id, [switch]$Strict)
  $dir = Get-CslEnvBackupDir
  if ($Id) {
    $p = Join-Path $dir ("envfix-{0}.json" -f $Id)
    if (-not (Test-Path -LiteralPath $p)) {
      $hit = Get-ChildItem -LiteralPath $dir -Filter ("envfix-{0}*.json" -f $Id) -File -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($hit) { $p = $hit.FullName }
      else {
        if ($Strict) { return @{ ok = $false; error = "没有可撤销的备份: $Id" } }
        return $null
      }
    }
    $rd = Read-CslEnvBackupFile -Path $p -Strict
    if (-not $rd.ok) {
      if ($Strict) { return $rd }
      return $null
    }
    if ($Strict) { return @{ ok = $true; data = $rd.data; path = $rd.path } }
    return $rd.data
  }
  $files = @(Get-ChildItem -LiteralPath $dir -Filter 'envfix-*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
  foreach ($f in $files) {
    $rd = Read-CslEnvBackupFile -Path $f.FullName -Strict
    if (-not $rd.ok) {
      if ($Strict) { return $rd }
      continue
    }
    if (-not $rd.data.undone) {
      if ($Strict) { return @{ ok = $true; data = $rd.data; path = $rd.path } }
      return $rd.data
    }
  }
  if ($Strict) { return @{ ok = $false; error = '没有可撤销的备份' } }
  return $null
}

function Get-CslEnvFixList {
  $dir = Get-CslEnvBackupDir
  $out = @()
  foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'envfix-*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
    $rd = Read-CslEnvBackupFile -Path $f.FullName
    if (-not $rd.ok) {
      $out += [pscustomobject]@{ id = $f.BaseName; ts = ''; undone = $true; corrupt = $true; error = $rd.error; vars = @() }
      continue
    }
    $j = $rd.data
    $vars = @($j.entries | ForEach-Object {
      $mask = if ($_.existed) { Protect-Secret ([string]$_.before) } else { '(不存在)' }
      [pscustomobject]@{
        name = $_.name
        beforeMasked = $mask
        after = $(if ($null -eq $_.after) { '(删除)' } else { Protect-Secret ([string]$_.after) })
        kind = $(if ($_.kind) { $_.kind } else { 'String' })
      }
    })
    $out += [pscustomobject]@{
      id = $j.id; ts = $j.ts; undone = [bool]$j.undone; testMode = [bool]$j.testMode; corrupt = $false
      vars = $vars
    }
  }
  return $out
}

function Invoke-CslEnvFix {
  param(
    [string[]]$Patterns,
    [switch]$TestMode,
    [switch]$DryRun,
    [int]$FailAtIndex = 0,
    $Store,
    [switch]$PassThru
  )
  if (-not $Store) { $Store = Get-CslDefaultEnvStore }

  $failIdx = 0
  if ($FailAtIndex -gt 0) {
    if ($TestMode) {
      $failIdx = $FailAtIndex
    } else {
      Write-Warning '-FailAtIndex 仅在 -TestMode 下生效，已忽略'
    }
  }

  $found = Find-CslRelayEnvTargets -Patterns $Patterns -TestMode:$TestMode -Store $Store
  if (-not $found.ok) {
    return @{ ok = $false; error = $found.error; exitCode = 2 }
  }
  foreach ($u in $found.user) {
    if (-not (Test-CslVarNameAllowed -Name $u.Name -TestMode:$TestMode)) {
      return @{ ok = $false; error = "变量名未通过 TestMode 守卫: $($u.Name)"; exitCode = 2 }
    }
  }
  $plan = @()
  foreach ($u in $found.user) {
    $plan += [pscustomobject]@{
      name = $u.Name
      scope = 'User'
      action = 'remove'
      valueMasked = Protect-Secret $u.Value
      kind = $u.Kind
    }
  }
  foreach ($m in $found.machineOnly) {
    $plan += [pscustomobject]@{
      name = $m.Name
      scope = 'Machine'
      action = 'skip-admin'
      valueMasked = ''
      note = '需要管理员手动处理'
    }
  }
  if ($DryRun) {
    return @{ ok = $true; dryRun = $true; plan = $plan; applied = @(); id = $null; exitCode = 0; hint = 'DryRun：未修改系统' }
  }
  if ($found.user.Count -eq 0) {
    return @{ ok = $true; dryRun = $false; plan = $plan; applied = @(); id = $null; message = '没有可清除的用户级变量'; exitCode = 0; hint = '' }
  }

  $earliest = Get-CslEarliestMap
  $entries = @()
  foreach ($u in $found.user) {
    $ex0 = $true
    $bf0 = $u.Value
    $kd0 = $u.Kind
    if ($earliest.ContainsKey($u.Name)) {
      $ex0 = [bool]$earliest[$u.Name].existed
      $bf0 = $earliest[$u.Name].before
      if ($earliest[$u.Name].kind) { $kd0 = $earliest[$u.Name].kind }
    }
    $entries += [pscustomobject]@{
      name = $u.Name
      existed = $true
      before = $u.Value
      kind = $u.Kind
      after = $null
      earliestExisted = $ex0
      earliestBefore = $bf0
      earliestKind = $kd0
    }
  }

  $id = New-CslEnvFixId
  $backupObj = [pscustomobject]@{
    id = $id
    ts = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    testMode = [bool]$TestMode
    undone = $false
    entries = $entries
  }
  $backupPath = Write-CslEnvBackup $backupObj

  $applied = @()
  $doneNames = @()
  $idx = 0
  try {
    foreach ($e in $entries) {
      $idx++
      if ($failIdx -gt 0 -and $idx -eq $failIdx) {
        throw "FailAtIndex=$failIdx 模拟失败（变量 $($e.name)）"
      }
      & $Store.SetUserEntry -Name $e.name -Value $null
      $doneNames += $e.name
      $applied += [pscustomobject]@{ name = $e.name; valueMasked = Protect-Secret $e.before; action = 'removed'; kind = $e.kind }
    }
    Broadcast-CslEnvironmentChange
  } catch {
    # 整单回滚到操作前，并删除未提交的备份（不留下可撤销条目）
    foreach ($e in $entries) {
      if ($doneNames -contains $e.name) {
        if ($e.existed) {
          & $Store.SetUserEntry -Name $e.name -Value $e.before -Kind $(if ($e.kind) { $e.kind } else { 'String' })
        }
      }
    }
    Broadcast-CslEnvironmentChange
    Remove-CslEnvBackupById $id
    return @{ ok = $false; error = "修复失败已回滚: $_"; exitCode = 1; id = $null; rolledBack = $true }
  }
  return @{ ok = $true; dryRun = $false; plan = $plan; applied = $applied; id = $id; exitCode = 0; hint = '新开的终端才会生效' }
}

function Invoke-CslEnvUndo {
  param(
    [string]$Id,
    [switch]$NoPause,
    [switch]$ForceSkipConflicts,
    [int]$FailAtIndex = 0,
    [switch]$TestMode,
    $Store,
    [scriptblock]$OnConflict
  )
  if (-not $Store) { $Store = Get-CslDefaultEnvStore }

  $failIdx = 0
  if ($FailAtIndex -gt 0) {
    if ($TestMode) {
      $failIdx = $FailAtIndex
    } else {
      Write-Warning '-FailAtIndex 仅在 -TestMode 下生效，已忽略'
    }
  }

  $got = Get-CslEnvBackupById -Id $Id -Strict
  if (-not $got.ok) {
    return @{ ok = $false; error = $got.error; exitCode = 1 }
  }
  $bak = $got.data
  if ($bak.undone) {
    return @{
      ok = $true
      alreadyUndone = $true
      id = $bak.id
      message = 'already undone'
      restored = @()
      skipped = @()
      conflicts = @()
      exitCode = 0
      hint = ''
    }
  }

  $conflicts = @()
  $restored = @()
  $skipped = @()
  $opsToMark = @{}
  $dir = Get-CslEnvBackupDir

  $targetNames = New-Object System.Collections.Generic.HashSet[string]
  foreach ($e in @($bak.entries)) { [void]$targetNames.Add([string]$e.name) }

  # 扫描连通备份；相关文件若损坏则整单中止、不改系统（无关损坏文件跳过）
  $changed = $true
  while ($changed) {
    $changed = $false
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'envfix-*.json' -File -ErrorAction SilentlyContinue)) {
      $rd = Read-CslEnvBackupFile -Path $f.FullName
      if (-not $rd.ok) { continue }
      $j = $rd.data
      if ($j.undone) { continue }
      $hit = $false
      foreach ($e in @($j.entries)) {
        if ($targetNames.Contains([string]$e.name)) { $hit = $true; break }
      }
      if ($hit) {
        # 再次严格校验：相关备份必须可解析
        $rd2 = Read-CslEnvBackupFile -Path $f.FullName -Strict
        if (-not $rd2.ok) {
          return @{ ok = $false; error = $rd2.error; exitCode = 1 }
        }
        if (-not $opsToMark.ContainsKey($j.id)) {
          $opsToMark[$j.id] = $f.FullName
          $changed = $true
        }
        foreach ($e in @($j.entries)) { [void]$targetNames.Add([string]$e.name) }
      }
    }
  }
  $opsToMark[$bak.id] = $got.path

  $latestAfter = @{}
  $latestAfterKind = @{}
  foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'envfix-*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $rd = Read-CslEnvBackupFile -Path $f.FullName
    if (-not $rd.ok) { continue }
    $j = $rd.data
    if ($j.undone) { continue }
    if (-not $opsToMark.ContainsKey($j.id)) { continue }
    foreach ($e in @($j.entries)) {
      $nm = [string]$e.name
      if (-not $targetNames.Contains($nm)) { continue }
      # after: $null = 删除；'' = 空字符串（若将来支持写入）
      if ($e.PSObject.Properties.Name -contains 'after') {
        $latestAfter[$nm] = $e.after
      } else {
        $latestAfter[$nm] = $null
      }
      if ($e.kind) { $latestAfterKind[$nm] = [string]$e.kind }
    }
  }

  $earliest = Get-CslEarliestMap
  $pending = @()
  foreach ($name in @($targetNames)) {
    if (-not $earliest.ContainsKey($name)) { continue }
    $wantExisted = [bool]$earliest[$name].existed
    $wantVal = $earliest[$name].before
    $wantKind = 'String'
    if ($earliest[$name].kind) { $wantKind = $earliest[$name].kind }

    $curEntry = & $Store.GetUserEntry $name
    $curAbsent = ($null -eq $curEntry)
    $expectAbsent = $true
    $expectAfter = $null
    if ($latestAfter.ContainsKey($name)) {
      $expectAfter = $latestAfter[$name]
      # JSON null -> $null；区分空字符串
      $expectAbsent = ($null -eq $expectAfter)
    }

    $conflict = $false
    if ($expectAbsent) {
      if (-not $curAbsent) { $conflict = $true }
    } else {
      if ($curAbsent) { $conflict = $true }
      elseif ([string]$curEntry.Value -ne [string]$expectAfter) { $conflict = $true }
    }

    if ($conflict) {
      $curShow = if ($curAbsent) { '(不存在)' } else { Protect-Secret $curEntry.Value }
      $expShow = if ($expectAbsent) { '(删除)' } else { Protect-Secret ([string]$expectAfter) }
      $msg = "冲突: $name 当前值与修复后不一致（当前=$curShow，期望修复后=$expShow）"
      $decision = 'skip'
      if ($OnConflict) {
        $decision = & $OnConflict $name $curShow $expShow
      } elseif ($NoPause -or $ForceSkipConflicts) {
        $decision = 'skip'
      } else {
        try {
          $ans = Read-Host "  $msg  跳过该变量？(Y 跳过 / N 中止撤销)"
          if ($ans -match '^[nN]') { $decision = 'abort' } else { $decision = 'skip' }
        } catch { $decision = 'skip' }
      }
      if ($decision -eq 'abort') {
        return @{ ok = $false; error = '用户中止撤销'; conflicts = @($conflicts + $msg); exitCode = 1; partial = $restored }
      }
      $conflicts += $msg
      $skipped += $name
      continue
    }

    $pending += [pscustomobject]@{
      name = $name
      wantExisted = $wantExisted
      wantVal = $wantVal
      wantKind = $wantKind
    }
  }

  # 应用前已确认无损坏文件；开始写入，FailAtIndex 可注入失败并回滚本轮写入
  $done = @()
  $idx = 0
  $snapshot = @{}
  try {
    foreach ($p in $pending) {
      $idx++
      $prev = & $Store.GetUserEntry $p.name
      $snapshot[$p.name] = $prev
      if ($failIdx -gt 0 -and $idx -eq $failIdx) {
        throw "FailAtIndex=$failIdx 模拟失败（撤销变量 $($p.name)）"
      }
      if ($p.wantExisted) {
        # 允许恢复空字符串
        & $Store.SetUserEntry -Name $p.name -Value $p.wantVal -Kind $p.wantKind
      } else {
        & $Store.SetUserEntry -Name $p.name -Value $null
      }
      $done += $p.name
      $restored += [pscustomobject]@{
        name = $p.name
        valueMasked = $(if ($p.wantExisted) { Protect-Secret $p.wantVal } else { '(删除)' })
        kind = $p.wantKind
      }
    }
    Broadcast-CslEnvironmentChange
  } catch {
    foreach ($name in $done) {
      $prev = $snapshot[$name]
      if ($null -eq $prev) {
        & $Store.SetUserEntry -Name $name -Value $null
      } else {
        & $Store.SetUserEntry -Name $name -Value $prev.Value -Kind $(if ($prev.Kind) { $prev.Kind } else { 'String' })
      }
    }
    Broadcast-CslEnvironmentChange
    return @{ ok = $false; error = "撤销失败已回滚: $_"; exitCode = 1; rolledBack = $true }
  }

  foreach ($kv in $opsToMark.GetEnumerator()) {
    try {
      $p = $kv.Value
      if (-not (Test-Path -LiteralPath $p)) {
        $p = Join-Path $dir ("envfix-{0}.json" -f $kv.Key)
      }
      if (Test-Path -LiteralPath $p) {
        $rd = Read-CslEnvBackupFile -Path $p -Strict
        if (-not $rd.ok) {
          return @{ ok = $false; error = $rd.error; exitCode = 1 }
        }
        $j = $rd.data
        $j.undone = $true
        [IO.File]::WriteAllText($p, ($j | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
      }
    } catch {
      return @{ ok = $false; error = "标记备份失败: $_"; exitCode = 1 }
    }
  }

  $code = 0
  if ($conflicts.Count -gt 0) { $code = 3 }
  return @{
    ok = ($conflicts.Count -eq 0)
    id = $bak.id
    restored = $restored
    skipped = $skipped
    conflicts = $conflicts
    exitCode = $code
    hint = '新开的终端才会生效'
  }
}

} # end guard
