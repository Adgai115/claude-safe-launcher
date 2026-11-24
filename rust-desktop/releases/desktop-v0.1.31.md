# Claude 环境检查器 v0.1.31

本版本继续面向 Windows x64，修复 Windows 系统时区已自动调整到位后，第 11 项“面板时区与 WebRTC”因已运行 WebView2 进程缓存启动时区或同区 IANA 城市别名不同而停在“参考”的问题。

## 主要变化

- `tzutil.exe /s` 调整 Windows 时区后广播 `WM_TIMECHANGE` 系统消息。
- 当 Win32 实时读取到的 Windows 系统时区已与基准时区一致，或面板 IANA 时区与基准属于同一 Windows 时区（如 `America/Detroit` 与 `America/New_York` 均对应 `Eastern Standard Time`）时，第 11 项直接判定为“通过（2/2 分）”，不再因当前 WebView2 渲染进程缓存的启动时区未刷新而停在“参考”。
- 自动修复或补齐基准时，若 `expectedTzIana` 缺失或更新，同步更新并落盘。

## 更新方式

v0.1.30 可发现本版本，并通过应用内更新入口下载经 GitHub SHA-256 校验的完整安装器。安装器会沿用原安装路径、配置和监控状态。

本次公开发布继续使用无 AWS 的 GitHub Actions 流程，只提供完整安装器和 `SHA256SUMS.txt`。由于没有与 `updater.pub` 配对的 Tauri 更新私钥，不发布 `latest.json` 或直接更新包。Windows 安装包当前没有 Authenticode 代码签名，系统可能显示安全提醒。

## 验证范围

- Windows 桌面格式、Rust 核心及桌面测试通过。
- Windows x64 完整安装器构建和结构检查通过。
- 新增 Windows 实时时区已对齐及同区 IANA 别名下的面板时区判定回归测试。
- 使用准备发布的提交执行 v0.1.30 到 v0.1.31 隔离升级测试。

应用不会绕过 Windows UAC，也不会在 Claude 运行时静默修改系统或强制结束 Claude。需要提升权限时仍需用户确认。
