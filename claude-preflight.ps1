param(
  [switch]$Force,
  [switch]$NoPause,
  [switch]$NoLaunch,
  [switch]$Relearn,
  [switch]$TestMode,
  [switch]$DryRun,
  [switch]$FixEnv,
  [switch]$Yes,
  [switch]$UndoFix,
  [string]$UndoId,
  [switch]$ListFixes,
  [string[]]$FixVarPattern,
  [int]$FailAtIndex = 0,
  [switch]$ExportIssues,
  [switch]$HideIp,
  [switch]$Json,
  [string]$JsonPath
)
<#
  Claude 桌面版 启动前检查 + 自动设置（v3.3.0）
  用法: powershell -NoProfile -ExecutionPolicy Bypass -File claude-preflight.ps1 [选项]
  -Force    : 即使有「必须修」项也启动 Claude
  -NoPause  : 结束时不等待按键；单独使用时不提示也不自动修复
  -NoLaunch : 只检查，不启动/不切换 Claude，也不启动后台监控（测试用）
  -Relearn  : 忘掉记住的出口 IP / 节点 / 时区，按当前环境重新记住
  -FixVarPattern <通配符...> : 限定要检测/修复的用户级变量名（默认 ANTHROPIC_* 列表）
  -FixEnv   : 一键清除匹配的用户级中转变量；先列出变量名和动作（不显示值）并问 y/N，回答 y 才修改（v3.3.0 起）
  -Yes      : 配合 -FixEnv 跳过 y/N 确认，直接修复（脚本/无人值守用）
  -DryRun   : 只列出将要修改的变量名和动作，不写系统、不写备份
  -UndoFix [-UndoId <id>] : 撤销一次修复（默认最近一次）；冲突时 -NoPause 跳过并返回非 0
  -ListFixes : 列出可撤销操作（脱敏）
  -TestMode : 仅允许操作 CSL_TEST_ 前缀变量；测试请配合 -FixVarPattern 'CSL_TEST_ANTHROPIC_*'
  -FailAtIndex <n> : （仅 -TestMode）使第 n 个变量变更抛错，用于验证整单回滚；非 TestMode 警告并忽略
  -ExportIssues : 检查结束后打印可复制的「问题说明」（脱敏四段结构）；建议配合 -NoLaunch -NoPause
  -HideIp : 出口 IP / WebRTC IP 也脱敏：-ExportIssues 的问题说明省略 IP 提示行；preflight-result.json 的 current 同样遮罩（containsIp 照样标 true）
  -Json     : 写出 preflight-result.json（UTF-8 无 BOM）并在末尾打印 CSL_JSON_PATH=…；评分走 claude-rules.ps1。不带 -Json 就不写也不覆盖这个文件（v4.0.0 起）
  -JsonPath <文件路径> : 配合 -Json，把 JSON 写到指定文件（默认脚本目录的 preflight-result.json）；目标目录必须已存在，不存在就报错退出（不自动创建）；只给 -JsonPath 不给 -Json 也报错退出（退出码 2，不写文件）
  配置文件  : 同目录 preflight.json（可用 fixVarPatterns；controllerSecret 不会被打印）
  依赖      : 同目录 claude-common.ps1、claude-envfix.ps1、claude-issueexport.ps1、claude-monitor.ps1、claude-rules.ps1
#>
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'claude-common.ps1')
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'claude-envfix.ps1')
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'claude-issueexport.ps1')
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'claude-rules.ps1')
# R4a: -JsonPath 先校验：目录不存在、或只给 -JsonPath 不给 -Json，都在任何检查之前报错退出
if ($Json -or $JsonPath) {
  try { $script:CslJsonTarget = Resolve-CslPreflightJsonPath -Json:$Json -JsonPath $JsonPath -Root (Split-Path -Parent $MyInvocation.MyCommand.Path) }
  catch { Write-Host ("CSL_JSON_ERROR=" + $_.Exception.Message) -ForegroundColor Red; exit 2 }
}
try { $Host.UI.RawUI.WindowTitle = 'Claude 安全启动 - 启动前检查' } catch {}
$cfg = Load-Config
if ($Relearn) { Save-Learned $cfg @{ expectedIp = ''; expectedLoc = ''; expectedNode = ''; timezone = ''; expectedTzIana = '' } }

$script:DoUndoFix = [bool]$UndoFix
$script:UndoFixId = $(if ($UndoId) { $UndoId } else { $null })

$script:FixPatterns = Get-CslFixVarPatterns -Cfg $cfg -FixVarPattern $FixVarPattern
$script:EnvFixSettings = Get-CslEnvFixSettings $cfg

# 撤销冲突提示：跳过 $null / 空值（PS 5.1 下 @($null) 会产生一个 $null 元素）
function Get-CslUndoConflictMessages($Conflicts) {
  $out = @()
  foreach ($c in @($Conflicts)) {
    if ($null -eq $c) { continue }
    $msg = if ($c -is [string]) { $c } elseif ($c -is [System.Collections.IDictionary]) { if ($c.Contains('message') -and $c['message']) { [string]$c['message'] } else { [string]$c['name'] } } elseif ($c.PSObject.Properties['message']) { [string]$c.message } else { [string]$c }
    if ([string]::IsNullOrWhiteSpace($msg)) { continue }
    $out += $msg
  }
  return $out
}
function Write-CslUndoConflicts($Conflicts) {
  foreach ($m in @(Get-CslUndoConflictMessages $Conflicts)) { Write-Host ("  [警告] {0}" -f $m) -ForegroundColor Yellow }
}

# -ListFixes 输出：只列变量名和动作/状态，不出现任何值（打码也不行）
function Write-CslEnvFixList($List) {
  Write-Host '可撤销的环境变量修复（只列变量名和动作）:' -ForegroundColor Cyan
  $list = @($List | Where-Object { $null -ne $_ })
  if ($list.Count -eq 0) { Write-Host '  （无）' -ForegroundColor DarkGray }
  foreach ($it in $list) {
    $st = $(if ($it.corrupt) { "损坏（不会自动清理）: $($it.path)" } elseif ($it.undone) { '已撤销' } elseif ($it.partiallyUndone) { '部分已撤销（其余可撤销）' } else { '可撤销' })
    Write-Host ("  [{0}] {1}  {2}" -f $it.id, $it.ts, $st)
    foreach ($v in $it.vars) {
      Write-Host ("    - {0}: {1}（{2}）" -f $v.name, $v.action, $(if ($it.undone -or $v.undone) { '已撤销' } else { '可撤销' }))
    }
  }
}

# ----- CLI：列出 / 撤销 / 仅修复（可在完整检查前短路） -----
if ($ListFixes) {
  Write-CslEnvFixList @(Get-CslEnvFixList)
  if (-not $NoPause) { try { Read-Host '按回车退出' | Out-Null } catch {} }
  exit 0
}

if ($script:DoUndoFix) {
  Write-Host '撤销环境变量修复…' -ForegroundColor Cyan
  $undo = Invoke-CslEnvUndo -Id $script:UndoFixId -NoPause:$NoPause -TestMode:$TestMode -FailAtIndex $FailAtIndex
  if ($undo.alreadyUndone) {
    Write-Host ("  [信息] already undone（{0}）" -f $undo.id) -ForegroundColor Gray
  }
  if ($undo.restored) {
    foreach ($r in $undo.restored) { Write-Host ("  [修复] 已恢复 {0}" -f $r.name) -ForegroundColor Yellow }
  }
  Write-CslUndoConflicts $undo.conflicts
  if (-not $undo.ok -and $undo.error) { Write-Host ("  [失败] {0}" -f $undo.error) -ForegroundColor Red }
  if ($undo.hint) { Write-Host ("  [信息] {0}" -f $undo.hint) -ForegroundColor Gray }
  if (-not $NoPause) { try { Read-Host '按回车退出' | Out-Null } catch {} }
  exit $(if ($null -ne $undo.exitCode) { $undo.exitCode } else { 1 })
}

# 确认名单 / 预览：只显示变量名和动作，不显示值（含打码值）
function Write-CslEnvFixPlan($Plan) {
  foreach ($row in @($Plan)) {
    if ($null -eq $row) { continue }
    switch ([string]$row.action) {
      'skip-admin' { Write-Host ("  [提示] {0} 仅 Machine 级存在：需要管理员手动处理" -f $row.name) -ForegroundColor DarkGray }
      'keep'       { Write-Host ("  [信息] 保留 User {0}（envFixKeep）" -f $row.name) -ForegroundColor Gray }
      default      { Write-Host ("  [信息] 将清除 User {0}" -f $row.name) -ForegroundColor Gray }
    }
  }
}

if ($FixEnv) {
  Write-Host '一键修复用户级中转环境变量…' -ForegroundColor Cyan
  $pauseExit = { param($code) if (-not $NoPause) { try { Read-Host '按回车退出' | Out-Null } catch {} }; exit $code }
  if (-not $script:EnvFixSettings.enabled) {
    Write-Host '  [信息] 一键修复已在 preflight.json 关闭（envFixEnabled=false），未做任何修改' -ForegroundColor Gray
    & $pauseExit 1
  }
  $keep = @($script:EnvFixSettings.keep)
  if ($DryRun) { Write-Host '  [信息] DryRun：只预览，不修改' -ForegroundColor Gray }
  $preview = Invoke-CslEnvFix -Patterns $script:FixPatterns -TestMode:$TestMode -DryRun -Keep $keep
  if (-not $preview.ok) {
    Write-Host ("  [失败] {0}" -f $preview.error) -ForegroundColor Red
    & $pauseExit $(if ($null -ne $preview.exitCode) { $preview.exitCode } else { 1 })
  }
  Write-CslEnvFixPlan $preview.plan
  if ($DryRun) { & $pauseExit 0 }
  $removeCount = @(@($preview.plan) | Where-Object { $null -ne $_ -and $_.action -eq 'remove' }).Count
  if ($removeCount -eq 0) {
    Write-Host '  [信息] 没有可清除的用户级变量' -ForegroundColor Gray
    & $pauseExit 0
  }
  # v3.3.0 起 -FixEnv 先确认；-NoPause 也会问（读不到输入 = 不同意）。脚本请加 -Yes
  if (-not (Test-CslFixConfirmed -Yes:$Yes -ReadAnswer { Read-Host '  确认删除以上用户级变量？(y/N)' })) {
    Write-Host '  [信息] 已取消，未做任何修改（无人值守请加 -Yes）' -ForegroundColor Gray
    & $pauseExit 1
  }
  $fix = Invoke-CslEnvFix -Patterns $script:FixPatterns -TestMode:$TestMode -FailAtIndex $FailAtIndex -Keep $keep
  if (-not $fix.ok) {
    Write-Host ("  [失败] {0}" -f $fix.error) -ForegroundColor Red
    & $pauseExit $(if ($null -ne $fix.exitCode) { $fix.exitCode } else { 1 })
  }
  foreach ($a in @($fix.applied)) {
    if ($null -eq $a) { continue }
    Write-Host ("  [修复] 已删除用户级 {0}" -f $a.name) -ForegroundColor Yellow
  }
  if ($fix.id) { Write-Host ("  [信息] 备份 id={0}（可用 -UndoFix 撤销）" -f $fix.id) -ForegroundColor Gray }
  if ($fix.hint) { Write-Host ("  [信息] {0}" -f $fix.hint) -ForegroundColor Gray }
  & $pauseExit $(if ($null -ne $fix.exitCode) { $fix.exitCode } else { 0 })
}


# ---------- 输出与评分 ----------
# FAIL = 必须修（默认扣 25）  WARN = 建议修（默认扣 8）  NOTE = 不用管（0 分）
$script:Items = New-Object System.Collections.ArrayList
$script:CurrentHead = ''
# Id = rules/checks.json 的真实规则 id（Say-Fail / Say-Warn / Say-Note 调用点必须传 -Id；测试静态检查）
function Add-Item($level, $t, $w, $id = $null) { [void]$script:Items.Add([pscustomobject]@{ Level = $level; Text = $t; Weight = $w; Group = $script:CurrentHead; Id = $id }) }
function Say-Head($t) { $script:CurrentHead = [string]$t; Write-Host ''; Write-Host "== $($t)" -ForegroundColor Cyan }
function Say-Pass($t) { Write-Host "  [通过] $($t)" -ForegroundColor Green }
function Say-Info($t) { Write-Host "  [信息] $($t)" -ForegroundColor Gray }
function Say-Fix($t)  { Write-Host "  [修复] $($t)" -ForegroundColor Yellow }
function Say-Note($t, $Id = $null) { Write-Host "  [提示] $($t)" -ForegroundColor DarkGray; Add-Item 'NOTE' $t 0 $Id }
function Say-Warn($t, $w = 8, $Id = $null)  { Write-Host "  [警告] $($t)" -ForegroundColor Yellow; Add-Item 'WARN' $t $w $Id }
function Say-Fail($t, $w = 25, $Id = $null) { Write-Host "  [失败] $($t)" -ForegroundColor Red; Add-Item 'FAIL' $t $w $Id }

# 用户级中转变量的检查项文本（显示给人看，含打码值；JSON 不用这条文本，见 Get-CslJsonCurrent）
function Format-CslEnvUserItemText($Name, $Value) {
  return ("用户级 {0}={1}（会让 Claude Code 走第三方接口）" -f $Name, (Protect-Secret $Value))
}

# JSON 的 current 字段：环境变量项只输出变量名和状态，不含值、不含打码值（不含 = 和 *）
# 其余文本走 v3.3.0 issue 导出同一套脱敏（Protect-CslIssueValue，claude-issueexport.ps1）：
#   路径用户名 → %USERPROFILE%，计算机名 → <PC>，订阅链接 / 节点域名 / ExtraHosts 遮罩，controllerSecret / 令牌不输出；
#   出口 IP / WebRTC IP 默认保留，-HideIp 时遮罩（containsIp 由 New-CslScoreMappedResults 标记）。
function Get-CslJsonCurrent {
  param(
    [AllowNull()][string]$Text,
    [switch]$HideIp,
    [string]$UserProfile = $env:USERPROFILE,
    [string]$ComputerName = $env:COMPUTERNAME,
    [string[]]$ExtraHosts
  )
  if ($null -eq $Text -or $Text -eq '') { return '' }
  $t = [string]$Text
  $m = [regex]::Match($t, '^用户级\s+([^\s=]+)=')
  if ($m.Success) { return ('用户级 {0}：已设置' -f $m.Groups[1].Value) }
  $t = [regex]::Replace($t, '\b([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)=\S*', '$1：已设置')
  $t = Protect-CslIssueValue -Value $t -HideIp:$HideIp -UserProfile $UserProfile -ComputerName $ComputerName -ExtraHosts $ExtraHosts
  # 兜底：任何仍含 * 的片段（遗漏的打码值）一律替换，JSON 里不出现 *
  return [regex]::Replace($t, '\S*\*\S*', '（已隐藏）')
}

# 检查项 → 规则评分输入（preflight-result.json 的 checks 由此而来）
# 每个检查项带着调用点写死的真实规则 id（rules/checks.json）；映射是确定的，没有 item.N 占位。
# 没有有效 id 的项（缺 id / 不在目录里 / 非 multi 规则重复出现）不丢、不编造 id：
#   以保留 id `meta.unmapped`（目录里标 multi）、status=error 写进 JSON，原因写在该行的 notes（不回显原 id；current 留空）；
#   同时记入 $script:CslUnmappedItems（Item / Id / Reason）。error 行在评分器里不扣分，
#   所以由 Invoke-CslPreflightScoring 按原权重补扣，分数与 d025841 一致。
# fixType / fixId 与 d025841 逐项一致：只有文本含「用户级」的失败项带 confirm + envfix.user-anthropic，其余一律 none / null。
function New-CslScoreMappedResults {
  param(
    $Items,
    $Catalog = $null,
    [switch]$HideIp,
    [string]$UserProfile = $env:USERPROFILE,
    [string]$ComputerName = $env:COMPUTERNAME,
    [string[]]$ExtraHosts
  )
  $script:CslUnmappedItems = New-Object System.Collections.ArrayList
  $mapped = New-Object System.Collections.ArrayList
  if ($null -eq $Catalog) { try { $Catalog = Get-CslRulesCatalog } catch { $Catalog = $null } }
  $seen = @{}
  foreach ($it in @($Items)) {
    if ($null -eq $it) { continue }
    $id = [string](Get-CslPsProp $it 'Id')
    $rule = $null
    if ($Catalog -and $id) { $rule = Get-CslRuleById -Catalog $Catalog -Id $id }
    $reason = ''
    if (-not $rule) {
      $reason = $(if ($id) { 'id 不在 rules/checks.json 里' } else { '检查项没有规则 id' })
    } else {
      $multi = $false; $mv = Get-CslPsProp $rule 'multi'; if ($null -ne $mv) { $multi = [bool]$mv }
      if ($seen.ContainsKey($id) -and -not $multi) { $reason = '规则 id 重复出现，但目录没有标 multi' }
      else { $seen[$id] = $true }
    }
    $sev = 'info'; $st = 'info'
    if ($it.Level -eq 'FAIL') { $sev = 'must_fix'; $st = 'failed' }
    elseif ($it.Level -eq 'WARN') { $sev = 'should_fix'; $st = 'failed' }
    elseif ($it.Level -eq 'NOTE') { $sev = 'info'; $st = 'info' }
    $fixTypeOv = 'none'; $fixIdOv = $null
    if ([string]$it.Text -match '用户级' -and $st -eq 'failed') {
      $fixTypeOv = 'confirm'; $fixIdOv = 'envfix.user-anthropic'
    }
    $cur = Get-CslJsonCurrent -Text ([string]$it.Text) -HideIp:$HideIp -UserProfile $UserProfile -ComputerName $ComputerName -ExtraHosts $ExtraHosts
    # 原文含出口 IP / WebRTC IP 的行一律 containsIp=true（-HideIp 遮罩后照样标 true）；其余沿用目录默认
    $cipOv = $null
    if (Test-CslTextContainsExitIp ([string]$it.Text)) { $cipOv = $true }
    $outId = $id
    $note = ''
    if ($reason) {
      [void]$script:CslUnmappedItems.Add([pscustomobject]@{ Item = $it; Id = $id; Reason = $reason })
      $outId = 'meta.unmapped'; $st = 'error'
      # 原因写进 notes（不回显原 id）；current 留空，不带任何原文
      $cur = ''
      $cipOv = $null
      $note = ('未映射：{0}' -f $reason)
    }
    [void]$mapped.Add([pscustomobject]@{
      id                   = $outId
      status               = $st
      severityOverride     = $sev
      refDeductionOverride = [int]$it.Weight
      current              = $cur
      expected             = ''
      recheck              = 'powershell -NoProfile -ExecutionPolicy Bypass -File claude-preflight.ps1 -NoLaunch -NoPause'
      masked               = $true
      fixTypeOverride      = $fixTypeOv
      fixIdOverride        = $fixIdOv
      containsIpOverride   = $cipOv
      notes                = $note
    })
  }
  return ,$mapped
}

# 评分单一入口（preflight 与测试共用）：映射 → Get-CslRulesScore → 补扣未映射项的原权重
function Invoke-CslPreflightScoring($Items, $Catalog, [switch]$HideIp) {
  $mapped = New-CslScoreMappedResults @($Items) -Catalog $Catalog -HideIp:$HideIp
  $res = Get-CslRulesScore -Catalog $Catalog -Results $mapped
  $extra = 0
  foreach ($u in $script:CslUnmappedItems) { $extra += [int]$u.Item.Weight }
  if ($extra -gt 0) { $res.score = [int][Math]::Max(0, [int]$res.score - $extra) }
  $script:CslScoreMapped = $mapped
  return $res
}

Write-Host '==============================================' -ForegroundColor Cyan
Write-Host '   Claude 桌面版 启动前检查 v4.0.0' -ForegroundColor Cyan
if ($Relearn) { Write-Host '   [重新学习] 将按当前环境重新记住出口 IP / 节点 / 时区' -ForegroundColor Cyan }
Write-Host ("   " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + $(if ($NoLaunch) { '   [NoLaunch 测试模式]' } else { '' })) -ForegroundColor Cyan
Write-Host '==============================================' -ForegroundColor Cyan

# ---------- 1. Clash Verge / TUN ----------
Say-Head '1. Clash Verge 与 TUN 模式'
$mihomo = Get-ProxyCore
$verge  = Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue
$tun = Get-TunAdapter
if (-not ($mihomo -and $tun -and $tun.Status -eq 'Up')) {
  if (-not $verge) {
    if ($cfg.clashExe -and (Test-Path $cfg.clashExe)) { Say-Fix "Clash Verge 未运行，正在启动: $($cfg.clashExe)"; Start-Process -FilePath $cfg.clashExe | Out-Null }
    else { Say-Fail "Clash Verge 未运行，也没找到安装位置（可在 preflight.json 里填写 clashExe）" -Id 'net.clash_running' }
  } else { Say-Info 'Clash Verge 已运行，但 TUN 未就绪，等待中…' }
  $deadline = (Get-Date).AddSeconds(30)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    $mihomo = Get-ProxyCore
    $tun = Get-TunAdapter
    if ($mihomo -and $tun -and $tun.Status -eq 'Up') { break }
  }
}
if ($mihomo) { Say-Pass "代理内核 $(@($mihomo)[0].ProcessName) 运行中 (PID $(@($mihomo)[0].Id))" } else { Say-Fail '代理内核 (mihomo) 未运行' -Id 'net.mihomo_core' }
if ($tun -and $tun.Status -eq 'Up') { Say-Pass "TUN 网卡 $($tun.Name) 已启用" }
else { Say-Fail '30 秒内 TUN 网卡未启用。请在 Clash Verge 里打开「虚拟网卡模式 (TUN)」' -Id 'net.tun' }

# ---------- 2. 时区 ----------
Say-Head '2. 系统时区'
$tz = (Get-TimeZone).Id
if (-not $cfg.timezone) {
  $tr0 = Get-Trace 'https://claude.ai/cdn-cgi/trace'; $iana = $null
  if ($tr0['ip']) { try { $iana = ((Invoke-Curl @('-m','12',"https://ipinfo.io/$($tr0['ip'])/json")) | ConvertFrom-Json).timezone } catch {} }
  $win = Convert-IanaToWindows $iana
  if ($win) { Save-Learned $cfg @{ timezone = $win; expectedTzIana = [string]$iana }; Say-Fix "首次运行：按出口 IP 所在地（$($iana)）设定目标时区 $($win)" }
  else { Say-Note "无法按出口 IP 判断时区（$($iana)），跳过时区检查；可在 preflight.json 里手动填写 timezone" -Id 'locale.system_tz' }
}
if ($cfg.timezone -and $tz -ne $cfg.timezone) {
  Say-Fix "当前时区 $($tz)，正在改为 $($cfg.timezone)"
  & tzutil.exe /s "$($cfg.timezone)" 2>&1 | Out-Null
  $tz = (& tzutil.exe /g).Trim()
}
if (-not $cfg.timezone) { } elseif ($tz -eq $cfg.timezone) { Say-Pass "时区: $($tz)" } else { Say-Fail "时区修改失败，当前仍为 $($tz)" -Id 'locale.system_tz' }
$tzAuto = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\tzautoupdate' -ErrorAction SilentlyContinue).Start
if ($tzAuto -eq 4) { Say-Pass '自动设置时区已关闭 (tzautoupdate Start=4)' }
else { Say-Warn "自动设置时区未关闭 (Start=$($tzAuto))，时区可能被系统改回" 5 -Id 'locale.tz_auto' }

# ---------- 3. 节点锁定（mihomo 外部控制器） ----------
Say-Head '3. 节点锁定'
$ctlVer = Ctl-Get $cfg '/version'
if (-not $ctlVer) {
  Say-Warn "外部控制器 $($cfg.controllerUrl) 无法连接，无法确认/自动切回节点（请完全退出并重新打开 Clash Verge 使控制器生效）" 10 -Id 'net.controller'
} else {
  Say-Pass "外部控制器已连接 (mihomo $($ctlVer.version))"
  $groups = @(); if ($cfg.claudeGroup) { $groups += $cfg.claudeGroup }
  if ($cfg.pinMainGroup -and $cfg.mainGroup) { $groups += $cfg.mainGroup }
  if (-not $cfg.expectedNode -and $cfg.claudeGroup) {
    $gi = Ctl-GetGroup $cfg $cfg.claudeGroup
    if ($gi -and $gi.now) { Save-Learned $cfg @{ expectedNode = [string]$gi.now }; Say-Fix "首次运行：记住 $($cfg.claudeGroup) 组当前节点 $($gi.now)，以后被切走会自动切回" }
  }
  $switched = $false
  foreach ($g in $groups) {
    $info = Ctl-GetGroup $cfg $g
    if (-not $info) { Say-Note "Clash 里没有名为 $($g) 的策略组，跳过节点锁定（建议给 Claude 建一个专用分组，见 README）" -Id 'net.node_lock'; continue }
    if (-not $cfg.expectedNode) { Say-Info "$($g) 组 → $($info.now)（未设置锁定节点）"; continue }
    if ($info.now -eq $cfg.expectedNode) { Say-Pass "$($g) 组 → $($info.now)" }
    else {
      Say-Fix "$($g) 组当前为 $($info.now)，正在切回 $($cfg.expectedNode)"
      if (Ctl-SelectNode $cfg $g $cfg.expectedNode) {
        $after = Ctl-GetGroup $cfg $g
        if ($after.now -eq $cfg.expectedNode) { Say-Pass "$($g) 组已切回 $($after.now)"; $switched = $true }
        else { Say-Fail "$($g) 组切换后仍为 $($after.now)" -Id 'net.node_lock' }
      } else { Say-Fail "$($g) 组切换请求失败" -Id 'net.node_lock' }
    }
  }
  if ($switched) { Say-Info '已切换节点，等待 3 秒后重新测 IP…'; Start-Sleep -Seconds 3 }
}

# ---------- 4. 三方 IP 对比 ----------
Say-Head '4. 出口 IP 三方对比（本机实测 / 期望 / Claude 边缘）'
$localIp = $null; $ipinfo = $null
try { $ipinfo = (Invoke-Curl @('-m','12','https://ipinfo.io/json')) | ConvertFrom-Json } catch {}
if ($ipinfo -and $ipinfo.ip) { $localIp = $ipinfo.ip; Say-Info "本机实测(ipinfo): $($ipinfo.ip) $($ipinfo.country) $($ipinfo.city) / $($ipinfo.org)" }
else {
  $localIp = (Invoke-Curl @('-4','-m','12','https://api.ipify.org')).Trim()
  if ($localIp) { Say-Info "本机实测(ipify): $($localIp)" } else { Say-Warn '本机实测 IP 查询失败（ipinfo / ipify 都无响应）' 5 -Id 'exit.local_ip' }
}
$edge = @()
foreach ($u in @('https://claude.ai/cdn-cgi/trace', 'https://api.anthropic.com/cdn-cgi/trace')) {
  $tr = Get-Trace $u
  $hostName = ([uri]$u).Host
  if ($tr['ip']) { $edge += [pscustomobject]@{ Host = $hostName; Ip = $tr['ip']; Loc = $tr['loc']; Colo = $tr['colo'] }; Say-Info "Claude 边缘($($hostName)): ip=$($tr['ip']) loc=$($tr['loc']) colo=$($tr['colo'])" }
  elseif ($hostName -eq 'claude.ai') { Say-Fail '无法访问 claude.ai/cdn-cgi/trace' -Id 'exit.edge_trace' }
  else { Say-Info "$($hostName) 不提供 trace（忽略）" }
}
$blocked = '^(CN|HK|MO|RU|KP|IR|CU|SY|BY)$'
$edgeLoc = $(if ($edge.Count) { $edge[0].Loc } else { '' })
if ($edgeLoc -and $edgeLoc -match $blocked) { Say-Fail "Claude 看到你位于 $($edgeLoc)，这是 Claude 不支持的地区，请检查代理规则是否让 Claude 走了代理" -Id 'exit.blocked_region' }
if (-not $cfg.expectedIp) {
  $ips = @(@($edge | ForEach-Object { $_.Ip }) + @($localIp) | Where-Object { $_ } | Select-Object -Unique)
  if ($edge.Count -and $edgeLoc -notmatch $blocked -and $ips.Count -eq 1) { Save-Learned $cfg @{ expectedIp = $ips[0]; expectedLoc = $edgeLoc }; Say-Fix "首次运行：记住当前出口 IP $($ips[0])（$($edgeLoc)），以后变化会提醒" }
  elseif ($ips.Count -gt 1) { Say-Warn ("各方看到的出口 IP 不一致，暂不记住: " + ($ips -join ', ')) 10 -Id 'exit.three_way_ip' }
  elseif (-not $edge.Count) { Say-Warn '测不到 Claude 看到的出口 IP，暂不记住' 10 -Id 'exit.three_way_ip' }
}
if ($cfg.expectedIp) { Say-Info "期望: $($cfg.expectedIp) loc=$($cfg.expectedLoc)" }
$all = @(); if ($cfg.expectedIp) { $all = @($edge | ForEach-Object { $_.Ip }); if ($localIp) { $all += $localIp } }
$bad = @($all | Where-Object { $_ -ne $cfg.expectedIp })
$badLoc = @($edge | Where-Object { $_.Loc -ne $cfg.expectedLoc })
if ($all.Count -gt 0 -and $bad.Count -eq 0 -and $badLoc.Count -eq 0) { Say-Pass "三方一致: $($cfg.expectedIp)" }
elseif ($all.Count -gt 0) { Say-Fail ("IP 不一致: 本机=$($localIp) 边缘=" + (($edge | ForEach-Object { "$($_.Host):$($_.Ip)/$($_.Loc)" }) -join ',') + " 期望=$($cfg.expectedIp)") -Id 'exit.three_way_ip' }
$exitIp = $(if ($edge.Count) { $edge[0].Ip } else { $localIp })

# ---------- 5. IP 风险评分 ----------
Say-Head '5. IP 风险（proxycheck.io / ip-api）'
$qip = $(if ($exitIp) { $exitIp } else { $cfg.expectedIp })
$pc = $null
try { $pc = (Invoke-Curl @('-m','15',"https://proxycheck.io/v2/$($qip)?vpn=1&asn=1&risk=1")) | ConvertFrom-Json } catch {}
$pcd = $null; if ($pc -and $pc.status -match 'ok|warning') { $pcd = $pc.$qip }
if ($pcd) {
  $risk = [int]$pcd.risk
  $line = "proxycheck: risk=$($risk) proxy=$($pcd.proxy) type=$($pcd.type) / $($pcd.provider) $($pcd.organisation)"
  if ($risk -ge [int]$cfg.failRisk) { Say-Fail "$($line)（≥ $($cfg.failRisk)）" -Id 'exit.ip_risk_proxycheck' }
  elseif ($risk -ge [int]$cfg.warnRisk -or $pcd.proxy -eq 'yes') { Say-Warn "$($line)（风险偏高）" 10 -Id 'exit.ip_risk_proxycheck' }
  else { Say-Pass $line }
} else { Say-Warn 'proxycheck.io 查询失败（可能被限流）' 3 -Id 'exit.ip_risk_proxycheck' }
$ia = $null
try { $ia = (Invoke-Curl @('-m','12',"http://ip-api.com/json/$($qip)?fields=status,countryCode,isp,org,as,proxy,hosting,mobile")) | ConvertFrom-Json } catch {}
if ($ia -and $ia.status -eq 'success') {
  $line = "ip-api: $($ia.countryCode) $($ia.isp) / $($ia.as) proxy=$($ia.proxy) hosting=$($ia.hosting)"
  if ($ia.hosting -or $ia.proxy) { Say-Warn "$($line)（被标记为机房/代理）" 8 -Id 'exit.ip_risk_ipapi' } else { Say-Pass $line }
} else { Say-Note 'ip-api 查询失败（忽略）' -Id 'exit.ip_risk_ipapi' }

# ---------- 6. DNS ----------
Say-Head '6. DNS (fake-ip)'
$dns = Resolve-DnsName api.anthropic.com -Type A -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress } | Select-Object -First 1
if ($dns -and ($dns.IPAddress -like '198.18.*' -or $dns.IPAddress -like '198.19.*')) { Say-Pass "api.anthropic.com → $($dns.IPAddress)（fake-ip，由 Clash 接管）" }
elseif ($dns) { Say-Warn "api.anthropic.com → $($dns.IPAddress)，不是 fake-ip，DNS 可能未被 Clash 接管" 10 -Id 'net.dns_fakeip' }
else { Say-Warn 'api.anthropic.com 解析失败' 5 -Id 'net.dns_fakeip' }

# ---------- 7. IPv6 ----------
Say-Head '7. IPv6 泄露'
$v6 = & curl.exe --noproxy '*' -6 -s -m 8 https://api64.ipify.org 2>$null
if ($LASTEXITCODE -ne 0 -or -not $v6 -or ($v6 -notmatch ':')) { Say-Pass '无 IPv6 出口' }
else { Say-Fail "存在 IPv6 出口: $($v6)，可能绕过代理暴露真实位置" -Id 'net.ipv6_leak' }

# ---------- 8. Anthropic API ----------
Say-Head '8. api.anthropic.com 连通性'
$tmp = [IO.Path]::GetTempFileName()
$code = & curl.exe --noproxy '*' -s -m 15 -o $tmp -w '%{http_code}' https://api.anthropic.com/v1/messages 2>$null
$body = ''; try { $body = [string](Get-Content $tmp -Raw -ErrorAction SilentlyContinue) } catch {}
Remove-Item $tmp -ErrorAction SilentlyContinue
$bodyOne = ($body -replace '\s+', ' ')
if ($code -in @('401','404','405')) { Say-Pass "HTTP $($code)（正常，未被地区封锁）" }
elseif ($code -eq '403') { Say-Fail ("HTTP 403，疑似地区封锁: " + $bodyOne.Substring(0, [Math]::Min(120, $bodyOne.Length))) -Id 'exit.api_anthropic' }
elseif ($code -eq '000' -or -not $code) { Say-Fail '无法连接 api.anthropic.com' -Id 'exit.api_anthropic' }
else { Say-Warn "HTTP $($code)（非预期状态码）" 5 -Id 'exit.api_anthropic' }

# ---------- 9. 环境变量 ----------
Say-Head '9. 环境变量'
# 检测与修复共用同一模式源（-FixVarPattern / preflight.json fixVarPatterns / 默认列表）
# 只读用户级注册表 / [Environment]::GetEnvironmentVariable(n,'User')，不把进程环境当真相
$targets = Find-CslRelayEnvTargets -Patterns $script:FixPatterns -TestMode:$TestMode
if (-not $targets.ok) {
  Say-Fail $targets.error -Id 'cfg.env_relay_user'
} else {
  $userNames = @($targets.user | ForEach-Object { $_.Name })
  $machNames = @($targets.machineOnly | ForEach-Object { $_.Name })
  if ($userNames.Count -eq 0 -and $machNames.Count -eq 0) {
    Say-Pass '没有匹配的第三方中转环境变量（用户级）'
  } else {
    foreach ($u in $targets.user) {
      Say-Fail (Format-CslEnvUserItemText $u.Name $u.Value) -Id 'cfg.env_relay_user'
      Write-Host 'CSL_FIX_ID=envfix.user-anthropic' -ForegroundColor DarkGray
    }
    foreach ($m in $targets.machineOnly) {
      Say-Note ("{0} 仅 Machine 级存在：需要管理员手动处理" -f $m.Name) -Id 'cfg.env_relay_machine'
    }
    # 交互修复：显式 -FixEnv 已在上方短路。此处仅在有 TTY 且非 NoPause 时询问。
    # 纯 -NoPause 绝不自动修。envFixKeep 中的变量不进确认名单；envFixEnabled=false 不询问。
    $keepNow = @($script:EnvFixSettings.keep)
    $fixNames = @($userNames | Where-Object { $null -ne $_ -and -not ($keepNow.Count -gt 0 -and (Test-CslNameMatchesPatterns -Name $_ -Patterns $keepNow)) })
    foreach ($kn in @($userNames | Where-Object { $null -ne $_ -and $fixNames -notcontains $_ })) {
      Say-Info ("{0} 在 envFixKeep 中，一键修复会保留它" -f $kn)
    }
    if ($userNames.Count -gt 0 -and -not $script:EnvFixSettings.enabled) {
      Say-Info '一键修复已在 preflight.json 关闭（envFixEnabled=false），请手动处理'
    } elseif ($fixNames.Count -gt 0 -and -not $NoPause -and -not $FixEnv) {
      foreach ($fn in $fixNames) { Say-Info ("将清除 User {0}" -f $fn) }
      $ans = ''
      try { $ans = Read-Host '  是否删除这些用户级变量？(y/N)' } catch {}
      if ($ans -match '^[yY]') {
        $fix = Invoke-CslEnvFix -Patterns $script:FixPatterns -TestMode:$TestMode -FailAtIndex $FailAtIndex -Keep $keepNow
        if ($fix.ok) {
          foreach ($a in @($fix.applied)) { if ($null -eq $a) { continue }; Say-Fix ("已删除用户级 {0}" -f $a.name) }
          if ($fix.id) { Say-Info ("备份 id={0}，可用 -UndoFix 撤销；新开的终端才会生效" -f $fix.id) }
        } else { Say-Fail $fix.error -Id 'cfg.env_relay_user' }
      } else {
        Say-Info '可在面板点「修复」，或 CLI: -FixEnv（加 -DryRun 可预览）'
      }
    } elseif ($fixNames.Count -gt 0 -and $NoPause) {
      Say-Info 'NoPause 模式不自动修复；需要时请显式传 -FixEnv（或面板「修复」）'
    }
  }
}
$hp = [Environment]::GetEnvironmentVariable('HTTPS_PROXY','User'); if (-not $hp) { $hp = $env:HTTPS_PROXY }
if ($hp) { Say-Pass ("HTTPS_PROXY={0}" -f (Mask-Value -Value $hp -Kind Url)) } else { Say-Warn "未设置 HTTPS_PROXY（建议 $($cfg.proxyUrl)）" 5 -Id 'cfg.https_proxy' }

# ---------- 10. 残留配置扫描（只报告，不删除，不显示值） ----------
Say-Head '10. 第三方接口残留扫描'
$scan = @()
$cdir = Join-Path $env:USERPROFILE '.claude'
foreach ($f in @('settings.json','settings.local.json','config.json','.credentials.json')) { $scan += (Join-Path $cdir $f) }
$scan += (Join-Path $env:USERPROFILE '.claude.json')
$adir = Join-Path $env:APPDATA 'Claude'
if (Test-Path $adir) { $scan += @(Get-ChildItem $adir -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
$hostRx = 'kimi|moonshot|deepseek|openrouter|siliconflow|bigmodel|zhipu|dashscope|aliyuncs|volces|minimax|anyrouter|api2d|aicodemirror|packycode|claude-relay|gptsapi|ohmygpt|xiaomimimo'
$residue = 0
foreach ($f in ($scan | Select-Object -Unique)) {
  if (-not (Test-Path $f)) { continue }
  $txt = ''; try { $txt = [IO.File]::ReadAllText($f) } catch { continue }
  $hits = @()
  $keys = [regex]::Matches($txt, '"(ANTHROPIC_(BASE_URL|AUTH_TOKEN|API_KEY|MODEL|SMALL_FAST_MODEL)|OPENAI_API_KEY|apiKeyHelper|primaryApiKey)"\s*:') | ForEach-Object { $_.Groups[1].Value }
  if ($keys) { $hits += ('键: ' + (($keys | Select-Object -Unique) -join ',')) }
  $urls = [regex]::Matches($txt, 'https?://[A-Za-z0-9\.\-]+') | ForEach-Object { ([uri]$_.Value).Host } |
          Where-Object { $_ -match $hostRx } | Select-Object -Unique
  if ($urls) { $hits += ('第三方域名: ' + ($urls -join ',')) }
  if ($hits.Count) { $residue++; Say-Warn "$($f) → $($hits -join '；')" 6 -Id 'cfg.residue_claude' }
}
if ($residue -eq 0) { Say-Pass 'Claude 配置文件中没有第三方接口 / API Key 残留' }
$npmDir = $cfg.npmGlobalDir
if ($npmDir -and (Test-Path $npmDir)) {
  $helpers = @(Get-ChildItem $npmDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^claude-(kimi|deepseek|model|models|multi)[\w\-]*\.(ps1|cmd|bat)$' } | ForEach-Object { $_.Name })
  if ($helpers.Count) { Say-Warn ("$($npmDir) 有第三方模型切换脚本: " + ($helpers -join ', ') + "（运行后会让 Claude Code 走第三方接口；未删除）") 4 -Id 'cfg.residue_scripts' }
  else { Say-Pass '没有第三方模型切换脚本' }
}

# ---------- 11. 其他 ----------
Say-Head '11. 其他'
$ui = (Get-UICulture).Name
if ($ui -match '^zh') { Say-Note "系统界面语言为 $($ui)（一般不影响，可忽略）" -Id 'locale.system_lang' } else { Say-Pass "系统界面语言 $($ui)" }
if ($cfg.claudeAumid -or ($cfg.claudeExe -and (Test-Path $cfg.claudeExe))) { Say-Pass 'Claude 桌面版已安装' } else { Say-Warn '没找到 Claude 桌面版（可在 preflight.json 里填写 claudeExe）' 5 -Id 'cfg.claude_desktop' }
if (Get-Command claude -ErrorAction SilentlyContinue) { Say-Pass 'Claude Code CLI 已安装' } else { Say-Note '未找到 claude CLI（仅影响命令行版）' -Id 'cfg.claude_cli' }


# ---------- 12. 浏览器环境 ----------
Say-Head '12. 浏览器环境'
$script:BrowserStaticWarnUsed = 0
$script:BrowserStaticWarnCap = 20
function Soft-BrowserWarn([string]$t, [int]$w = 5, [string]$Id = '') {
  $left = $script:BrowserStaticWarnCap - $script:BrowserStaticWarnUsed
  if ($left -le 0) { Say-Info $t; return }
  $use = [Math]::Min($w, $left)
  $script:BrowserStaticWarnUsed += $use
  Say-Warn $t $use -Id $Id
}
function Read-PrefText([string]$path) {
  $tmp = Join-Path $env:TEMP ('csl-pref-' + [guid]::NewGuid().ToString('n'))
  try {
    Copy-Item -LiteralPath $path -Destination $tmp -Force -ErrorAction Stop
    $txt = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8)
  } catch {
    try {
      $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
      $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
      $txt = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
    } catch { return $null }
  } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  return $txt
}
function Get-JsonStr([string]$txt, [string]$key) {
  if (-not $txt) { return $null }
  $m = [regex]::Match($txt, '"' + [regex]::Escape($key) + '"\s*:\s*"((?:\\.|[^"\\])*)"')
  if ($m.Success) { return $m.Groups[1].Value } else { return $null }
}
function Test-LangMismatch([string]$langs, [string]$loc) {
  # en* never reported. Otherwise compare base language with exit-IP country's common languages.
  # Mismatch -> caller should Say-Warn with weight 0 (建议修, 不扣分).
  if (-not $langs -or -not $loc) { return $false }
  $first = (($langs -split ',')[0]).Trim().ToLowerInvariant()
  if (-not $first) { return $false }
  if ($first.StartsWith('en')) { return $false }
  $cc = $loc.ToUpperInvariant()
  $base = ($first -split '-')[0]
  $map = @{
    'zh' = @('CN','TW','HK','MO','SG')
    'ja' = @('JP')
    'ko' = @('KR')
    'de' = @('DE','AT','CH','LI')
    'fr' = @('FR','BE','CH','LU','MC','CA')
    'es' = @('ES','MX','AR','CO','CL','PE','VE','EC','GT','CU','BO','DO','HN','PY','SV','NI','CR','PA','UY','PR')
    'pt' = @('PT','BR','AO','MZ')
    'ru' = @('RU','BY','KZ','KG')
    'it' = @('IT','CH','SM','VA')
    'nl' = @('NL','BE','SR')
    'ar' = @('SA','AE','EG','IQ','JO','KW','LB','MA','OM','QA','SY','TN','YE','BH','DZ','LY','SD')
    'th' = @('TH')
    'vi' = @('VN')
    'id' = @('ID')
    'ms' = @('MY','BN','SG')
    'tr' = @('TR','CY')
    'pl' = @('PL')
    'uk' = @('UA')
    'hi' = @('IN')
  }
  if ($map.ContainsKey($base)) {
    return -not ($cc -in $map[$base])
  }
  # Unknown language with region tag: warn when region != exit country
  if ($first -match '^[a-z]{2}-([a-z]{2})$') {
    return ($Matches[1].ToUpperInvariant() -ne $cc)
  }
  return $false
}

$browserRoots = @(
  @{ Name = 'Chrome'; Path = (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data') },
  @{ Name = 'Edge'; Path = (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data') },
  @{ Name = 'Brave'; Path = (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data') }
)
$foundBrowser = $false
foreach ($b in $browserRoots) {
  if (-not (Test-Path -LiteralPath $b.Path)) { continue }
  $profiles = @(Get-ChildItem -LiteralPath $b.Path -Directory -ErrorAction SilentlyContinue | Where-Object {
    ($_.Name -eq 'Default' -or $_.Name.StartsWith('Profile ')) -and ($_.FullName -notmatch 'panel-edge')
  })
  foreach ($prof in $profiles) {
    $prefPath = Join-Path $prof.FullName 'Preferences'
    if (-not (Test-Path -LiteralPath $prefPath)) { continue }
    $foundBrowser = $true
    $txt = Read-PrefText $prefPath
    if (-not $txt) { Say-Info "$($b.Name) · $($prof.Name): 无法读取 Preferences"; continue }
    # Label always includes profile directory name; optional profile.name from JSON as secondary.
    $dirName = $prof.Name
    $displayName = $null
    $langs = $null
    try {
      $prefObj = $txt | ConvertFrom-Json -ErrorAction Stop
      if ($prefObj.profile -and $prefObj.profile.PSObject.Properties['name'] -and $prefObj.profile.name) {
        $displayName = [string]$prefObj.profile.name
      }
      if ($prefObj.intl -and $prefObj.intl.PSObject.Properties['accept_languages']) {
        $langs = [string]$prefObj.intl.accept_languages
      }
    } catch { }
    if (-not $langs) { $langs = Get-JsonStr $txt 'accept_languages' }
    $label = "$($b.Name) · $dirName"
    if ($displayName -and $displayName -ne $dirName -and $displayName -ne 'Person 1') {
      $label = "$($b.Name) · $dirName（$displayName）"
    }
    $webrtc = $null
    $wm = [regex]::Match($txt, '"ip_handling_policy"\s*:\s*"([^"]+)"')
    if ($wm.Success) { $webrtc = $wm.Groups[1].Value }
    if ($webrtc -eq 'disable_non_proxied_udp') {
      Say-Pass "${label}: WebRTC=disable_non_proxied_udp"
    } elseif ($webrtc) {
      Soft-BrowserWarn "${label}: WebRTC=$webrtc（建议 disable_non_proxied_udp 或用扩展禁用）" 5 -Id 'net.browser_webrtc_chromium'
    } else {
      Soft-BrowserWarn "${label}: 未设置 webrtc.ip_handling_policy，可能暴露真实/局域网 IP（建议 disable_non_proxied_udp）" 5 -Id 'net.browser_webrtc_chromium'
    }
    if ($langs) {
      if (Test-LangMismatch $langs $cfg.expectedLoc) {
        Say-Warn "${label}: 语言 $langs 与出口地区 $($cfg.expectedLoc) 不一致" 0 -Id 'locale.browser_lang_static'
      } else {
        Say-Info "${label}: 语言 $langs"
      }
    }
    if ($txt -match '(?i)switchyomega|foxyproxy|proxy\s*switch|webrtc.?leak|canvas.?blocker|fingerprint|指纹|CanvasFingerprint|WebRTC Control') {
      Say-Info "${label}: 检测到代理/指纹相关扩展（仅提示）"
    }
  }
}
if (-not $foundBrowser) { Say-Info '未找到 Chrome / Edge / Brave 用户配置（跳过静态配置检查）' }

$ffRoot = Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles'
if (Test-Path -LiteralPath $ffRoot) {
  foreach ($fp in @(Get-ChildItem -LiteralPath $ffRoot -Directory -ErrorAction SilentlyContinue)) {
    $pj = Join-Path $fp.FullName 'prefs.js'
    if (-not (Test-Path -LiteralPath $pj)) { continue }
    $ptxt = ''; try { $ptxt = [IO.File]::ReadAllText($pj) } catch { continue }
    $m = [regex]::Match($ptxt, 'user_pref\("media\.peerconnection\.enabled"\s*,\s*(true|false)\)')
    if ($m.Success) {
      if ($m.Groups[1].Value -eq 'false') { Say-Info "Firefox「$($fp.Name)」: WebRTC 已关闭" }
      else { Soft-BrowserWarn "Firefox「$($fp.Name)」: media.peerconnection.enabled=true，可能暴露 IP" 5 -Id 'net.browser_webrtc_firefox' }
    } else {
      Soft-BrowserWarn "Firefox「$($fp.Name)」: 未关闭 media.peerconnection.enabled（默认开启）" 5 -Id 'net.browser_webrtc_firefox'
    }
  }
}

$bcPath = Join-Path $script:Root 'browser-check.json'
if (-not (Test-Path -LiteralPath $bcPath)) {
  Say-Info '实时浏览器检查（WebRTC/时区/语言）请从检查面板运行；命令行模式跳过，不扣分'
} else {
  $raw = $null; try { $raw = [IO.File]::ReadAllText($bcPath, [Text.Encoding]::UTF8) } catch {}
  $bc = $null; if ($raw) { try { $bc = $raw | ConvertFrom-Json } catch { Say-Warn 'browser-check.json 解析失败' 3 -Id 'browser.check_parse' } }
  if ($bc) {
    $ts = $null
    if ($bc.ts) {
      try {
        $ts = [datetime]::Parse(
          [string]$bc.ts,
          [Globalization.CultureInfo]::InvariantCulture,
          [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
        )
      } catch {
        try { $ts = [datetime]::Parse([string]$bc.ts, $null, [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime() } catch {}
      }
    }
    if (-not $ts -or [math]::Abs((([datetime]::UtcNow) - $ts).TotalMinutes) -gt 3) {
      Say-Info 'browser-check.json 超过 3 分钟或无时间戳，视为过期；请从面板重新检查（不扣分）'
    } else {
      Say-Info ("实时快照 " + $ts.ToUniversalTime().ToString('HH:mm:ss') + ' UTC')
      $srflx = @(); $hostC = @(); $v6extra = @()
      if ($bc.webrtc) {
        if ($bc.webrtc.srflx) { $srflx = @($bc.webrtc.srflx | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
        if ($bc.webrtc.host) { $hostC = @($bc.webrtc.host | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
        if ($bc.webrtc.ipv6) { $v6extra = @($bc.webrtc.ipv6 | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
      }
      $pubV4 = @($srflx | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
      $pubV6 = @(@($srflx | Where-Object { $_ -match ':' }) + $v6extra | Select-Object -Unique)
      $expectIp = $(if ($cfg.expectedIp) { [string]$cfg.expectedIp } else { [string]$exitIp })
      if ($pubV4.Count -eq 0 -and $pubV6.Count -eq 0) {
        Say-Info 'WebRTC 未收集到 srflx 公网候选（可能已禁用，属好事）'
      } else {
        if ($pubV4.Count) {
          $uniq = @($pubV4 | Select-Object -Unique)
          $bad = @($uniq | Where-Object { $expectIp -and $_ -ne $expectIp })
          if ($expectIp -and $bad.Count -eq 0) { Say-Pass "WebRTC 公网 IP 与出口一致: $($uniq[0])" }
          elseif ($expectIp -and $bad.Count) { Say-Fail ("WebRTC 公网 IP 与出口不一致: WebRTC=" + ($uniq -join ',') + " 期望=$expectIp") -Id 'exit.webrtc_srflx' }
          else { Say-Info ("WebRTC 公网 IP: " + ($uniq -join ',')) }
        }
        if ($pubV6.Count) { Say-Warn ("WebRTC 发现公网 IPv6: " + ($pubV6 -join ',') + "（可能绕过代理）") 8 -Id 'exit.webrtc_ipv6' }
      }
      $mdns = @($hostC | Where-Object { $_ -match '\.local$' })
      if ($mdns.Count) { Say-Info ("WebRTC host 含 mDNS（正常）: " + ($mdns -join ',')) }

      $btz = [string]$bc.timezone
      $expectIana = [string]$cfg.expectedTzIana
      if (-not $expectIana -and $cfg.timezone) {
        if ([string]$cfg.timezone -match '/') { $expectIana = [string]$cfg.timezone }
        else { $expectIana = Convert-WindowsToIana ([string]$cfg.timezone) }
      }
      if ($btz -and $expectIana) {
        if ($btz -eq $expectIana) { Say-Pass "浏览器时区 $btz 与出口一致" }
        else { Say-Warn "浏览器时区 $btz 与出口时区 $expectIana 不一致" 8 -Id 'locale.browser_tz_live' }
      } elseif ($btz) { Say-Info "浏览器时区: $btz（尚未记住出口 IANA 时区）" }

      $blang = [string]$bc.language
      if ((-not $blang) -and $bc.languages) { $blang = [string](@($bc.languages)[0]) }
      if ($blang -and $cfg.expectedLoc) {
        if (Test-LangMismatch $blang $cfg.expectedLoc) { Say-Warn "浏览器语言 $blang 与出口地区 $($cfg.expectedLoc) 不一致" 0 -Id 'locale.browser_lang_live' }
        else { Say-Pass "浏览器语言 $blang" }
      } elseif ($blang) { Say-Info "浏览器语言: $blang" }

      if ($bc.webdriver -eq $true) { Say-Warn 'navigator.webdriver=true（自动化/被驱动环境）' 5 -Id 'auto.webdriver' }
      else { Say-Pass 'navigator.webdriver 未开启' }
    }
  }
}


# ---------- 评分（单一入口：claude-rules.ps1） ----------
$fails = @($script:Items | Where-Object Level -eq 'FAIL')
$warns = @($script:Items | Where-Object Level -eq 'WARN')
$notes = @($script:Items | Where-Object Level -eq 'NOTE')

# Map checks (each carries its real rules/checks.json id; unmapped ones become meta.unmapped / status=error) → score (weights already include Soft-BrowserWarn cap)
$script:CslRulesCatalog = $null
$script:CslScoreResult = $null
$script:CslScoreMapped = @()
$script:CslUnmappedItems = New-Object System.Collections.ArrayList
try {
  $script:CslRulesCatalog = Get-CslRulesCatalog
  $script:CslScoreResult = Invoke-CslPreflightScoring @($script:Items) $script:CslRulesCatalog -HideIp:$HideIp
  $score = [int]$script:CslScoreResult.score
  if ($script:CslUnmappedItems.Count -gt 0) {
    Write-Host ("  [提示] 内部：{0} 条检查项没有有效的规则 id（{1}），JSON 里记为 meta.unmapped / status=error，分数照扣" -f $script:CslUnmappedItems.Count, $script:CslUnmappedItems[0].Reason) -ForegroundColor DarkGray
  }
} catch {
  # Catalog missing → fall back to sum of weights (should not happen in a full checkout)
  Write-Host ("  [提示] 规则评分模块不可用，回退权重求和: " + $_) -ForegroundColor DarkGray
  $lost = ($script:Items | Measure-Object -Property Weight -Sum).Sum; if (-not $lost) { $lost = 0 }
  $score = [Math]::Max(0, 100 - [int]$lost)
}

Write-Host ''
Write-Host '==============================================' -ForegroundColor Cyan
$sc = $(if ($fails.Count) { 'Red' } elseif ($score -ge 90) { 'Green' } else { 'Yellow' })
Write-Host "  一致性评分: $($score) / 100" -ForegroundColor $sc
if ($fails.Count) { Write-Host "  【必须修】$($fails.Count) 项" -ForegroundColor Red;    foreach ($i in $fails) { Write-Host "    - $($i.Text)" -ForegroundColor Red } }
if ($warns.Count) { Write-Host "  【建议修】$($warns.Count) 项" -ForegroundColor Yellow; foreach ($i in $warns) { Write-Host "    - $($i.Text)" -ForegroundColor Yellow } }
if ($notes.Count) { Write-Host "  【不用管】$($notes.Count) 项" -ForegroundColor DarkGray; foreach ($i in $notes) { Write-Host "    - $($i.Text)" -ForegroundColor DarkGray } }
if (-not ($fails.Count + $warns.Count + $notes.Count)) { Write-Host '  全部通过' -ForegroundColor Green }
Write-Host '==============================================' -ForegroundColor Cyan
$result = $(if ($fails.Count) { 'FAIL' } elseif ($warns.Count) { 'WARN' } else { 'PASS' })

if ($ExportIssues) {
  Write-Host ''
  Write-Host '-------- 问题说明（可复制） --------' -ForegroundColor Cyan
  $pack = Format-CslIssuePack -Items @($script:Items.ToArray()) -HideIp:$HideIp
  Write-Host $pack
  Write-Host '-------- 结束 --------' -ForegroundColor Cyan
}

# Structured JSON：只在 -Json 时写（R4a），并打印 CSL_JSON_PATH= 供机器读取
try {
  if ($script:CslScoreResult) {
    $verdict = $(if ($fails.Count -eq 0) { 'ok' } elseif ($Force) { 'force' } else { 'blocked' })
    $payload = New-CslPreflightResult -ScoreResult $script:CslScoreResult -Platform 'win' -Verdict $verdict
    $outJson = Save-CslPreflightResultJson -Result $payload -Json:$Json -JsonPath $JsonPath -Root $script:Root
    if ($Json -and $outJson) { Write-Host ("CSL_JSON_PATH=" + $outJson) -ForegroundColor DarkGray }
  }
} catch {
  if ($Json) { Write-Host ("CSL_JSON_ERROR=" + $_) -ForegroundColor Yellow }
}

# ---------- 启动 ----------
$launched = 'no'
if ($NoLaunch) {
  Write-Host '[NoLaunch] 测试模式：不启动 Claude，不启动后台监控。' -ForegroundColor Cyan
  $launched = 'nolaunch'
} elseif ($fails.Count -eq 0 -or $Force) {
  if ($fails.Count) { Write-Host "有 $($fails.Count) 项必须修，但使用了 -Force，仍然启动。" -ForegroundColor Red }
  if (Get-ClaudeProcesses) { Write-Host 'Claude 已在运行，切换到前台…' -ForegroundColor Green; $launched = 'front' }
  else { Write-Host '正在启动 Claude…' -ForegroundColor Green; $launched = 'yes' }
  if (-not (Start-ClaudeApp $cfg)) { Write-Host '找不到 Claude 桌面版，请先安装，或在 preflight.json 里填写 claudeExe' -ForegroundColor Red; $launched = 'notfound' }
  $mon = Join-Path $script:Root 'claude-monitor.ps1'
  if (Test-Path $mon) {
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$($mon)`"")
    Write-Host "已启动后台监控（每 $($cfg.monitorIntervalMin) 分钟检查一次）" -ForegroundColor Gray
  }
} else {
  Write-Host "有 $($fails.Count) 项必须修，未启动 Claude。修好后重新运行；确需强行启动可加 -Force。" -ForegroundColor Red
}

# ---------- 日志 ----------
$logLine = '{0} | score={1} | ip={2} | tz={3} | fail={4} | warn={5} | launch={6}{7}' -f $result, $score, $exitIp, $tz, $fails.Count, $warns.Count, $launched, $(if ($Force) { ' | force' } else { '' })
if ($fails.Count) { $logLine += ' | ' + (($fails | ForEach-Object { $_.Text }) -join '; ') }
Write-Log $logLine

if (-not $NoPause) {
  if ($fails.Count -and -not $Force) { Write-Host ''; Write-Host '按任意键退出' -ForegroundColor Gray; try { [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Read-Host | Out-Null } }
  else { Write-Host '5 秒后自动关闭…' -ForegroundColor Gray; Start-Sleep -Seconds 5 }
}
if ($fails.Count -and -not $Force) { exit 1 } else { exit 0 }
