# Claude 环境检查器

Claude 环境检查器是面向 Windows x64 的第三方桌面工具，用于在启动 Claude 前核对系统环境，并在运行期间监控连接和客户端日志。

## 下载当前正式版

**[下载 v0.1.24 Windows x64 安装包](https://github.com/Adgai115/claude-safe-launcher/releases/download/desktop-v0.1.24/Claude-Environment-Checker-v0.1.24-win-x64-setup.exe)** · [最新发布与校验值](https://github.com/Adgai115/claude-safe-launcher/releases/latest)

安装器按条款并排显示中英文许可，勾选同意后可继续。首次安装默认使用 `%LOCALAPPDATA%\Claude Environment Checker`，可浏览文件夹或粘贴路径。升级沿用原安装位置。当前安装包为未签名构建，Windows SmartScreen 可能提示发布者未知。

## 从源码构建

Windows 桌面版源码位于 [`rust-desktop/`](rust-desktop/)。[构建说明](rust-desktop/README.md#构建)

## 使用

1. 打开应用后运行「检查并修复」，查看每项检查的状态和得分。
2. 完整检查达到 100 分后可点击「启动 Claude」。启动前会再次核对环境。
3. 面板关闭后可留在托盘监控。应用临时调整过的时区可在 Claude 退出后恢复。

主界面右下角显示版本，发现新版时显示「可更新」。确认后应用会下载并校验安装包，再通过 Windows 打开安装器。手动检查入口位于「设置」。

「监控日志 → 导出脱敏诊断」将诊断文件保存到 Windows 的下载文件夹，同名文件自动编号。

[完整使用说明](rust-desktop/README.md#使用)

## 历史版本

- 历史桌面版见 [v0.1.23](https://github.com/Adgai115/claude-safe-launcher/releases/tag/desktop-v0.1.23) 和 [v0.1.22](https://github.com/Adgai115/claude-safe-launcher/releases/tag/desktop-v0.1.22)。
- Releases 中的 v3.x 属于历史脚本版。Windows PowerShell v3.5.3、macOS 实现和规则预览源码见[历史归档分支](https://github.com/Adgai115/claude-safe-launcher/tree/archive/legacy)。

## 许可

本项目采用 **CC BY-NC 4.0**，可依照署名、非商业使用及其他条款分享和改编。

[英文许可全文](LICENSE) · [简体中文许可全文](LICENSE.zh-Hans.txt)
