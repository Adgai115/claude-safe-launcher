# Claude 安全启动 · 主题面板（本地网页界面）
param(
  [switch]$TestMode
)
$dir = $PSScriptRoot
$pre = Join-Path $dir 'claude-preflight.ps1'
$htmlPath = Join-Path $dir 'claude-panel.html'
. (Join-Path $dir 'claude-common.ps1')
. (Join-Path $dir 'claude-envfix.ps1')
$stateFile = Join-Path $dir 'panel.json'
$logFile = Join-Path $dir 'preflight.log'
$srvLog = Join-Path $dir 'panel-server.log'
function SLog([string]$m) { try { Add-Content -LiteralPath $srvLog -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $m) -Encoding UTF8 } catch {} }
$port = 47831
# 仅 loopback：127.0.0.1 + localhost，禁止 0.0.0.0 / + / *
$urlLoopback = "http://127.0.0.1:$port/"
$urlLocalhost = "http://localhost:$port/"
$openUrl = $urlLocalhost
# CSL_PANEL_TESTMODE=1 仅由进程环境变量启用；请求体无法开关
$script:CslPanelTestMode = ($env:CSL_PANEL_TESTMODE -eq '1')
$script:CslPanelToken = New-CslSessionToken
# 绝不把 token 写入日志

function Open-Win {
  $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($edge) { Start-Process $edge -ArgumentList "--app=$openUrl --window-size=1040,880 --user-data-dir=`"$dir\panel-edge`" --no-first-run --no-default-browser-check" }
  else { $chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1; if ($chrome) { Start-Process $chrome -ArgumentList "--app=$openUrl --window-size=1040,880 --user-data-dir=`"$dir\panel-edge`" --no-first-run" } else { Start-Process $openUrl } }
}
function Test-Port { try { $c = New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $port); $c.Close(); $true } catch { $false } }
if (Test-Port) { if (-not $env:CSL_PANEL_NO_OPEN) { Open-Win }; return }

function Get-Theme { try { (Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json).theme } catch { 'anime' } }
function Send($ctx, [string]$body, [string]$type = 'application/json; charset=utf-8') {
  $b = [Text.Encoding]::UTF8.GetBytes($body); $r = $ctx.Response
  $r.ContentType = $type; $r.Headers.Add('Cache-Control', 'no-store'); $r.ContentLength64 = $b.Length
  # 故意不发送任何 Access-Control-Allow-* 头
  $r.OutputStream.Write($b, 0, $b.Length); $r.OutputStream.Close()
}
function Send-Forbidden($ctx, [string]$err) {
  $ctx.Response.StatusCode = 403
  Send $ctx (ConvertTo-Json @{ ok = $false; error = $err } -Compress)
}

function Read-JsonBody($req) {
  $len = [int]$req.ContentLength64
  if ($len -le 0 -or $len -ge 200000) { return $null }
  $buf = New-Object byte[] $len
  $read = 0
  while ($read -lt $len) { $n = $req.InputStream.Read($buf, $read, $len - $read); if ($n -le 0) { break }; $read += $n }
  try { return [Text.Encoding]::UTF8.GetString($buf, 0, $read) | ConvertFrom-Json } catch { return $null }
}

$l = New-Object Net.HttpListener
$l.Prefixes.Add($urlLoopback)
$l.Prefixes.Add($urlLocalhost)
$l.Start()
if (-not $env:CSL_PANEL_NO_OPEN) { Open-Win }
SLog "server start pid $PID loopback-only port $port"
trap { SLog ("FATAL: " + $_ + " @ " + $_.InvocationInfo.ScriptLineNumber); continue }
$job = @{ proc = $null; tmp = $null }
$last = Get-Date; $quit = $false
$task = $l.GetContextAsync()
while (-not $quit) {
  $ready = $false; try { $ready = $task.Wait(1000) } catch { $ready = $true }
  if (-not $ready) {
    $running = $job.proc -and -not $job.proc.HasExited
    if (((Get-Date) - $last).TotalSeconds -gt 45 -and -not $running) { break }
    continue
  }
  if ($task.IsFaulted -or $task.IsCanceled) { SLog ("listener task fault: " + $task.Exception); $task = $l.GetContextAsync(); continue }
  $ctx = $task.Result; $task = $l.GetContextAsync(); $last = Get-Date
  try {
    $path = $ctx.Request.Url.AbsolutePath
    $method = $ctx.Request.HttpMethod
    $isApi = $path.StartsWith('/api/')
    $hostHdr = [string]$ctx.Request.Headers['Host']

    # SEC-01: every request (including '/' which carries the token) must pass the Host allowlist
    if (-not (Test-CslPanelHostAllowed -HostHeader $hostHdr -Port $port)) {
      Send-Forbidden $ctx 'forbidden host'
      continue
    }

    if ($isApi) {
      $origin = [string]$ctx.Request.Headers['Origin']
      if ([string]::IsNullOrEmpty($origin)) { $origin = $null }
      $ctype = [string]$ctx.Request.ContentType
      $tok = [string]$ctx.Request.Headers['X-CSL-Token']
      $gate = Test-CslPanelApiRequest -Method $method -HostHeader $hostHdr -Origin $origin -ContentType $ctype -TokenHeader $tok -ExpectedToken $script:CslPanelToken -Port $port -IsApiPath
      if (-not $gate.ok) {
        Send-Forbidden $ctx $gate.error
        continue
      }
    }

    $q = $ctx.Request.QueryString
    switch ($path) {
      '/' {
        $h = [IO.File]::ReadAllText($htmlPath, [Text.Encoding]::UTF8)
        $h = $h.Replace('__THEME__', [string](Get-Theme))
        $h = $h.Replace('__CSL_TOKEN__', $script:CslPanelToken)
        $h = $h.Replace('__CSL_TESTMODE__', $(if ($script:CslPanelTestMode) { '1' } else { '0' }))
        Send $ctx $h 'text/html; charset=utf-8'
      }
      '/api/run' {
        if ($method -ne 'POST') { Send-Forbidden $ctx 'forbidden method'; break }
        if (-not ($job.proc -and -not $job.proc.HasExited)) {
          if ($job.tmp) { Remove-Item $job.tmp -Force -ErrorAction SilentlyContinue }
          $job.tmp = [IO.Path]::GetTempFileName()
          $extra = @('-NoPause'); if ($q['launch'] -ne '1') { $extra += '-NoLaunch' }; if ($q['relearn'] -eq '1') { $extra += '-Relearn' }
          if ($script:CslPanelTestMode) { $extra += '-TestMode'; $extra += "-FixVarPattern 'CSL_TEST_ANTHROPIC_*'" }
          $flagStr = ($extra -join ' ')
          $cmd = "[Console]::OutputEncoding=[Text.Encoding]::UTF8; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$pre' $flagStr *>&1 | ForEach-Object { Add-Content -LiteralPath '$($job.tmp)' -Value (""`$_"") -Encoding UTF8 }"
          $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
          $job.proc = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc" -WindowStyle Hidden -PassThru
        }
        Send $ctx '{"ok":true}'
      }
      '/api/poll' {
        $from = 0; [void][int]::TryParse([string]$q['from'], [ref]$from); $done = (-not $job.proc) -or $job.proc.HasExited
        $lines = @()
        if ($job.tmp -and (Test-Path $job.tmp)) {
          $all = $null; for ($k = 0; $k -lt 5 -and $null -eq $all; $k++) { try { $fs = [IO.File]::Open($job.tmp, 'Open', 'Read', 'ReadWrite,Delete'); $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8); $all = $sr.ReadToEnd(); $sr.Close() } catch { Start-Sleep -Milliseconds 40 } }
          if ($null -eq $all) { $all = [string]::Empty; $done = $false }
          $parts = $all -split "`r?`n"
          $complete = @(if ($done) { $parts } elseif ($parts.Count -gt 1) { $parts[0..($parts.Count - 2)] })
          if ($complete.Count -gt $from) { $lines = @($complete[$from..($complete.Count - 1)]) }
          $nextIdx = [Math]::Max($from, $complete.Count)
        } else { $nextIdx = $from }
        Send $ctx (ConvertTo-Json @{ lines = [object[]]$lines; next = $nextIdx; done = [bool]$done } -Compress)
      }
      '/api/claude' {
        $r = [bool](Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*WindowsApps\Claude_*' })
        Send $ctx (ConvertTo-Json @{ running = $r } -Compress)
      }
      '/api/theme' {
        if ($method -ne 'POST') { Send-Forbidden $ctx 'forbidden method'; break }
        $t = [string]$q['t']; if ($t -match '^[a-z]+$') { (@{ theme = $t } | ConvertTo-Json) | Set-Content $stateFile -Encoding UTF8 }
        Send $ctx '{"ok":true}'
      }
      '/api/log' {
        if ($method -ne 'POST') { Send-Forbidden $ctx 'forbidden method'; break }
        if (Test-Path $logFile) { Start-Process notepad.exe $logFile }
        Send $ctx '{"ok":true}'
      }
      '/api/ping' { Send $ctx '{"ok":true}' }
      '/api/quit' {
        if ($method -ne 'POST') { Send-Forbidden $ctx 'forbidden method'; break }
        Send $ctx '{"ok":true}'; $quit = $true
      }
      '/api/browser' {
        if ($method -ne 'POST') { Send-Forbidden $ctx 'forbidden method'; break }
        $bodyObj = Read-JsonBody $ctx.Request
        if ($null -eq $bodyObj) { $ctx.Response.StatusCode = 400; Send $ctx '{"ok":false,"error":"bad json"}'; break }
        try {
          $body = ($bodyObj | ConvertTo-Json -Depth 6 -Compress)
          if ($body -notmatch '"ts"') {
            $utcTs = [datetime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            $bodyObj | Add-Member -NotePropertyName ts -NotePropertyValue $utcTs -Force
            $body = ($bodyObj | ConvertTo-Json -Depth 6 -Compress)
          }
          $out = Join-Path $dir 'browser-check.json'
          [IO.File]::WriteAllText($out, $body, [Text.UTF8Encoding]::new($false))
          SLog 'browser-check.json written'
          Send $ctx '{"ok":true}'
        } catch { SLog ("browser json error: " + $_); $ctx.Response.StatusCode = 400; Send $ctx '{"ok":false}' }
      }
      '/api/envfix' {
        if ($method -ne 'POST') { Send-Forbidden $ctx 'forbidden method'; break }
        $bodyObj = Read-JsonBody $ctx.Request
        $action = 'plan'
        if ($bodyObj -and $bodyObj.action) { $action = [string]$bodyObj.action }
        $cfg = Load-Config
        # CSL_PANEL_TESTMODE=1：强制 TestMode + 固定 CSL_TEST_ANTHROPIC_*；请求体 patterns/testMode 一律忽略
        # 环境变量未设：与原先一致（忽略请求体 patterns/testMode，用配置/默认，排除 CSL_TEST_*）
        $testMode = [bool]$script:CslPanelTestMode
        if ($script:CslPanelTestMode) {
          $patterns = @('CSL_TEST_ANTHROPIC_*')
        } else {
          $patterns = Get-CslFixVarPatterns -Cfg $cfg -FixVarPattern $null
        }
        try {
          switch ($action) {
            'list' {
              $list = @(Get-CslEnvFixList)
              Send $ctx (ConvertTo-Json @{ ok = $true; items = $list } -Depth 6 -Compress)
            }
            'plan' {
              $fix = Invoke-CslEnvFix -Patterns $patterns -TestMode:$testMode -DryRun
              Send $ctx (ConvertTo-Json @{
                ok = [bool]$fix.ok; error = $fix.error; plan = @($fix.plan); hint = '新开的终端才会生效'
              } -Depth 6 -Compress)
            }
            'apply' {
              $fix = Invoke-CslEnvFix -Patterns $patterns -TestMode:$testMode
              Send $ctx (ConvertTo-Json @{
                ok = [bool]$fix.ok; error = $fix.error; id = $fix.id; plan = @($fix.plan); applied = @($fix.applied); hint = $(if ($fix.hint) { $fix.hint } else { '新开的终端才会生效' }); exitCode = $fix.exitCode
              } -Depth 6 -Compress)
            }
            'undo-plan' {
              $id = $null
              if ($bodyObj -and $bodyObj.id) { $id = [string]$bodyObj.id }
              $undo = Invoke-CslEnvUndo -Id $id -DryRun -DefaultConflictDecision skip
              Send $ctx (ConvertTo-Json @{
                ok = [bool]$undo.ok; error = $undo.error; id = $undo.id; dryRun = $true
                conflicts = @($undo.conflicts); pending = @($undo.pending); skipped = @($undo.skipped)
                hint = $(if ($undo.hint) { $undo.hint } else { '新开的终端才会生效' }); exitCode = $undo.exitCode
              } -Depth 6 -Compress)
            }
            'undo-apply' {
              $id = $null
              if ($bodyObj -and $bodyObj.id) { $id = [string]$bodyObj.id }
              $def = 'skip'
              if ($bodyObj -and $bodyObj.PSObject.Properties['defaultConflictDecision'] -and $bodyObj.defaultConflictDecision) {
                $def = [string]$bodyObj.defaultConflictDecision
              }
              if ($def -ne 'overwrite' -and $def -ne 'skip') {
                $ctx.Response.StatusCode = 400
                Send $ctx '{"ok":false,"error":"invalid defaultConflictDecision"}'
                break
              }
              $dec = @{}
              if ($bodyObj -and $bodyObj.PSObject.Properties['decisions'] -and $bodyObj.decisions) {
                $dobj = $bodyObj.decisions
                if ($dobj -is [hashtable]) {
                  foreach ($k in @($dobj.Keys)) { $dec[[string]$k] = [string]$dobj[$k] }
                } else {
                  foreach ($p in $dobj.PSObject.Properties) { $dec[$p.Name] = [string]$p.Value }
                }
              }
              $planChk = Invoke-CslEnvUndo -Id $id -DryRun -DefaultConflictDecision skip
              if (-not $planChk.ok) {
                $ctx.Response.StatusCode = 400
                Send $ctx (ConvertTo-Json @{ ok = $false; error = $planChk.error } -Compress)
                break
              }
              $allowed = @($planChk.conflicts | ForEach-Object { [string]$_.name } | Where-Object { $_ })
              $vdec = Test-CslUndoDecisionsValid -Decisions $dec -AllowedNames $allowed
              if (-not $vdec.ok) {
                $ctx.Response.StatusCode = 400
                Send $ctx (ConvertTo-Json @{ ok = $false; error = $vdec.error } -Compress)
                break
              }
              $undo = Invoke-CslEnvUndo -Id $id -DefaultConflictDecision $def -ConflictDecisions $dec
              Send $ctx (ConvertTo-Json @{
                ok = [bool]$undo.ok; error = $undo.error; id = $undo.id
                restored = @($undo.restored); skipped = @($undo.skipped); conflicts = @($undo.conflicts)
                hint = $(if ($undo.hint) { $undo.hint } else { '新开的终端才会生效' }); exitCode = $undo.exitCode
              } -Depth 6 -Compress)
            }
            'undo' {
              # 兼容旧客户端：等同 undo-plan 提示改用新流程
              $ctx.Response.StatusCode = 400
              Send $ctx '{"ok":false,"error":"use undo-plan then undo-apply"}'
            }
            default {
              $ctx.Response.StatusCode = 400
              Send $ctx '{"ok":false,"error":"unknown action"}'
            }
          }
        } catch {
          SLog ("envfix error: " + $_)
          $ctx.Response.StatusCode = 500
          Send $ctx (ConvertTo-Json @{ ok = $false; error = [string]$_ } -Compress)
        }
      }
      default { $ctx.Response.StatusCode = 404; Send $ctx '{}' }
    }
  } catch { SLog ("request error " + $ctx.Request.Url.PathAndQuery + ": " + $_); try { $ctx.Response.StatusCode = 500; Send $ctx '{}' } catch {} }
}
SLog "server exit (idle or quit)"; $l.Stop()
