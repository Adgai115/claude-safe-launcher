# Claude 安全启动 · 主题面板（本地网页界面）
$dir = $PSScriptRoot
$pre = Join-Path $dir 'claude-preflight.ps1'
$htmlPath = Join-Path $dir 'claude-panel.html'
$stateFile = Join-Path $dir 'panel.json'
$logFile = Join-Path $dir 'preflight.log'
$srvLog = Join-Path $dir 'panel-server.log'
function SLog([string]$m) { try { Add-Content -LiteralPath $srvLog -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $m) -Encoding UTF8 } catch {} }
$port = 47831
$url = "http://localhost:$port/"

function Open-Win {
  $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($edge) { Start-Process $edge -ArgumentList "--app=$url --window-size=1040,880 --user-data-dir=`"$dir\panel-edge`" --no-first-run --no-default-browser-check" }
  else { $chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1; if ($chrome) { Start-Process $chrome -ArgumentList "--app=$url --window-size=1040,880 --user-data-dir=`"$dir\panel-edge`" --no-first-run" } else { Start-Process $url } }
}
function Test-Port { try { $c = New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $port); $c.Close(); $true } catch { $false } }
if (Test-Port) { if (-not $env:CSL_PANEL_NO_OPEN) { Open-Win }; return }

function Get-Theme { try { (Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json).theme } catch { 'anime' } }
function Send($ctx, [string]$body, [string]$type = 'application/json; charset=utf-8') {
  $b = [Text.Encoding]::UTF8.GetBytes($body); $r = $ctx.Response
  $r.ContentType = $type; $r.Headers.Add('Cache-Control', 'no-store'); $r.ContentLength64 = $b.Length
  $r.OutputStream.Write($b, 0, $b.Length); $r.OutputStream.Close()
}

$l = New-Object Net.HttpListener; $l.Prefixes.Add($url); $l.Start()
if (-not $env:CSL_PANEL_NO_OPEN) { Open-Win }
SLog "server start pid $PID"; trap { SLog ("FATAL: " + $_ + " @ " + $_.InvocationInfo.ScriptLineNumber); continue }
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
    $q = $ctx.Request.QueryString
    switch ($ctx.Request.Url.AbsolutePath) {
      '/' {
        $h = [IO.File]::ReadAllText($htmlPath, [Text.Encoding]::UTF8).Replace('__THEME__', [string](Get-Theme))
        Send $ctx $h 'text/html; charset=utf-8'
      }
      '/api/run' {
        if (-not ($job.proc -and -not $job.proc.HasExited)) {
          if ($job.tmp) { Remove-Item $job.tmp -Force -ErrorAction SilentlyContinue }
          $job.tmp = [IO.Path]::GetTempFileName()
          $extra = @('-NoPause'); if ($q['launch'] -ne '1') { $extra += '-NoLaunch' }; if ($q['relearn'] -eq '1') { $extra += '-Relearn' }
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
        $t = [string]$q['t']; if ($t -match '^[a-z]+$') { (@{ theme = $t } | ConvertTo-Json) | Set-Content $stateFile -Encoding UTF8 }
        Send $ctx '{"ok":true}'
      }
      '/api/log' { if (Test-Path $logFile) { Start-Process notepad.exe $logFile }; Send $ctx '{"ok":true}' }
      '/api/ping' { Send $ctx '{"ok":true}' }
      '/api/quit' { Send $ctx '{"ok":true}'; $quit = $true }
      '/api/browser' {
        if ($ctx.Request.HttpMethod -eq 'POST') {
          $len = [int]$ctx.Request.ContentLength64
          if ($len -gt 0 -and $len -lt 200000) {
            $buf = New-Object byte[] $len
            $read = 0
            while ($read -lt $len) { $n = $ctx.Request.InputStream.Read($buf, $read, $len - $read); if ($n -le 0) { break }; $read += $n }
            $body = [Text.Encoding]::UTF8.GetString($buf, 0, $read)
            try {
              $null = $body | ConvertFrom-Json
              $out = Join-Path $dir 'browser-check.json'
              if ($body -notmatch '"ts"') {
                $obj = $body | ConvertFrom-Json
                $utcTs = [datetime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                $obj | Add-Member -NotePropertyName ts -NotePropertyValue $utcTs -Force
                $body = ($obj | ConvertTo-Json -Depth 6 -Compress)
              }
              [IO.File]::WriteAllText($out, $body, [Text.UTF8Encoding]::new($false))
              SLog 'browser-check.json written'
            } catch { SLog ("browser json error: " + $_); $ctx.Response.StatusCode = 400; Send $ctx '{"ok":false}'; break }
          }
        }
        Send $ctx '{"ok":true}'
      }
      default { $ctx.Response.StatusCode = 404; Send $ctx '{}' }
    }
  } catch { SLog ("request error " + $ctx.Request.Url.PathAndQuery + ": " + $_); try { $ctx.Response.StatusCode = 500; Send $ctx '{}' } catch {} }
}
SLog "server exit (idle or quit)"; $l.Stop()