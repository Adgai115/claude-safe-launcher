#Requires -Version 5.1
# 问题说明导出（v3.3.0）：脱敏 + 四段结构。不调用任何 agent。
# 被 claude-preflight.ps1 / 面板客户端逻辑共用约定；本文件供 CLI 与单元测试。

$script:CslIssueClosing = '请只给出建议，确认后再修改；不要修改 Claude Code 自身依赖的环境变量。'
$script:CslIssueIpNotice = '本说明包含你的出口 IP，粘贴前请确认'

function Test-CslLooksLikeSecretText {
  param([AllowNull()][string]$Value)
  if ([string]::IsNullOrEmpty($Value)) { return $false }
  $v = [string]$Value
  if ($v -match '(?i)(controllerSecret|X-CSL-Token|Authorization:\s*Bearer|api[_-]?key|auth[_-]?token|sk-[a-zA-Z0-9]{8,})') { return $true }
  if ($v -match '(?i)Bearer\s+[A-Za-z0-9\-_\.]{16,}') { return $true }
  return $false
}

function Test-CslPrivateOrFakeIp {
  param([string]$Ip)
  if (-not $Ip) { return $true }
  if ($Ip -match '^127\.') { return $true }
  if ($Ip -match '^10\.') { return $true }
  if ($Ip -match '^192\.168\.') { return $true }
  if ($Ip -match '^172\.(1[6-9]|2[0-9]|3[0-1])\.') { return $true }
  if ($Ip -match '^198\.18\.') { return $true }  # Clash fake-ip
  if ($Ip -match '^::1$') { return $true }
  if ($Ip -match '(?i)^fe80:') { return $true }
  return $false
}

function Test-CslTextContainsExitIp {
  param([AllowNull()][string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { return $false }
  $found = $false
  [regex]::Matches([string]$Text, '(?i)\b(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\b') | ForEach-Object {
    if (-not (Test-CslPrivateOrFakeIp $_.Value)) { $found = $true }
  }
  if ($found) { return $true }
  # rough IPv6 public candidates (skip fe80/::1)
  [regex]::Matches([string]$Text, '(?i)\b(?:[0-9a-f]{1,4}:){2,7}[0-9a-f]{1,4}\b') | ForEach-Object {
    if (-not (Test-CslPrivateOrFakeIp $_.Value)) { $found = $true }
  }
  return $found
}

<#
.SYNOPSIS
  Mask a value for issue-export text.
  - Paths: USERPROFILE / \Users\<name>\ → %USERPROFILE%
  - Computer name → <PC>
  - Subscription / node URLs & domains fully masked
  - Exit / WebRTC IPs kept unless -HideIp
  - Secrets / tokens never printed in full
#>
function Protect-CslIssueValue {
  param(
    [AllowNull()][string]$Value,
    [switch]$HideIp,
    [string]$UserProfile = $env:USERPROFILE,
    [string]$ComputerName = $env:COMPUTERNAME,
    [string[]]$ExtraHosts
  )
  if ($null -eq $Value -or $Value -eq '') { return '(空)' }
  $v = [string]$Value

  # Redact secret-looking substrings in place (never return early — still mask path/node/IP)
  $v = [regex]::Replace($v, '(?i)(controllerSecret\s*[=:]\s*)(\S+)', {
    param($m) $m.Groups[1].Value + (Protect-Secret $m.Groups[2].Value)
  })
  $v = [regex]::Replace($v, '(?i)(Authorization:\s*Bearer\s+)(\S+)', {
    param($m) $m.Groups[1].Value + (Protect-Secret $m.Groups[2].Value)
  })
  $v = [regex]::Replace($v, '(?i)(sk-[A-Za-z0-9]{8,})', {
    param($m) Protect-Secret $m.Groups[1].Value
  })
  $v = [regex]::Replace($v, '(?i)(api[_-]?key|auth[_-]?token)\s*[=:]\s*(\S+)', {
    param($m) $m.Groups[1].Value + '=' + (Protect-Secret $m.Groups[2].Value)
  })

  # Path / profile collapse uses the injected UserProfile (do NOT call Mask-Value -Kind Path
  # here: on non-Windows hosts $env:USERPROFILE may differ and Mask-Value falls through to Secret).
  if ($UserProfile) {
    $up = [string]$UserProfile
    if ($up.Length -gt 0) {
      $v = [regex]::Replace($v, [regex]::Escape($up), '%USERPROFILE%', 'IgnoreCase')
    }
  }
  # Generic Windows user profile path
  $v = [regex]::Replace($v, '(?i)([A-Za-z]:\\Users\\)[^\\\/\s"'']+', '%USERPROFILE%')
  $v = [regex]::Replace($v, '(?i)(/Users/)[^\/\s"'']+', '%USERPROFILE%')

  if ($ComputerName) {
    $cn = [string]$ComputerName
    if ($cn.Length -gt 0) {
      $v = [regex]::Replace($v, [regex]::Escape($cn), '<PC>', 'IgnoreCase')
    }
  }

  # Subscription / provider URLs → fully masked
  $v = [regex]::Replace($v, '(?i)https?://[^\s''"<>]+(?:subscribe|sub\?|/sub/|proxy-provider|providers?/|clash|verge)[^\s''"<>]*', '<订阅链接>')
  $v = [regex]::Replace($v, '(?i)https?://[^\s''"<>]*(?:token|password|key)=[^\s''"<>]+', '<订阅链接>')

  foreach ($h in @($ExtraHosts)) {
    if (-not $h) { continue }
    $v = [regex]::Replace($v, [regex]::Escape([string]$h), '<节点>', 'IgnoreCase')
  }
  # Bare node-looking host:port (not anthropic/claude/well-known)
  $v = [regex]::Replace($v, '(?i)\b(?!(?:anthropic|claude|ipify|ipinfo|proxycheck|ip-api|googleapis|cloudflare|stun)\b)[a-z0-9][a-z0-9\-\.]{2,}\.(?:com|net|org|io|cc|me|xyz|top|dev)(?::\d{2,5})?\b', '<节点>')

  # IPs
  $ipEval = {
    param($m)
    $ip = $m.Value
    if (Test-CslPrivateOrFakeIp $ip) { return $ip }
    if ($HideIp) { return '<出口IP>' }
    return $ip
  }
  $v = [regex]::Replace($v, '\b(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\b', $ipEval)

  # Never leave token-looking leftovers from panel injection mistakes
  $v = [regex]::Replace($v, '(?i)\b[0-9a-f]{64}\b', '<令牌>')

  return $v
}

function Get-CslIssueMeta {
  param(
    [AllowNull()][string]$Group,
    [AllowNull()][string]$Text
  )
  $g = [string]$Group
  $t = [string]$Text
  $recheck = 'powershell -NoProfile -ExecutionPolicy Bypass -File .\claude-preflight.ps1 -NoLaunch -NoPause'
  $expected = '该项应通过（与记住的环境一致、无失败/警告）'
  $problem = $t

  if ($g -match 'Clash|TUN') {
    $expected = 'Clash Verge 已运行，代理内核 (mihomo) 运行中，TUN（虚拟网卡）已启用'
    $problem = if ($t) { $t } else { 'Clash / TUN 检查未通过' }
  }
  elseif ($g -match '时区') {
    $expected = '系统时区与记住的出口地区时区一致，且未开启会改回的自动时区'
    $problem = if ($t) { $t } else { '系统时区不一致' }
  }
  elseif ($g -match '节点') {
    $expected = 'Claude 策略组（及锁定的主组）使用记住的节点'
    $problem = if ($t) { $t } else { '节点锁定失败' }
  }
  elseif ($g -match '出口 IP|三方') {
    $expected = '本机实测 IP、Claude 边缘 IP 与记住的 expectedIp 一致，且不在封锁地区'
    $problem = if ($t) { $t } else { '出口 IP 不一致' }
  }
  elseif ($g -match 'IP 风险') {
    $expected = '出口 IP 风险分低于失败阈值，且未被标记为机房/代理（或仅作提示）'
    $problem = if ($t) { $t } else { 'IP 风险偏高' }
  }
  elseif ($g -match 'DNS') {
    $expected = 'api.anthropic.com 解析到 Clash fake-ip（198.18.0.0/15）'
    $problem = if ($t) { $t } else { 'DNS 未被 Clash 接管' }
  }
  elseif ($g -match 'IPv6') {
    $expected = '无公网 IPv6 出口（避免绕过代理）'
    $problem = if ($t) { $t } else { '存在 IPv6 泄露' }
  }
  elseif ($g -match '连通性|api\.anthropic') {
    $expected = 'api.anthropic.com 可连通（405/401/404 视为正常，非地区 403）'
    $problem = if ($t) { $t } else { 'api.anthropic.com 连通异常' }
  }
  elseif ($g -match '环境变量') {
    $expected = '用户级无第三方中转 ANTHROPIC_*（等）变量；代理变量按需配置'
    $problem = if ($t) { $t } else { '存在第三方中转环境变量' }
    $recheck = 'powershell -NoProfile -ExecutionPolicy Bypass -File .\claude-preflight.ps1 -NoLaunch -NoPause'
  }
  elseif ($g -match '残留') {
    $expected = 'Claude 配置与 npm 全局目录无第三方接口残留/切换脚本（或已确认可忽略）'
    $problem = if ($t) { $t } else { '发现第三方接口残留' }
  }
  elseif ($g -match '浏览器') {
    $expected = 'WebRTC 公网 IP 与出口一致；浏览器时区/语言与出口地区一致；webdriver 未开启'
    $problem = if ($t) { $t } else { '浏览器环境异常' }
    $recheck = '从面板运行「重新检查（不启动）」（命令行无法做 WebRTC 实时采集）'
  }
  elseif ($g -match '其他') {
    $expected = '系统语言合理，Claude 桌面版与 CLI 已安装'
    $problem = if ($t) { $t } else { '本机配置不完整' }
  }

  if ($g -and $problem -notmatch [regex]::Escape(($g -replace '^\d+\.\s*',''))) {
    # keep problem as the raw check text; title goes in 问题 header via Format
  }

  return [pscustomobject]@{
    Problem  = $problem
    Expected = $expected
    Recheck  = $recheck
    Group    = $g
  }
}

function Format-CslIssueDescription {
  param(
    [AllowNull()][string]$Group,
    [AllowNull()][string]$Level,
    [AllowNull()][string]$Text,
    [switch]$HideIp,
    [string]$UserProfile = $env:USERPROFILE,
    [string]$ComputerName = $env:COMPUTERNAME,
    [string[]]$ExtraHosts
  )
  $meta = Get-CslIssueMeta -Group $Group -Text $Text
  $rawCurrent = [string]$Text
  $current = Protect-CslIssueValue -Value $rawCurrent -HideIp:$HideIp -UserProfile $UserProfile -ComputerName $ComputerName -ExtraHosts $ExtraHosts
  $problem = Protect-CslIssueValue -Value $meta.Problem -HideIp:$HideIp -UserProfile $UserProfile -ComputerName $ComputerName -ExtraHosts $ExtraHosts
  $expected = Protect-CslIssueValue -Value $meta.Expected -HideIp:$HideIp -UserProfile $UserProfile -ComputerName $ComputerName -ExtraHosts $ExtraHosts
  $lvl = if ($Level) { [string]$Level } else { '' }
  $title = if ($meta.Group) { "[{0}] {1}" -f $lvl, ($meta.Group -replace '^\d+\.\s*','') } else { "[$lvl]" }

  $containsIp = (Test-CslTextContainsExitIp $rawCurrent) -or (Test-CslTextContainsExitIp $current)
  $lines = New-Object System.Collections.Generic.List[string]
  if ($containsIp -and -not $HideIp) {
    [void]$lines.Add($script:CslIssueIpNotice)
    [void]$lines.Add('')
  }
  [void]$lines.Add(("问题: {0}" -f $(if ($meta.Group) { "$title — $problem" } else { $problem })))
  [void]$lines.Add(("当前状态: {0}" -f $current))
  [void]$lines.Add(("期望状态: {0}" -f $expected))
  [void]$lines.Add(("复查命令: {0}" -f $meta.Recheck))
  [void]$lines.Add($script:CslIssueClosing)
  return ($lines -join "`r`n")
}

function Format-CslIssuePack {
  param(
    [object[]]$Items,
    [switch]$HideIp,
    [string]$UserProfile = $env:USERPROFILE,
    [string]$ComputerName = $env:COMPUTERNAME,
    [string[]]$ExtraHosts
  )
  $parts = New-Object System.Collections.Generic.List[string]
  $anyIp = $false
  foreach ($it in @($Items)) {
    if (-not $it) { continue }
    $lv = [string]$it.Level
    if ($lv -ne 'FAIL' -and $lv -ne 'WARN' -and $lv -ne '失败' -and $lv -ne '警告') { continue }
    $txt = [string]$it.Text
    if (Test-CslTextContainsExitIp $txt) { $anyIp = $true }
  }
  # Pack-level notice once at top when any issue keeps an exit IP
  if ($anyIp -and -not $HideIp) {
    [void]$parts.Add($script:CslIssueIpNotice)
    [void]$parts.Add('')
  }
  $n = 0
  foreach ($it in @($Items)) {
    if (-not $it) { continue }
    $lv = [string]$it.Level
    if ($lv -ne 'FAIL' -and $lv -ne 'WARN' -and $lv -ne '失败' -and $lv -ne '警告') { continue }
    $n++
    # Per-item: suppress duplicate opening line (already at pack top)
    $one = Format-CslIssueDescription -Group $it.Group -Level $lv -Text $it.Text -HideIp:$HideIp -UserProfile $UserProfile -ComputerName $ComputerName -ExtraHosts $ExtraHosts
    if ($anyIp -and -not $HideIp) {
      $prefix = $script:CslIssueIpNotice + "`r`n`r`n"
      if ($one.StartsWith($prefix)) {
        $one = $one.Substring($prefix.Length)
      } elseif ($one.StartsWith($script:CslIssueIpNotice + "`n`n")) {
        $one = $one.Substring(($script:CslIssueIpNotice + "`n`n").Length)
      }
    }
    [void]$parts.Add("---- 问题 $n ----")
    [void]$parts.Add($one)
    [void]$parts.Add('')
  }
  if ($n -eq 0) {
    return '(当前没有失败或警告项)'
  }
  return ($parts -join "`r`n").TrimEnd() + "`r`n"
}
