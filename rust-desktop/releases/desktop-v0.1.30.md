# Claude 环境检查器 v0.1.30

本版本继续面向 Windows x64，修复 Clash Mi 已连接并开启全局 + TUN 时仍提示“请连接 VPN”与无法确认控制器/TUN 状态的问题。

## 主要变化

- 识别 Clash Mi 在 Windows 上的真实配置目录（包括 `%APPDATA%\clashmi\clashmi` 与运行目录旁边的 `portable` 便携目录），不再因单层 `%APPDATA%\ClashMi` 不存在而误回退到 Clash Verge 的 `9097` 端口。
- 从 Clash Mi 的 `service_core_patch_final.json`、`service.json` 及 `service_core_setting.json` 联合读取本地控制器地址、端口和 `secret`（含设备 ID 派生的默认密钥），解决 `service_core_setting.json` 未落盘 `secret` 时控制器鉴权失败的问题。
- 切换到全局模式前，若 `GLOBAL` 策略组仍指向 `DIRECT` 等非代理项，自动切换到首个有效代理组或节点。
- 系统 DNS 检查新增识别 Clash Mi 默认 Fake-IP 网段（`172.19.0.0/16` 与 `fdfe:dcbe:9876::/126`），自动节点筛选同步确认 TUN 模式下的公网 DNS。
- 当 Windows 本机无公网 IPv6 路由且已确认通过本机 IPv4/TUN 隧道转发时，允许远端代理节点使用 IPv6 访问 Cloudflare，使第 7 项“IPv6 出口探测”正常通过。
- 扩充常见 IANA 时区映射，并在 `ipinfo.io` 限流或不可达时按已确认出口国家提供默认时区兜底；若代理控制器端口被禁用但 Windows TUN 路由已确认，自动回退到 Windows TUN 路由接口核验。

## 更新方式

v0.1.29 可发现本版本，并通过应用内更新入口下载经 GitHub SHA-256 校验的完整安装器。安装器会沿用原安装路径、配置和监控状态。

本次公开发布继续使用无 AWS 的 GitHub Actions 流程，只提供完整安装器和 `SHA256SUMS.txt`。由于没有与 `updater.pub` 配对的 Tauri 更新私钥，不发布 `latest.json` 或直接更新包。Windows 安装包当前没有 Authenticode 代码签名，系统可能显示安全提醒。

## 验证范围

- Windows 桌面格式、Rust 核心及桌面测试通过。
- Windows x64 完整安装器构建和结构检查通过。
- 新增 Clash Mi 嵌套目录与便携目录发现、伴生配置文件密钥解析、`172.19.0.0/16` Fake-IP 与隧道 IPv6 出口回归测试。
- 使用准备发布的提交执行 v0.1.29 到 v0.1.30 隔离升级测试。

应用不会绕过 Windows UAC，也不会在 Claude 运行时静默修改系统或强制结束 Claude。需要提升权限时仍需用户确认。
