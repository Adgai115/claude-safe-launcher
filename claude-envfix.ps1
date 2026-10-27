# Claude 安全启动 · 用户级环境变量一键修复 / 撤销（Windows）
# 由 claude-preflight.ps1 / claude-panel.ps1 dot-source。仅操作用户级（User / HKCU\Environment）。
# 备份含原始值，仅用于撤销；面板与日志必须走 Protect-Secret，禁止打印明文。

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
function Get-CslDefaultEnvStore {
  if ($script:CslEnvStore) { return $script:CslEnvStore }
  return [pscustomobject]@{
    GetUser = {
      param([string]$Name)
      return [Environment]::GetEnvironmentVariable($Name, 'User')
    }
    GetMachine = {
      param([string]$Name)
      return [Environment]::GetEnvironmentVariable($Name, 'Machine')
    }
    SetUser = {
      param([string]$Name, [AllowNull()][string]$Value)
      if ($null -eq $Value -or $Value -eq '') {
        [Environment]::SetEnvironmentVariable($Name, $null, 'User')
        Remove-ItemProperty -Path 'HKCU:\Environment' -Name $Name -ErrorAction SilentlyContinue
      } else {
        [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
      }
    }
    ListUserNames = {
      $names = New-Object System.Collections.Generic.List[string]
      try {
        $key = Get-Item -Path 'HKCU:\Environment' -ErrorAction Stop
        foreach ($n in $key.GetValueNames()) { if ($n) { [void]$names.Add([string]$n) } }
      } catch {}
      # also include process-known User vars via Environment API is incomplete; registry is source of truth
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
      # In TestMode patterns should target CSL_TEST_* ; still enforced per-name
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
  # Also probe exact default/pattern literals (wildcards need list; literals may exist even if List incomplete)
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
    $uv = & $Store.GetUser $n
    $mv = $null
    try { $mv = & $Store.GetMachine $n } catch {}
    if ($null -ne $uv -and $uv -ne '') {
      $userHits += [pscustomobject]@{ Name = $n; Value = [string]$uv; Scope = 'User' }
    } elseif ($null -ne $mv -and $mv -ne '') {
      $machineOnly += [pscustomobject]@{ Name = $n; Scope = 'Machine' }
    }
  }
  # TestMode: refuse if any matched name from patterns expansion would be non-CSL_TEST (already handled)
  return @{ ok = $true; user = $userHits; machineOnly = $machineOnly }
}

function Get-CslEarliestMap {
  # name -> @{ existed; before } from oldest non-undone backup
  $dir = Get-CslEnvBackupDir
  $map = @{}
  $files = @(Get-ChildItem -LiteralPath $dir -Filter 'envfix-*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
  foreach ($f in $files) {
    try {
      $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
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
          $map[$n] = @{ existed = $ex; before = $bf }
        }
      }
    } catch {}
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
  # 至少保留 N 条仍可撤销的备份；额外已撤销的审计记录可再留一些
  $all = @(Get-ChildItem -LiteralPath $dir -Filter 'envfix-*.json' -File | Sort-Object Name -Descending)
  $undoable = @()
  $undone = @()
  foreach ($f in $all) {
    try {
      $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($j.undone) { $undone += $f } else { $undoable += $f }
    } catch { $undone += $f }
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

function Get-CslEnvBackupById([string]$Id) {
  $dir = Get-CslEnvBackupDir
  if ($Id) {
    $p = Join-Path $dir ("envfix-{0}.json" -f $Id)
    if (-not (Test-Path -LiteralPath $p)) {
      $hit = Get-ChildItem -LiteralPath $dir -Filter ("envfix-{0}*.json" -f $Id) -File -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($hit) { $p = $hit.FullName } else { return $null }
    }
    try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
  }
  $files = @(Get-ChildItem -LiteralPath $dir -Filter 'envfix-*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
  foreach ($f in $files) {
    try {
      $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
      if (-not $j.undone) { return $j }
    } catch {}
  }
  return $null
}

function Get-CslEnvFixList {
  $dir = Get-CslEnvBackupDir
  $out = @()
  foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'envfix-*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
    try {
      $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
      $vars = @($j.entries | ForEach-Object {
        $mask = if ($_.existed) { Protect-Secret ([string]$_.before) } else { '(不存在)' }
        [pscustomobject]@{ name = $_.name; beforeMasked = $mask; after = $(if ($null -eq $_.after -or $_.after -eq '') { '(删除)' } else { Protect-Secret ([string]$_.after) }) }
      })
      $out += [pscustomobject]@{
        id = $j.id; ts = $j.ts; undone = [bool]$j.undone; testMode = [bool]$j.testMode
        vars = $vars
      }
    } catch {}
  }
  return @($out | Select-Object -First $script:CslEnvBackupKeep)
}

function Invoke-CslEnvFix {
  param(
    [string[]]$Patterns,
    [switch]$TestMode,
    [switch]$DryRun,
    $Store,
    [switch]$PassThru
  )
  if (-not $Store) { $Store = Get-CslDefaultEnvStore }
  $found = Find-CslRelayEnvTargets -Patterns $Patterns -TestMode:$TestMode -Store $Store
  if (-not $found.ok) {
    return @{ ok = $false; error = $found.error; exitCode = 2 }
  }
  # Extra guard: every user target must pass TestMode name check (abort whole op before backup)
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
    return @{ ok = $true; dryRun = $true; plan = $plan; applied = @(); id = $null; exitCode = 0 }
  }
  if ($found.user.Count -eq 0) {
    return @{ ok = $true; dryRun = $false; plan = $plan; applied = @(); id = $null; message = '没有可清除的用户级变量'; exitCode = 0 }
  }

  $earliest = Get-CslEarliestMap
  $entries = @()
  foreach ($u in $found.user) {
    $ex0 = $true
    $bf0 = $u.Value
    if ($earliest.ContainsKey($u.Name)) {
      $ex0 = [bool]$earliest[$u.Name].existed
      $bf0 = $earliest[$u.Name].before
    }
    $entries += [pscustomobject]@{
      name = $u.Name
      existed = $true
      before = $u.Value
      after = $null
      earliestExisted = $ex0
      earliestBefore = $bf0
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
  # Write backup BEFORE mutating
  [void](Write-CslEnvBackup $backupObj)

  $applied = @()
  $doneNames = @()
  try {
    foreach ($e in $entries) {
      & $Store.SetUser -Name $e.name -Value $null
      $doneNames += $e.name
      $applied += [pscustomobject]@{ name = $e.name; valueMasked = Protect-Secret $e.before; action = 'removed' }
    }
    Broadcast-CslEnvironmentChange
  } catch {
    # rollback whole operation
    foreach ($e in $entries) {
      if ($doneNames -contains $e.name) {
        if ($e.existed) { & $Store.SetUser -Name $e.name -Value $e.before }
      }
    }
    Broadcast-CslEnvironmentChange
    $backupObj.undone = $true
    $backupObj | Add-Member -NotePropertyName rollback -NotePropertyValue $true -Force
    [void](Write-CslEnvBackup $backupObj)
    return @{ ok = $false; error = "修复失败已回滚: $_"; exitCode = 1; id = $id }
  }
  return @{ ok = $true; dryRun = $false; plan = $plan; applied = $applied; id = $id; exitCode = 0; hint = '新开的终端才会生效' }
}

function Invoke-CslEnvUndo {
  param(
    [string]$Id,
    [switch]$NoPause,
    [switch]$ForceSkipConflicts,
    $Store,
    [scriptblock]$OnConflict  # optional; receives name, currentMasked, expectedMasked; returns 'skip'|'abort'|'overwrite' — we only use skip/abort for safety
  )
  if (-not $Store) { $Store = Get-CslDefaultEnvStore }
  $bak = Get-CslEnvBackupById -Id $Id
  if (-not $bak) { return @{ ok = $false; error = '没有可撤销的备份'; exitCode = 1 } }
  if ($bak.undone) { return @{ ok = $false; error = "备份 $($bak.id) 已撤销"; exitCode = 1 } }

  $conflicts = @()
  $restored = @()
  $skipped = @()
  $opsToMark = @{}

  # 连通：与本次备份共享变量名的所有未撤销操作一并处理；各变量恢复到链路 earliest
  $targetNames = New-Object System.Collections.Generic.HashSet[string]
  foreach ($e in @($bak.entries)) { [void]$targetNames.Add([string]$e.name) }
  $dir = Get-CslEnvBackupDir
  $changed = $true
  while ($changed) {
    $changed = $false
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'envfix-*.json' -File -ErrorAction SilentlyContinue)) {
      try {
        $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.undone) { continue }
        $hit = $false
        foreach ($e in @($j.entries)) {
          if ($targetNames.Contains([string]$e.name)) { $hit = $true; break }
        }
        if ($hit) {
          if (-not $opsToMark.ContainsKey($j.id)) {
            $opsToMark[$j.id] = $f.FullName
            $changed = $true
          }
          foreach ($e in @($j.entries)) { [void]$targetNames.Add([string]$e.name) }
        }
      } catch {}
    }
  }
  $opsToMark[$bak.id] = (Join-Path $dir ("envfix-{0}.json" -f $bak.id))

  # 每个变量的期望「修复后」状态：取最新未撤销操作中该变量的 after（我们写入的）
  $latestAfter = @{}
  foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'envfix-*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
    try {
      $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($j.undone) { continue }
      if (-not $opsToMark.ContainsKey($j.id)) { continue }
      foreach ($e in @($j.entries)) {
        $nm = [string]$e.name
        if (-not $targetNames.Contains($nm)) { continue }
        $latestAfter[$nm] = $e.after
      }
    } catch {}
  }

  $earliest = Get-CslEarliestMap

  foreach ($name in @($targetNames)) {
    $wantExisted = $true
    $wantVal = $null
    if ($earliest.ContainsKey($name)) {
      $wantExisted = [bool]$earliest[$name].existed
      $wantVal = $earliest[$name].before
    } else {
      continue
    }

    $cur = & $Store.GetUser $name
    $curAbsent = ($null -eq $cur -or $cur -eq '')
    $expectAfter = $null
    if ($latestAfter.ContainsKey($name)) { $expectAfter = $latestAfter[$name] }
    $expectAbsent = ($null -eq $expectAfter -or $expectAfter -eq '')
    $conflict = $false
    if ($expectAbsent) {
      if (-not $curAbsent) { $conflict = $true }
    } else {
      if ($curAbsent -or $cur -ne [string]$expectAfter) { $conflict = $true }
    }

    if ($conflict) {
      $msg = "冲突: $name 当前值与修复后不一致（当前=$(Protect-Secret $cur)，期望修复后=$(if($expectAbsent){'(删除)'}else{Protect-Secret ([string]$expectAfter)}))"
      $decision = 'skip'
      if ($OnConflict) {
        $decision = & $OnConflict $name (Protect-Secret $cur) $(if($expectAbsent){'(删除)'}else{Protect-Secret ([string]$expectAfter)})
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

    if ($wantExisted) { & $Store.SetUser -Name $name -Value $wantVal }
    else { & $Store.SetUser -Name $name -Value $null }
    $restored += [pscustomobject]@{ name = $name; valueMasked = $(if ($wantExisted) { Protect-Secret $wantVal } else { '(删除)' }) }
  }
  Broadcast-CslEnvironmentChange

  foreach ($kv in $opsToMark.GetEnumerator()) {
    try {
      $p = $kv.Value
      if (-not (Test-Path -LiteralPath $p)) {
        $p = Join-Path $dir ("envfix-{0}.json" -f $kv.Key)
      }
      if (Test-Path -LiteralPath $p) {
        $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        $j.undone = $true
        [IO.File]::WriteAllText($p, ($j | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
      }
    } catch {}
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
