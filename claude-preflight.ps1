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
param([switch]$Force, [switch]$NoPause, [switch]$NoLaunch, [switch]$Relearn)

. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'claude-common.ps1')
try { $Host.UI.RawUI.WindowTitle = 'Claude 安全启动 - 启动前检查' } catch {}
$cfg = Load-Config
if ($Relearn) { Save-Learned $cfg @{ expectedIp = ''; expectedLoc = ''; expectedNode = ''; timezone = '' } }

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
  if ($win) { Save-Learned $cfg @{ timezone = $win }; Say-Fix "首次运行：按出口 IP 所在地（$($iana)）设定目标时区 $($win)" }
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
