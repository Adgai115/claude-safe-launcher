param([switch]$Force, [switch]$NoPause, [switch]$NoLaunch, [switch]$Relearn)
<#
  Claude 桌面版 启动前检查 + 自动设置（v3 通用版）
  用法: powershell -NoProfile -ExecutionPolicy Bypass -File claude-preflight.ps1 [-Force] [-NoPause] [-NoLaunch]
  -Force    : 即使有「必须修」项也启动 Claude
  -NoPause  : 结束时不等待按键
  -NoLaunch : 只检查，不启动/不切换 Claude，也不启动后台监控（测试用）
  -Relearn  : 忘掉记住的出口 IP / 节点 / 时区，按当前环境重新记住
  配置文件  : 同目录 preflight.json（controllerSecret 为敏感信息，不会被打印）
  依赖      : 同目录 claude-common.ps1、claude-monitor.ps1
#>
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'claude-common.ps1')
try { $Host.UI.RawUI.WindowTitle = 'Claude 安全启动 - 启动前检查' } catch {}
$cfg = Load-Config
if ($Relearn) { Save-Learned $cfg @{ expectedIp = ''; expectedLoc = ''; expectedNode = ''; timezone = ''; expectedTzIana = '' } }

# ---------- 输出与评分 ----------
# FAIL = 必须修（默认扣 25）  WARN = 建议修（默认扣 8）  NOTE = 不用管（0 分）
$script:Items = New-Object System.Collections.ArrayList
function Add-Item($level, $t, $w) { [void]$script:Items.Add([pscustomobject]@{ Level = $level; Text = $t; Weight = $w }) }
function Say-Head($t) { Write-Host ''; Write-Host "== $($t)" -ForegroundColor Cyan }
function Say-Pass($t) { Write-Host "  [通过] $($t)" -ForegroundColor Green }
function Say-Info($t) { Write-Host "  [信息] $($t)" -ForegroundColor Gray }
function Say-Fix($t)  { Write-Host "  [修复] $($t)" -ForegroundColor Yellow }
function Say-Note($t) { Write-Host "  [提示] $($t)" -ForegroundColor DarkGray; Add-Item 'NOTE' $t 0 }
function Say-Warn($t, $w = 8)  { Write-Host "  [警告] $($t)" -ForegroundColor Yellow; Add-Item 'WARN' $t $w }
function Say-Fail($t, $w = 25) { Write-Host "  [失败] $($t)" -ForegroundColor Red; Add-Item 'FAIL' $t $w }

Write-Host '==============================================' -ForegroundColor Cyan
Write-Host '   Claude 桌面版 启动前检查 v3（通用版）' -ForegroundColor Cyan
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
    else { Say-Fail "Clash Verge 未运行，也没找到安装位置（可在 preflight.json 里填写 clashExe）" }
  } else { Say-Info 'Clash Verge 已运行，但 TUN 未就绪，等待中…' }
  $deadline = (Get-Date).AddSeconds(30)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    $mihomo = Get-ProxyCore
    $tun = Get-TunAdapter
    if ($mihomo -and $tun -and $tun.Status -eq 'Up') { break }
  }
}
if ($mihomo) { Say-Pass "代理内核 $(@($mihomo)[0].ProcessName) 运行中 (PID $(@($mihomo)[0].Id))" } else { Say-Fail '代理内核 (mihomo) 未运行' }
if ($tun -and $tun.Status -eq 'Up') { Say-Pass "TUN 网卡 $($tun.Name) 已启用" }
else { Say-Fail '30 秒内 TUN 网卡未启用。请在 Clash Verge 里打开「虚拟网卡模式 (TUN)」' }

# ---------- 2. 时区 ----------
Say-Head '2. 系统时区'
$tz = (Get-TimeZone).Id
if (-not $cfg.timezone) {
  $tr0 = Get-Trace 'https://claude.ai/cdn-cgi/trace'; $iana = $null
  if ($tr0['ip']) { try { $iana = ((Invoke-Curl @('-m','12',"https://ipinfo.io/$($tr0['ip'])/json")) | ConvertFrom-Json).timezone } catch {} }
  $win = Convert-IanaToWindows $iana
  if ($win) { Save-Learned $cfg @{ timezone = $win; expectedTzIana = [string]$iana }; Say-Fix "首次运行：按出口 IP 所在地（$($iana)）设定目标时区 $($win)" }
  else { Say-Note "无法按出口 IP 判断时区（$($iana)），跳过时区检查；可在 preflight.json 里手动填写 timezone" }
}
if ($cfg.timezone -and $tz -ne $cfg.timezone) {
  Say-Fix "当前时区 $($tz)，正在改为 $($cfg.timezone)"
  & tzutil.exe /s "$($cfg.timezone)" 2>&1 | Out-Null
  $tz = (& tzutil.exe /g).Trim()
}
if (-not $cfg.timezone) { } elseif ($tz -eq $cfg.timezone) { Say-Pass "时区: $($tz)" } else { Say-Fail "时区修改失败，当前仍为 $($tz)" }
$tzAuto = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\tzautoupdate' -ErrorAction SilentlyContinue).Start
if ($tzAuto -eq 4) { Say-Pass '自动设置时区已关闭 (tzautoupdate Start=4)' }
else { Say-Warn "自动设置时区未关闭 (Start=$($tzAuto))，时区可能被系统改回" 5 }

# ---------- 3. 节点锁定（mihomo 外部控制器） ----------
Say-Head '3. 节点锁定'
$ctlVer = Ctl-Get $cfg '/version'
if (-not $ctlVer) {
  Say-Warn "外部控制器 $($cfg.controllerUrl) 无法连接，无法确认/自动切回节点（请完全退出并重新打开 Clash Verge 使控制器生效）" 10
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
    if (-not $info) { Say-Note "Clash 里没有名为 $($g) 的策略组，跳过节点锁定（建议给 Claude 建一个专用分组，见 README）"; continue }
    if (-not $cfg.expectedNode) { Say-Info "$($g) 组 → $($info.now)（未设置锁定节点）"; continue }
    if ($info.now -eq $cfg.expectedNode) { Say-Pass "$($g) 组 → $($info.now)" }
    else {
      Say-Fix "$($g) 组当前为 $($info.now)，正在切回 $($cfg.expectedNode)"
      if (Ctl-SelectNode $cfg $g $cfg.expectedNode) {
        $after = Ctl-GetGroup $cfg $g
        if ($after.now -eq $cfg.expectedNode) { Say-Pass "$($g) 组已切回 $($after.now)"; $switched = $true }
        else { Say-Fail "$($g) 组切换后仍为 $($after.now)" }
      } else { Say-Fail "$($g) 组切换请求失败" }
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
  if ($localIp) { Say-Info "本机实测(ipify): $($localIp)" } else { Say-Warn '本机实测 IP 查询失败（ipinfo / ipify 都无响应）' 5 }
}
$edge = @()
foreach ($u in @('https://claude.ai/cdn-cgi/trace', 'https://api.anthropic.com/cdn-cgi/trace')) {
  $tr = Get-Trace $u
  $hostName = ([uri]$u).Host
  if ($tr['ip']) { $edge += [pscustomobject]@{ Host = $hostName; Ip = $tr['ip']; Loc = $tr['loc']; Colo = $tr['colo'] }; Say-Info "Claude 边缘($($hostName)): ip=$($tr['ip']) loc=$($tr['loc']) colo=$($tr['colo'])" }
  elseif ($hostName -eq 'claude.ai') { Say-Fail '无法访问 claude.ai/cdn-cgi/trace' }
  else { Say-Info "$($hostName) 不提供 trace（忽略）" }
}
$blocked = '^(CN|HK|MO|RU|KP|IR|CU|SY|BY)$'
$edgeLoc = $(if ($edge.Count) { $edge[0].Loc } else { '' })
if ($edgeLoc -and $edgeLoc -match $blocked) { Say-Fail "Claude 看到你位于 $($edgeLoc)，这是 Claude 不支持的地区，请检查代理规则是否让 Claude 走了代理" }
if (-not $cfg.expectedIp) {
  $ips = @(@($edge | ForEach-Object { $_.Ip }) + @($localIp) | Where-Object { $_ } | Select-Object -Unique)
  if ($edge.Count -and $edgeLoc -notmatch $blocked -and $ips.Count -eq 1) { Save-Learned $cfg @{ expectedIp = $ips[0]; expectedLoc = $edgeLoc }; Say-Fix "首次运行：记住当前出口 IP $($ips[0])（$($edgeLoc)），以后变化会提醒" }
  elseif ($ips.Count -gt 1) { Say-Warn ("各方看到的出口 IP 不一致，暂不记住: " + ($ips -join ', ')) 10 }
  elseif (-not $edge.Count) { Say-Warn '测不到 Claude 看到的出口 IP，暂不记住' 10 }
}
if ($cfg.expectedIp) { Say-Info "期望: $($cfg.expectedIp) loc=$($cfg.expectedLoc)" }
$all = @(); if ($cfg.expectedIp) { $all = @($edge | ForEach-Object { $_.Ip }); if ($localIp) { $all += $localIp } }
$bad = @($all | Where-Object { $_ -ne $cfg.expectedIp })
$badLoc = @($edge | Where-Object { $_.Loc -ne $cfg.expectedLoc })
if ($all.Count -gt 0 -and $bad.Count -eq 0 -and $badLoc.Count -eq 0) { Say-Pass "三方一致: $($cfg.expectedIp)" }
elseif ($all.Count -gt 0) { Say-Fail ("IP 不一致: 本机=$($localIp) 边缘=" + (($edge | ForEach-Object { "$($_.Host):$($_.Ip)/$($_.Loc)" }) -join ',') + " 期望=$($cfg.expectedIp)") }
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
  if ($risk -ge [int]$cfg.failRisk) { Say-Fail "$($line)（≥ $($cfg.failRisk)）" }
  elseif ($risk -ge [int]$cfg.warnRisk -or $pcd.proxy -eq 'yes') { Say-Warn "$($line)（风险偏高）" 10 }
  else { Say-Pass $line }
} else { Say-Warn 'proxycheck.io 查询失败（可能被限流）' 3 }
$ia = $null
try { $ia = (Invoke-Curl @('-m','12',"http://ip-api.com/json/$($qip)?fields=status,countryCode,isp,org,as,proxy,hosting,mobile")) | ConvertFrom-Json } catch {}
if ($ia -and $ia.status -eq 'success') {
  $line = "ip-api: $($ia.countryCode) $($ia.isp) / $($ia.as) proxy=$($ia.proxy) hosting=$($ia.hosting)"
  if ($ia.hosting -or $ia.proxy) { Say-Warn "$($line)（被标记为机房/代理）" 8 } else { Say-Pass $line }
} else { Say-Note 'ip-api 查询失败（忽略）' }

# ---------- 6. DNS ----------
Say-Head '6. DNS (fake-ip)'
$dns = Resolve-DnsName api.anthropic.com -Type A -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress } | Select-Object -First 1
if ($dns -and $dns.IPAddress -like '198.18.*') { Say-Pass "api.anthropic.com → $($dns.IPAddress)（fake-ip，由 Clash 接管）" }
elseif ($dns) { Say-Warn "api.anthropic.com → $($dns.IPAddress)，不是 fake-ip，DNS 可能未被 Clash 接管" 10 }
else { Say-Warn 'api.anthropic.com 解析失败' 5 }

# ---------- 7. IPv6 ----------
Say-Head '7. IPv6 泄露'
$v6 = & curl.exe --noproxy '*' -6 -s -m 8 https://api64.ipify.org 2>$null
if ($LASTEXITCODE -ne 0 -or -not $v6 -or ($v6 -notmatch ':')) { Say-Pass '无 IPv6 出口' }
else { Say-Fail "存在 IPv6 出口: $($v6)，可能绕过代理暴露真实位置" }

# ---------- 8. Anthropic API ----------
Say-Head '8. api.anthropic.com 连通性'
$tmp = [IO.Path]::GetTempFileName()
$code = & curl.exe --noproxy '*' -s -m 15 -o $tmp -w '%{http_code}' https://api.anthropic.com/v1/messages 2>$null
$body = ''; try { $body = [string](Get-Content $tmp -Raw -ErrorAction SilentlyContinue) } catch {}
Remove-Item $tmp -ErrorAction SilentlyContinue
$bodyOne = ($body -replace '\s+', ' ')
if ($code -in @('401','404','405')) { Say-Pass "HTTP $($code)（正常，未被地区封锁）" }
elseif ($code -eq '403') { Say-Fail ("HTTP 403，疑似地区封锁: " + $bodyOne.Substring(0, [Math]::Min(120, $bodyOne.Length))) }
elseif ($code -eq '000' -or -not $code) { Say-Fail '无法连接 api.anthropic.com' }
else { Say-Warn "HTTP $($code)（非预期状态码）" 5 }

# ---------- 9. 环境变量 ----------
Say-Head '9. 环境变量'
$envBad = @('ANTHROPIC_BASE_URL','ANTHROPIC_AUTH_TOKEN','ANTHROPIC_API_KEY','ANTHROPIC_MODEL','ANTHROPIC_SMALL_FAST_MODEL')
$found = @()
foreach ($n in $envBad) {
  if ([Environment]::GetEnvironmentVariable($n,'User') -or [Environment]::GetEnvironmentVariable($n,'Machine') -or [Environment]::GetEnvironmentVariable($n,'Process')) { $found += $n }
}
if ($found.Count -eq 0) { Say-Pass '没有 ANTHROPIC_BASE_URL / AUTH_TOKEN / API_KEY 等第三方中转变量' }
else {
  Say-Fail ("发现变量: " + ($found -join ', ') + "（会让 Claude Code 走第三方接口）")
  $ans = ''
  if (-not $NoPause) { try { $ans = Read-Host '  是否删除这些用户级变量？(y/N)' } catch {} }
  if ($ans -match '^[yY]') {
    foreach ($n in $found) { Remove-ItemProperty -Path 'HKCU:\Environment' -Name $n -ErrorAction SilentlyContinue; Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
    Say-Fix '已删除用户级变量（已打开的终端需重开才生效）'
  }
}
$hp = [Environment]::GetEnvironmentVariable('HTTPS_PROXY','User'); if (-not $hp) { $hp = $env:HTTPS_PROXY }
if ($hp) { Say-Pass "HTTPS_PROXY=$($hp)" } else { Say-Warn "未设置 HTTPS_PROXY（建议 $($cfg.proxyUrl)）" 5 }

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
  if ($hits.Count) { $residue++; Say-Warn "$($f) → $($hits -join '；')" 6 }
}
if ($residue -eq 0) { Say-Pass 'Claude 配置文件中没有第三方接口 / API Key 残留' }
$npmDir = $cfg.npmGlobalDir
if ($npmDir -and (Test-Path $npmDir)) {
  $helpers = @(Get-ChildItem $npmDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^claude-(kimi|deepseek|model|models|multi)[\w\-]*\.(ps1|cmd|bat)$' } | ForEach-Object { $_.Name })
  if ($helpers.Count) { Say-Warn ("$($npmDir) 有第三方模型切换脚本: " + ($helpers -join ', ') + "（运行后会让 Claude Code 走第三方接口；未删除）") 4 }
  else { Say-Pass '没有第三方模型切换脚本' }
}

# ---------- 11. 其他 ----------
Say-Head '11. 其他'
$ui = (Get-UICulture).Name
if ($ui -match '^zh') { Say-Note "系统界面语言为 $($ui)（一般不影响，可忽略）" } else { Say-Pass "系统界面语言 $($ui)" }
if ($cfg.claudeAumid -or ($cfg.claudeExe -and (Test-Path $cfg.claudeExe))) { Say-Pass 'Claude 桌面版已安装' } else { Say-Warn '没找到 Claude 桌面版（可在 preflight.json 里填写 claudeExe）' 5 }
if (Get-Command claude -ErrorAction SilentlyContinue) { Say-Pass 'Claude Code CLI 已安装' } else { Say-Note '未找到 claude CLI（仅影响命令行版）' }


# ---------- 12. 浏览器环境 ----------
Say-Head '12. 浏览器环境'
$script:BrowserStaticWarnUsed = 0
$script:BrowserStaticWarnCap = 20
function Soft-BrowserWarn([string]$t, [int]$w = 5) {
  $left = $script:BrowserStaticWarnCap - $script:BrowserStaticWarnUsed
  if ($left -le 0) { Say-Info $t; return }
  $use = [Math]::Min($w, $left)
  $script:BrowserStaticWarnUsed += $use
  Say-Warn $t $use
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
  if (-not $langs -or -not $loc) { return $false }
  $first = (($langs -split ',')[0]).Trim().ToLowerInvariant()
  $cc = $loc.ToUpperInvariant()
  if ($first.StartsWith('zh')) { return -not ($cc -in @('CN','TW','HK','MO','SG')) }
  if ($first -match '^([a-z]{2})-([a-z]{2})$') {
    $reg = $Matches[2].ToUpperInvariant()
    if ($reg -ne $cc -and -not $first.StartsWith('en')) { return $true }
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
    if (-not $txt) { Say-Info "$($b.Name)/$($prof.Name): 无法读取 Preferences"; continue }
    $pname = Get-JsonStr $txt 'name'; if (-not $pname) { $pname = $prof.Name }
    $webrtc = $null
    $wm = [regex]::Match($txt, '"ip_handling_policy"\s*:\s*"([^"]+)"')
    if ($wm.Success) { $webrtc = $wm.Groups[1].Value }
    $langs = Get-JsonStr $txt 'accept_languages'
    if ($webrtc -eq 'disable_non_proxied_udp') {
      Say-Pass "$($b.Name)「$pname」: WebRTC=disable_non_proxied_udp"
    } elseif ($webrtc) {
      Soft-BrowserWarn "$($b.Name)「$pname」: WebRTC=$webrtc（建议 disable_non_proxied_udp 或用扩展禁用）" 5
    } else {
      Soft-BrowserWarn "$($b.Name)「$pname」: 未设置 webrtc.ip_handling_policy，可能暴露真实/局域网 IP（建议 disable_non_proxied_udp）" 5
    }
    if ($langs) {
      if (Test-LangMismatch $langs $cfg.expectedLoc) {
        Soft-BrowserWarn "$($b.Name)「$pname」: 语言 $langs 与出口地区 $($cfg.expectedLoc) 不一致" 5
      } else {
        Say-Info "$($b.Name)「$pname」: 语言 $langs"
      }
    }
    if ($txt -match '(?i)switchyomega|foxyproxy|proxy\s*switch|webrtc.?leak|canvas.?blocker|fingerprint|指纹|CanvasFingerprint|WebRTC Control') {
      Say-Info "$($b.Name)「$pname」: 检测到代理/指纹相关扩展（仅提示）"
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
      else { Soft-BrowserWarn "Firefox「$($fp.Name)」: media.peerconnection.enabled=true，可能暴露 IP" 5 }
    } else {
      Soft-BrowserWarn "Firefox「$($fp.Name)」: 未关闭 media.peerconnection.enabled（默认开启）" 5
    }
  }
}

$bcPath = Join-Path $script:Root 'browser-check.json'
if (-not (Test-Path -LiteralPath $bcPath)) {
  Say-Note '实时浏览器检查（WebRTC/时区/语言）请从检查面板运行；命令行模式跳过，不扣分'
} else {
  $raw = $null; try { $raw = [IO.File]::ReadAllText($bcPath, [Text.Encoding]::UTF8) } catch {}
  $bc = $null; if ($raw) { try { $bc = $raw | ConvertFrom-Json } catch { Say-Warn 'browser-check.json 解析失败' 3 } }
  if ($bc) {
    $ts = $null
    if ($bc.ts) {
      try { $ts = [datetime]::Parse([string]$bc.ts, $null, [Globalization.DateTimeStyles]::RoundtripKind) } catch {
        try { $ts = [datetime]$bc.ts } catch {}
      }
    }
    if (-not $ts -or ((Get-Date) - $ts).TotalMinutes -gt 3) {
      Say-Note 'browser-check.json 超过 3 分钟或无时间戳，视为过期；请从面板重新检查（不扣分）'
    } else {
      Say-Info ("实时快照 " + $ts.ToString('HH:mm:ss'))
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
          elseif ($expectIp -and $bad.Count) { Say-Fail ("WebRTC 公网 IP 与出口不一致: WebRTC=" + ($uniq -join ',') + " 期望=$expectIp") }
          else { Say-Info ("WebRTC 公网 IP: " + ($uniq -join ',')) }
        }
        if ($pubV6.Count) { Say-Warn ("WebRTC 发现公网 IPv6: " + ($pubV6 -join ',') + "（可能绕过代理）") 8 }
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
        else { Say-Warn "浏览器时区 $btz 与出口时区 $expectIana 不一致" 8 }
      } elseif ($btz) { Say-Info "浏览器时区: $btz（尚未记住出口 IANA 时区）" }

      $blang = [string]$bc.language
      if ((-not $blang) -and $bc.languages) { $blang = [string](@($bc.languages)[0]) }
      if ($blang -and $cfg.expectedLoc) {
        if (Test-LangMismatch $blang $cfg.expectedLoc) { Say-Warn "浏览器语言 $blang 与出口地区 $($cfg.expectedLoc) 不一致" 5 }
        else { Say-Pass "浏览器语言 $blang" }
      } elseif ($blang) { Say-Info "浏览器语言: $blang" }

      if ($bc.webdriver -eq $true) { Say-Warn 'navigator.webdriver=true（自动化/被驱动环境）' 5 }
      else { Say-Pass 'navigator.webdriver 未开启' }
    }
  }
}


# ---------- 评分 ----------
$fails = @($script:Items | Where-Object Level -eq 'FAIL')
$warns = @($script:Items | Where-Object Level -eq 'WARN')
$notes = @($script:Items | Where-Object Level -eq 'NOTE')
$lost = ($script:Items | Measure-Object -Property Weight -Sum).Sum; if (-not $lost) { $lost = 0 }
$score = [Math]::Max(0, 100 - [int]$lost)
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
