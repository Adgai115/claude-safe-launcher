# Claude Safe Launcher 安装脚本：解除下载锁定，并在桌面创建「Claude 安全启动」快捷方式（打开检查面板）
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
Get-ChildItem -Path $dir -File | Unblock-File -ErrorAction SilentlyContinue
$windowsDir = Join-Path $dir 'windows'
$panel = Join-Path $windowsDir 'claude-panel.ps1'
if (-not (Test-Path -LiteralPath $panel)) { throw '新版 Windows 面板缺失，请下载并解压完整仓库。' }
Get-ChildItem -LiteralPath $windowsDir -File | Unblock-File -ErrorAction SilentlyContinue
$ps   = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$desk = [Environment]::GetFolderPath('Desktop')
$ico  = Join-Path $dir 'claude.ico'
$ws   = New-Object -ComObject WScript.Shell
function New-Lnk($name, $file, $style) {
  $l = $ws.CreateShortcut((Join-Path $desk "$name.lnk"))
  $l.TargetPath = $ps
  $l.Arguments = "-NoProfile -ExecutionPolicy Bypass $style-File `"$(Join-Path $dir $file)`""
  $l.WorkingDirectory = $windowsDir
  if (Test-Path $ico) { $l.IconLocation = $ico }
  $l.Save()
  Write-Host "已创建桌面快捷方式: $name" -ForegroundColor Green
}
New-Lnk 'Claude 安全启动' 'windows\claude-panel.ps1' '-WindowStyle Hidden '
# 旧版本安装过的「Claude 检查面板」快捷方式（指向本文件夹的）一并清理
$old = Join-Path $desk 'Claude 检查面板.lnk'
if ((Test-Path $old) -and ($ws.CreateShortcut($old).Arguments.Contains($dir))) { Remove-Item $old -Force }
Write-Host ''
Write-Host '安装完成。桌面「Claude 安全启动」已指向 Windows v3.5.3 面板。' -ForegroundColor Cyan
Write-Host '关闭面板后继续监控：需先通过「修复并启动 Claude」启动独立监控；Claude 退出后监控结束。' -ForegroundColor Gray
