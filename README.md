# Claude 环境检查器

Claude 环境检查器是面向 Windows x64 的第三方桌面工具，用于在启动 Claude 前核对系统环境，并在运行期间监控连接和客户端日志。

## 下载当前正式版

**[下载 v0.1.25 Windows x64 安装包](https://github.com/Adgai115/claude-safe-launcher/releases/download/desktop-v0.1.25/Claude-Environment-Checker-v0.1.25-win-x64-setup.exe)** · [最新发布与校验值](https://github.com/Adgai115/claude-safe-launcher/releases/latest)

安装器按条款并排显示中英文许可，勾选同意后可继续。首次安装默认使用 `%LOCALAPPDATA%\Claude Environment Checker`，可浏览文件夹或粘贴路径。升级沿用原安装位置。应用内更新包使用 Tauri 签名。Windows SmartScreen 可能提示安装器发布者未知，因为安装器未做 Windows 代码签名。

## 从源码构建

Windows 桌面版源码位于 [`rust-desktop/`](rust-desktop/)。[构建说明](rust-desktop/README.md#构建)

## 使用

1. 打开应用后默认执行只读检查。「检查并修复」会先列出拟改动的项目及前后值，确认后执行。
2. 完整检查达到 100 分后可点击「启动 Claude」。启动前会再次核对环境。
3. 面板关闭后可留在托盘监控。应用临时调整过的时区可在 Claude 退出后恢复。

主界面右下角显示版本，发现新版时显示「可更新」。v0.1.24 及更早版本通过安装向导升级一次。v0.1.25 起，后续兼容的签名补丁可在应用内直接安装，其他更新仍通过安装向导。手动检查入口位于「设置」。

遇到 VPN 路由问题时，修复说明可打开 Windows VPN 设置；连接并保持节点稳定后，「连接后自动处理」会重新检测并自动建立可确认的接口、出口和时区基准，再预览需要用户确认的修改。「监控日志 → 导出脱敏诊断」将诊断文件保存到 Windows 的下载文件夹，同名文件自动编号。「反馈问题」会先说明隐私范围，再按用户选择打开 GitHub 反馈页；诊断文件不会自动上传。

[完整使用说明](rust-desktop/README.md#使用)

## 历史版本

- 历史桌面版见 [v0.1.24](https://github.com/Adgai115/claude-safe-launcher/releases/tag/desktop-v0.1.24)、[v0.1.23](https://github.com/Adgai115/claude-safe-launcher/releases/tag/desktop-v0.1.23) 和 [v0.1.22](https://github.com/Adgai115/claude-safe-launcher/releases/tag/desktop-v0.1.22)。
- Releases 中的 v3.x 属于历史脚本版。Windows PowerShell v3.5.3、macOS 实现和规则预览源码见[历史归档分支](https://github.com/Adgai115/claude-safe-launcher/tree/archive/legacy)。

## 许可

本项目采用 **CC BY-NC 4.0**，可依照署名、非商业使用及其他条款分享和改编。

[英文许可全文](LICENSE) · [简体中文许可全文](LICENSE.zh-Hans.txt)
