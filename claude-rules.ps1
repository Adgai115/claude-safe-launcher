# Claude Safe Launcher — rules load + single scoring (v4.0.0)
# Dot-source after claude-common.ps1. Do not redefine Mask-Value / Protect-Secret.

# 不在脚本作用域设置 StrictMode：本文件会被 dot-source 进 preflight，严格模式会泄漏到调用方
# （claude-common.ps1 的 Load-Config 等会抛 PropertyNotFoundStrict）。

# Captured at dot-source time (MyInvocation inside functions points at the caller).
$script:CslRulesDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Get-CslRulesPath {
  $here = $script:CslRulesDir
  if (-not $here) { $here = Split-Path -Parent $PSCommandPath }
  Join-Path $here 'rules\checks.json'
}

function Get-CslRulesCatalog {
  param([string]$Path)
  if (-not $Path) { $Path = Get-CslRulesPath }
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "rules catalog not found: $Path"
  }
  $raw = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
  $obj = $raw | ConvertFrom-Json
  return $obj
}

function Get-CslRuleById {
  param(
    [Parameter(Mandatory)]$Catalog,
    [Parameter(Mandatory)][string]$Id
  )
  foreach ($c in @($Catalog.checks)) {
    if ([string]$c.id -eq $Id) { return $c }
  }
  return $null
}

function Get-CslPsProp {
  param($Object, [string]$Name)
  if ($null -eq $Object) { return $null }
  $p = $Object.PSObject.Properties[$Name]
  if ($null -eq $p) { return $null }
  return $p.Value
}

function Resolve-CslFixType {
  param($Rule, $Result)
  $ov = Get-CslPsProp $Result 'fixTypeOverride'
  if ($null -ne $ov -and [string]$ov -ne '') { return [string]$ov }
  if ($Rule) {
    $ft = Get-CslPsProp $Rule 'fixType'
    if ($null -ne $ft -and [string]$ft -ne '') { return [string]$ft }
  }
  return 'none'
}

function Resolve-CslFixId {
  param($Rule, $Result, [string]$FixType)
  $ov = Get-CslPsProp $Result 'fixIdOverride'
  if ($null -ne $ov -and [string]$ov -ne '') { return [string]$ov }
  if ($FixType -ne 'confirm') { return $null }
  if ($Rule) {
    $fid = Get-CslPsProp $Rule 'fixId'
    if ($null -ne $fid -and [string]$fid -ne '') { return [string]$fid }
  }
  return $null
}

<#
.SYNOPSIS
  Single scoring entry used by CLI and panel.

.PARAMETER Results
  Array of hashtables / PSCustomObjects:
    id, status (passed|failed|error|info|skipped), [severityOverride], [refDeductionOverride],
    current, expected, recheck, [masked], [fixTypeOverride], [fixIdOverride], [notes]

  status=failed applies rule refDeduction (unless override / cap / hint-only).
  status=error → 0 deduction; if severity is must_fix, blocks canLaunchSafely.
  status=info|passed|skipped → 0 deduction for that row.

.OUTPUTS
  PSCustomObject with score, canLaunchSafely, summary (incl. error), checks (enriched), browserCap
#>
function Get-CslRulesScore {
  param(
    [Parameter(Mandatory)]$Catalog,
    [Parameter(Mandatory)]$Results
  )

  $cap = 20
  try { if ($null -ne $Catalog.scoring.staticBrowserCap) { $cap = [int]$Catalog.scoring.staticBrowserCap } } catch {}
  $staticIds = @()
  try { $staticIds = @($Catalog.scoring.staticBrowserCheckIds) | ForEach-Object { [string]$_ } } catch {}
  $staticSet = @{}
  foreach ($sid in $staticIds) { $staticSet[$sid] = $true }

  $enriched = New-Object System.Collections.Generic.List[object]
  $staticWarnPending = New-Object System.Collections.Generic.List[object]
  $mustFailed = 0
  $shouldFailed = 0
  $infoCount = 0
  $passedCount = 0
  $errorCount = 0
  $mustError = 0

  foreach ($r in @($Results)) {
    $id = [string]$r.id
    $rule = Get-CslRuleById -Catalog $Catalog -Id $id
    $status = [string]$r.status
    if (-not $status) { $status = 'info' }

    $sev = $null
    $sevOv = Get-CslPsProp $r 'severityOverride'
    if ($sevOv) { $sev = [string]$sevOv }
    elseif ($rule) { $sev = [string]$rule.severity }
    else { $sev = 'info' }

    $ref = 0
    $refOv = Get-CslPsProp $r 'refDeductionOverride'
    if ($null -ne $refOv) { $ref = [int]$refOv }
    elseif ($rule -and $null -ne (Get-CslPsProp $rule 'refDeduction')) { $ref = [int]$rule.refDeduction }

    $title = $(if ($rule) { [string]$rule.title } else { $id })
    $category = $(if ($rule) { [string]$rule.category } else { '' })
    $expIn = Get-CslPsProp $r 'expected'
    $expected = $(if ($null -ne $expIn -and [string]$expIn -ne '') { [string]$expIn } elseif ($rule) { [string](Get-CslPsProp $rule 'expected') } else { '' })
    $curIn = Get-CslPsProp $r 'current'
    $current = $(if ($null -ne $curIn) { [string]$curIn } else { '' })
    $recIn = Get-CslPsProp $r 'recheck'
    $recheckWin = $(if ($rule) { Get-CslPsProp $rule 'recheckWin' } else { $null })
    $recheck = $(if ($null -ne $recIn) { [string]$recIn } elseif ($null -ne $recheckWin) { [string]$recheckWin } else { '' })

    $fixType = Resolve-CslFixType -Rule $rule -Result $r
    $fixId = Resolve-CslFixId -Rule $rule -Result $r -FixType $fixType

    $containsIp = $false
    $cipOv = Get-CslPsProp $r 'containsIpOverride'
    if ($null -ne $cipOv) { $containsIp = [bool]$cipOv }
    elseif ($rule) {
      $cip = Get-CslPsProp $rule 'containsIp'
      if ($null -ne $cip) { $containsIp = [bool]$cip }
    }

    $masked = $true
    $maskIn = Get-CslPsProp $r 'masked'
    if ($null -ne $maskIn) { $masked = [bool]$maskIn }

    $row = [ordered]@{
      id                   = $id
      category             = $category
      title                = $title
      severity             = $sev
      status               = $status
      current              = $current
      expected             = $expected
      recheck              = $recheck
      fixType              = $fixType
      fixId                = $fixId
      containsIp           = [bool]$containsIp
      masked               = $masked
      refDeductionRule     = $ref
      refDeductionApplied  = 0
      isStaticBrowser      = [bool]$staticSet.ContainsKey($id)
    }
    # optional per-row note (e.g. why an item could not be mapped); only present when the caller supplies one
    $notesIn = Get-CslPsProp $r 'notes'
    if ($null -ne $notesIn -and [string]$notesIn -ne '') { $row['notes'] = [string]$notesIn }

    if ($status -eq 'passed') {
      $passedCount++
      $enriched.Add([pscustomobject]$row) | Out-Null
    } elseif ($status -eq 'error') {
      # Incomplete check: never deduct; must_fix error still blocks launch
      $errorCount++
      if ($sev -eq 'must_fix') { $mustError++ }
      $row.refDeductionApplied = 0
      $enriched.Add([pscustomobject]$row) | Out-Null
    } elseif ($status -eq 'skipped') {
      $infoCount++
      $enriched.Add([pscustomobject]$row) | Out-Null
    } elseif ($status -eq 'info') {
      $infoCount++
      $enriched.Add([pscustomobject]$row) | Out-Null
    } elseif ($status -eq 'failed') {
      if ($sev -eq 'must_fix') { $mustFailed++ }
      elseif ($sev -eq 'should_fix') { $shouldFailed++ }
      else { $infoCount++ }

      if ($sev -eq 'info' -or $ref -le 0) {
        $row.refDeductionApplied = 0
        $enriched.Add([pscustomobject]$row) | Out-Null
      } elseif ($row.isStaticBrowser -and $sev -eq 'should_fix') {
        $staticWarnPending.Add([pscustomobject]$row) | Out-Null
      } else {
        $row.refDeductionApplied = $ref
        $enriched.Add([pscustomobject]$row) | Out-Null
      }
    } else {
      $infoCount++
      $enriched.Add([pscustomobject]$row) | Out-Null
    }
  }

  $staticBefore = 0
  foreach ($s in $staticWarnPending) { $staticBefore += [int]$s.refDeductionRule }
  $staticAfter = [Math]::Min($staticBefore, $cap)
  $remaining = $staticAfter
  foreach ($s in $staticWarnPending) {
    $want = [int]$s.refDeductionRule
    if ($remaining -ge $want) {
      $s.refDeductionApplied = $want
      $remaining -= $want
    } elseif ($remaining -gt 0) {
      $s.refDeductionApplied = $remaining
      $remaining = 0
    } else {
      $s.refDeductionApplied = 0
      $s.severity = 'info'
      if ($shouldFailed -gt 0) { $shouldFailed--; $infoCount++ }
    }
    $enriched.Add($s) | Out-Null
  }

  $sumDeduction = 0
  foreach ($e in $enriched) { $sumDeduction += [int]$e.refDeductionApplied }
  $score = [Math]::Max(0, 100 - $sumDeduction)
  $canLaunch = (($mustFailed -eq 0) -and ($mustError -eq 0))

  return [pscustomobject]@{
    schemaVersion    = 1
    rulesVersion     = $(if ($Catalog.rulesVersion) { [string]$Catalog.rulesVersion } else { '4.0.0' })
    score            = [int]$score
    scoreMode        = 'reference_only'
    canLaunchSafely  = [bool]$canLaunch
    summary          = [pscustomobject]@{
      must_fix_failed   = $mustFailed
      should_fix_failed = $shouldFailed
      info             = $infoCount
      passed           = $passedCount
      error            = $errorCount
    }
    checks           = @($enriched.ToArray())
    browserCap       = [pscustomobject]@{
      staticWarnSumBeforeCap = $staticBefore
      staticWarnSumAfterCap  = $staticAfter
      cap                    = $cap
    }
  }
}

function New-CslPreflightResult {
  param(
    [Parameter(Mandatory)]$ScoreResult,
    [string]$Platform = 'win',
    [string]$Verdict = '',
    [datetime]$GeneratedAt = [datetime]::UtcNow
  )
  if (-not $Verdict) {
    if ($ScoreResult.canLaunchSafely) { $Verdict = 'ok' } else { $Verdict = 'blocked' }
  }
  return [pscustomobject]@{
    schemaVersion   = 1
    rulesVersion    = $ScoreResult.rulesVersion
    generatedAt     = $GeneratedAt.ToString('o')
    platform        = $Platform
    score           = [int]$ScoreResult.score
    scoreMode       = $ScoreResult.scoreMode
    canLaunchSafely = [bool]$ScoreResult.canLaunchSafely
    verdict         = $Verdict
    summary         = $ScoreResult.summary
    checks          = $ScoreResult.checks
    browserCap      = $ScoreResult.browserCap
  }
}

function Write-CslPreflightResultJson {
  param(
    [Parameter(Mandatory)]$Result,
    [Parameter(Mandatory)][string]$Path
  )
  $json = $Result | ConvertTo-Json -Depth 8
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($Path, $json + "`n", $utf8NoBom)
  return $Path
}

# R4a: preflight-result.json 只在 -Json 时写；-JsonPath 指定文件（目录必须已存在，不自动创建）；只给 -JsonPath 不给 -Json 报错
function Resolve-CslPreflightJsonPath {
  param(
    [switch]$Json,
    [AllowNull()][string]$JsonPath,
    [Parameter(Mandatory)][string]$Root
  )
  if (-not $Json) {
    if (-not [string]::IsNullOrWhiteSpace($JsonPath)) { throw "-JsonPath 需要配合 -Json 使用（未写任何文件）" }
    return $null
  }
  if ([string]::IsNullOrWhiteSpace($JsonPath)) { return (Join-Path $Root 'preflight-result.json') }
  $full = [System.IO.Path]::GetFullPath($JsonPath)
  if (Test-Path -LiteralPath $full -PathType Container) { throw "-JsonPath 指向的是目录，请给出文件路径" }
  $dir = Split-Path -Parent $full
  if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir -PathType Container)) { throw "-JsonPath 的目标目录不存在（不会自动创建）" }
  return $full
}

function Save-CslPreflightResultJson {
  param(
    [Parameter(Mandatory)]$Result,
    [switch]$Json,
    [AllowNull()][string]$JsonPath,
    [Parameter(Mandatory)][string]$Root
  )
  $target = Resolve-CslPreflightJsonPath -Json:$Json -JsonPath $JsonPath -Root $Root
  if (-not $target) { return $null }
  return (Write-CslPreflightResultJson -Result $Result -Path $target)
}
