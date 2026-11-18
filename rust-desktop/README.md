# Claude 环境检查器

这是独立的 Windows 桌面版。Rust 负责探测、评分、修复、启动和监控，Tauri 2 承载固定中国风的 HTML/CSS 界面。面板通过 Tauri 命令和事件与 Rust 通信。

## 构建

需要 Windows、Rust stable MSVC 工具链、Visual Studio C++ Build Tools（含 Windows SDK）和 WebView2 Runtime。详见 [Tauri Windows 开发环境](https://v2.tauri.app/start/prerequisites/#windows)。

在本目录用 PowerShell 运行以下命令。

```powershell
cargo test --no-default-features --locked
cargo run --locked
```

发布 Windows 安装包时，使用 Tauri CLI 构建当前用户模式的 NSIS 安装载荷，然后用原生 Windows 安装界面封装。发布给用户的是封装后的 EXE。它在本地提供简体中文和英文协议，勾选同意后才允许安装。

```powershell
cargo install tauri-cli --version '^2' --locked
cargo tauri build
$payload = Get-ChildItem target\release\bundle\nsis -Filter '*.exe' | Select-Object -First 1
.\installer\Build-Installer.ps1 -Payload $payload.FullName -OutputPath .\target\Claude-Environment-Checker-Setup.exe
```

手动安装器按条款并排显示 [简体中文许可](../LICENSE.zh-Hans.txt)和[英文许可](../LICENSE)。首次安装可浏览文件夹，也可输入或粘贴路径。升级沿用已登记的安装位置。签名更新继续使用 Tauri CLI 生成的 NSIS 载荷及其签名。

主界面右下角显示应用版本。程序启动时自动查询 `desktop-v<版本号>` 的 Windows x64 正式发布，设置中也可手动检查。发现新版本时点击「可更新」，确认后从 GitHub 下载到 Windows 下载文件夹，校验 SHA-256 并通过 Windows 打开安装器。更新安装前会检查 Claude 是否已退出，并处理待恢复的时区。

启用签名更新的安装包可在应用内安装已验证的新版本。构建命令为 `cargo tauri build --features signed-updates --config <发布配置>`。配置需要设置 `bundle.createUpdaterArtifacts`、`plugins.updater.pubkey`、HTTPS `plugins.updater.endpoints` 和 `plugins.updater.requireSignedVersion: true`。使用 Tauri CLI 2.12.5 或更新版本签署带版本号的安装包，并按 [Tauri 更新发布格式](https://v2.tauri.app/plugin/updater/) 发布安装包、签名和版本清单。应用内安装前必须退出 Claude，并完成尚未处理的时区恢复。

## 使用

1. 打开 Clash Verge Rev，启用外部控制和 TUN。Rust 版从 Clash Verge 运行配置读取本机控制器地址及认证信息。默认策略组为 `Claude`，可在应用设置里更改。
2. 打开面板自动「检查并修复」，也可从主界面手动复查。首次缺少基准时，尝试依据可确认的 Claude 出口、当前策略组节点和出口地时区建立基准，检查无阻断后再保存。已有基准按原值复查和修复。需要换基准时使用「设置 → 记住当前环境」。
3. 检查完成且达到 100 分后，「启动 Claude」才可点击。点击后会只读复核，复核达到 100 分才启动客户端。
4. 关闭面板后程序留在系统托盘。完成一次环境检查后，发现 Claude 正在运行就进入监控，包括从其他入口启动的 Claude。约每 30 秒复查连接和日志，约每 5 分钟复查代理、时区、出口、DNS、IPv6、API 连通性和支持地区。Claude 退出后回到等待状态，下一次运行会自动接续。面板底部可暂停或恢复监控，托盘菜单可以退出程序。
5. 启动器临时更改 Windows 时区前，先保存原时区及夏令时设置。Claude 进程退出后恢复。如果时区在会话中被另行更改，保留当前设置。托盘退出且 Claude 未运行时也会处理恢复。遇到异常退出，启动器下次打开会继续处理未完成的恢复记录。
6. 检测到 Claude 进程后，启动器只读检查，并锁定时区、Clash TUN、节点、策略组设置和环境基准的写入。运行状态检测在暂停后台复查时仍有效。系统设置和独立 VPN 客户端由各自的应用控制。

没有运行 Clash 内核时，程序核对 Claude 网页和 Anthropic API 探测连接的 Windows 路由。两者都经同一受支持 VPN 接口时，可保存接口和出口基准。支持识别常见 WireGuard、Wintun、OpenVPN、TAP、Tailscale 和 Windows VPN 驱动。仅系统代理、仅应用代理、无法归属的驱动，以及路由分流到不同接口的情况无法获得满分。切换 Clash 和其他 VPN 后，在「设置 → 记住当前环境」核对并保存当前基准。

后台确认新的偏差时记录日志并在 Windows 允许时发出桌面通知。同一个持续偏差只通知一次。底部显示原时区的备份及恢复结果。Claude 退出后，可以手动恢复或重试。

配置与支持地区缓存位于 `%LOCALAPPDATA%\io.github.adgai115.claude-safe-launcher-rust`。运行时不读取 PowerShell 版配置，也不写它的安装目录或快捷方式。如需指定非标准安装的 Claude，在 Rust 版 `preflight.json` 里设置 `claudeExe`（绝对路径）或 `claudeAumid`。新版本启动时等待用户操作。

打开应用、手动检查和启动前复核都会检查全部 14 组。检查会请求 Claude 的公开连通性与出口端点、公开 IP 和官方支持地区服务。第三方 IP 风险与通用 IPv6 出口探测的权重各为 4。IP 风险分达到 33 记警告，达到 66 记风险。IPv6 探测未取得有效结果时核对 Windows 路由表。只有确认没有公网 IPv6 路由且 Claude 出口使用 IPv4，才按 IPv4 环境通过。IPv6 探测仍待核实时，该项得 0 分。出口按 Claude 网页探测结果与基准比对。API 端点有结果时一并核对，通用 IP 差异作为分流提示。首次建立出口地时区时使用旧版同款 IPinfo 查询。地区名单获取失败时使用七天内有效缓存，证据不足时暂停自动启动。

每组按权重计分。通过或已修复的组获得该组权重，失败、警告、待核实和未完成的组暂不得分。待启动及其他不计分状态从有效总权重中排除，得分换算为百分制并向下取整。最高 100 分在完整结果确认后显示。「Claude 运行与连接」在启动前显示「待启动」，启动后复查实际连接。

Rust 版后台监控采用只读模式。实际连接核对会比对 Windows 和 Clash 的快照。Claude 的公网 TCP 连接在 Clash 快照中无法归属时标为待核实。客户端日志支持带时间戳的文本和 JSON 行。账号是否可用仍需通过客户端的实际会话确认。

Claude Code 接口检查读取当前进程的环境变量和用户配置目录中的 `settings.json`、`settings.local.json`、`config.json`。识别自定义 `ANTHROPIC_BASE_URL` 后只显示来源。项目级和组织托管配置可在相应 Claude Code 会话里核对。

面板 WebRTC 使用 WebView2 及旧看板同样的两个 STUN 服务探测候选地址。面板只显示和 Claude 网页出口的比对结论，候选地址不写入磁盘。WebRTC 结果作为参考，时区仍按原权重计分。其他浏览器独立于面板 WebView2。

「设置 → 复制检查状态」只包含各组状态和得分。旧版环境变量清理、DPAPI 备份撤销、完整问题包和 macOS 实现尚未移植。

主界面的「监控日志」可查看最近 50 条诊断记录，打开期间自动更新。后台约每 30 秒完成连接和客户端告警复查并记录一次，约每 5 分钟复查主要环境，暂停、恢复和异常事件也会写入。「设置」会显示本地诊断日志路径 `logs\diagnostics.jsonl`。每行包含时间、事件、分数、各检查项状态和监控状态。日志达到 1 MiB 后保留一个轮替文件。诊断日志不会保存原始客户端日志、聊天内容、地址或凭据。

「监控日志 → 导出脱敏诊断」在 Windows 下载文件夹生成 `monitor-diagnostics.json`，同名文件存在时自动编号。导出包含当前状态和最近 50 条事件，仅使用固定事件类别、分数、检查编号与状态、时间和时区恢复标记。

时区恢复通过 `timezone-restore.json` 记录临时更改。恢复范围只包含启动器自己改动的 Windows 时区。地区、语言、系统位置与网络配置不参与退出恢复。
