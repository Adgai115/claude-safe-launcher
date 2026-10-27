# Claude Safe Launcher 安装脚本：解除下载锁定，并在桌面创建「Claude 安全启动」快捷方式（打开检查面板）
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
New-Lnk 'Claude 安全启动' 'claude-panel.ps1' '-WindowStyle Hidden '
# 旧版本安装过的「Claude 检查面板」快捷方式（指向本文件夹的）一并清理
$old = Join-Path $desk 'Claude 检查面板.lnk'
if ((Test-Path $old) -and ($ws.CreateShortcut($old).Arguments.Contains($dir))) { Remove-Item $old -Force }
Write-Host ''
Write-Host '安装完成。双击桌面上的「Claude 安全启动」打开检查面板：可以「只检查」，也可以「检查并启动」。' -ForegroundColor Cyan