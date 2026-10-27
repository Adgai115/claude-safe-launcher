# Claude Safe Launcher — rules load + single scoring (v4.0.0)
# Dot-source after claude-common.ps1. Do not redefine Mask-Value / Protect-Secret.

Set-StrictMode -Version Latest

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

<#
.SYNOPSIS
  Single scoring entry used by CLI and panel.

.PARAMETER Results
  Array of hashtables / PSCustomObjects:
    id, status (passed|failed|info|skipped), [severityOverride], [refDeductionOverride],
    current, expected, recheck, [masked]

  status=failed applies rule refDeduction (unless override / cap / hint-only).
  status=info|passed|skipped → 0 deduction for that row.

.OUTPUTS
  PSCustomObject with score, canLaunchSafely, summary, checks (enriched), browserCap
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
    $fixable = $false
    if ($rule) {
      $fv = Get-CslPsProp $rule 'fixable'
      if ($null -ne $fv) { $fixable = [bool]$fv }
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
      fixable              = $fixable
      masked               = $masked
      refDeductionRule     = $ref
      refDeductionApplied  = 0
      isStaticBrowser      = [bool]$staticSet.ContainsKey($id)
    }

    if ($status -eq 'passed') {
      $passedCount++
    } elseif ($status -eq 'skipped') {
      $infoCount++
    } elseif ($status -eq 'info') {
      $infoCount++
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
  # Apply cap in catalog order (already list order): full until remainder runs out; excess → info/0
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
      # demoted from should_fix failed → still counted in shouldFailed above; adjust
      if ($shouldFailed -gt 0) { $shouldFailed--; $infoCount++ }
    }
    $enriched.Add($s) | Out-Null
  }

  $sumDeduction = 0
  foreach ($e in $enriched) { $sumDeduction += [int]$e.refDeductionApplied }
  $score = [Math]::Max(0, 100 - $sumDeduction)
  $canLaunch = ($mustFailed -eq 0)

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
