<#
.SYNOPSIS
Claude Safe Launcher 安装脚本：解除下载锁定，并在桌面创建「Claude 安全启动」快捷方式（打开检查面板）

.DESCRIPTION
对本文件夹里的文件执行 Unblock-File，并在桌面创建指向 claude-panel.ps1 的快捷方式「Claude 安全启动」；顺便清理旧版本留下的「Claude 检查面板」快捷方式（只清指向本文件夹的）。
-Help（或 -?）只打印本帮助后立即以退出码 0 退出：不解除锁定、不创建或删除任何快捷方式、不写任何文件。

.PARAMETER Help
-Help : 只打印本帮助后 exit 0（等同 -?）：不解除下载锁定、不创建/删除快捷方式。

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
安装：解除下载锁定并创建桌面快捷方式。

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Help
只打印帮助，退出码 0；不安装。
#>
param([switch]$Help)
# R4c: -Help 只打印帮助后 exit 0。必须是 param() 之后的第一条语句：在加载配置、任何检查、写日志/JSON、启动监控、网络/Clash 调用之前退出。
if ($Help) {
  try { Get-Help -Name $MyInvocation.MyCommand.Path -Full | Out-String -Width 110 | Write-Host } catch { Write-Host '（帮助不可用：请查看脚本开头的注释式帮助）' }
  exit 0
}
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