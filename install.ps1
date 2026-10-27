# Claude Safe Launcher 安装脚本：解除下载锁定，并在桌面创建两个快捷方式
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
Get-ChildItem -Path $dir -File | Unblock-File -ErrorAction SilentlyContinue
$ps   = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$desk = [Environment]::GetFolderPath('Desktop')
$ico  = Join-Path $dir 'claude.ico'
$ws   = New-Object -ComObject WScript.Shell
function New-Lnk($name, $file, $style) {
  $l = $ws.CreateShortcut((Join-Path $desk "$name.lnk"))
  $l.TargetPath = $ps
  $l.Arguments = "-NoProfile -ExecutionPolicy Bypass $style-File `"$(Join-Path $dir $file)`""
  $l.WorkingDirectory = $dir
  if (Test-Path $ico) { $l.IconLocation = $ico }
  $l.Save()
  Write-Host "已创建桌面快捷方式: $name" -ForegroundColor Green
}
New-Lnk 'Claude 安全启动' 'claude-preflight.ps1' ''
New-Lnk 'Claude 检查面板' 'claude-panel.ps1' '-WindowStyle Hidden '
Write-Host ''
Write-Host '安装完成。建议先双击「Claude 检查面板」点「只检查」，确认环境没问题再启动 Claude。' -ForegroundColor Cyan