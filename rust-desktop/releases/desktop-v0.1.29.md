# Claude 环境检查器 v0.1.29

本版本继续面向 Windows x64，修复 Windows 时区已自动调整后，“面板时区与 WebRTC”仍使用修复前样本并显示“参考”的问题。

## 主要变化

- “检查并修复”仍由第 2 项直接调整 Windows 系统时区，并保留原时区恢复记录。
- Windows 时区修复成功后，检查器等待 WebView2 接收主机时区变化通知，再自动执行一次新的只读复查。
- 若 WebView2 通知延迟，检查器只重载面板一次并自动复查，不重启后端、不恢复刚应用的临时时区，也不影响 Claude。
- 第 11 项不再把修复前采集的旧面板时区长期显示为普通“参考”；诊断日志会记录 `panel_timezone_runtime_stale`、`panel_timezone_match` 或 `panel_timezone_missing`。
- WebRTC 仍重新采集并与 Claude 网页出口比对，诊断信息继续脱敏，不记录公网候选地址。

## 更新方式

v0.1.28 可发现本版本，并通过应用内更新入口下载经 GitHub SHA-256 校验的完整安装器。安装器会沿用原安装路径、配置和监控状态。

本次公开发布继续使用无 AWS 的 GitHub Actions 流程，只提供完整安装器和 `SHA256SUMS.txt`。由于没有与 `updater.pub` 配对的 Tauri 更新私钥，不发布 `latest.json` 或直接更新包。Windows 安装包当前没有 Authenticode 代码签名，系统可能显示安全提醒。

## 验证范围

- Windows 桌面格式、Rust 核心及桌面测试通过。
- Windows x64 完整安装器构建和结构检查通过。
- 新增修复后旧 WebView2 时区样本的原因码与自动复查回归测试。
- 使用准备发布的提交执行 v0.1.28 到 v0.1.29 隔离升级测试。

应用不会绕过 Windows UAC，也不会在 Claude 运行时静默修改系统或强制结束 Claude。需要提升权限时仍需用户确认。
