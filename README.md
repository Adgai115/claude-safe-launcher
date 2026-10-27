# Claude Safe Launcher（Claude 桌面版启动前检查器）

在启动 Claude 桌面版之前，自动检查代理与本机环境是否一致、干净，减少因环境异常（IP 跳变、时区不符、DNS/IPv6 泄露、第三方中转残留等）带来的风险。附带一个可视化检查面板，支持多种界面主题，评分随检查结果实时变化。

支持 **Windows**（PowerShell）与 **macOS**（Python 3 标准库，无需 pip）。

> 本工具只做本机环境检查，不修改 Claude 本身，不收集、不上传任何数据。它不能保证账号安全，请遵守 Anthropic 的使用条款与所在地法律法规。

## 运行要求

### Windows

- Windows 10 / 11，自带的 Windows PowerShell 5.1
- [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev)（mihomo 内核），建议开启 TUN 模式
- Clash Verge「设置 → Clash 设置」中开启**外部控制**（脚本会自动从 Clash Verge 运行配置读取地址和密钥）
- Claude 桌面版（Microsoft Store / MSIX 版或官网安装版均可）
- Edge 或 Chrome（用于显示检查面板）

### macOS

- macOS 12+（建议）
- Python 3（随 Xcode 命令行工具提供）。若没有：`xcode-select --install`
- [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev)（mihomo 内核），建议开启 TUN 模式，并开启外部控制
- Claude 桌面版（`/Applications/Claude.app` 或 `~/Applications/Claude.app`）
- 系统自带的 `curl`、`osascript`（通知用）

## 安装

### Windows

1. 下载本仓库（Code → Download ZIP）并解压到任意文件夹，例如 `D:\ClaudeSafeLauncher`。
2. 双击 `install.cmd`。它会解除文件的下载锁定，并在桌面创建一个 **Claude 安全启动** 快捷方式。点开就是检查面板，可以「只检查」，也可以「检查并启动」；检查通过并启动 Claude 后，会自动开启后台监控。

不想用面板的话，也可以直接运行 `claude-preflight.ps1`（命令行版，参数见下文）。

移动文件夹后重新运行一次 `install.cmd` 即可。

### macOS

1. 下载本仓库并解压，进入其中的 `mac/` 文件夹。
2. 双击 `install.command`（若被拦截：右键 → 打开）。它会：
   - 检查 `python3` 是否可用；
   - 给脚本加上执行权限；
   - 在桌面创建一个 **Claude 安全启动**（`.app` 或 `.command`）。点开就是检查面板。

命令行也可以：

```bash
cd mac
python3 claude_preflight.py --no-launch
python3 claude_panel.py
```

移动文件夹后重新运行一次 `install.command` 即可。

## 推荐的 Clash 设置

建议在 Clash 配置中为 Claude 建一个专用策略组（默认组名 `Claude`），固定使用一个干净、稳定的住宅 IP 节点，并把相关域名分流过去，例如：

```yaml
proxy-groups:
  - name: Claude
    type: select
    proxies: [你的固定节点]

rules:
  - DOMAIN-SUFFIX,anthropic.com,Claude
  - DOMAIN-SUFFIX,claude.ai,Claude
  - DOMAIN-SUFFIX,claude.com,Claude
  - DOMAIN-SUFFIX,claudeusercontent.com,Claude
```

没有这个策略组也能用，只是会跳过「节点锁定」检查。

## 第一次运行会自动记住你的环境

首次运行时，脚本会按当前环境自动记住以下内容，并写入同目录下的 `preflight.json`（macOS 写在 `mac/preflight.json`）：

- **出口 IP 与地区**：本机实测和 Claude 边缘看到的 IP 一致、且不在封锁地区时才会记住
- **节点**：`Claude` 策略组当前使用的节点，之后被切走会自动切回
- **时区**：根据出口 IP 所在地推算（Windows 为 Windows 时区 ID；macOS 为 IANA，如 `America/New_York`）。同时记住 IANA 名（`expectedTzIana`），供浏览器时区对比使用

之后每次运行都会和记住的值对比。出口 IP 发生变化时会阻止启动 Claude。

换了节点或 IP 后，在面板里点「记住当前环境」，或：

```text
# Windows
powershell -ExecutionPolicy Bypass -File claude-preflight.ps1 -Relearn

# macOS
python3 claude_preflight.py --relearn --no-launch
```

### macOS 时区说明

macOS 版**不会**自动改系统时区（避免请求管理员权限）。若时区不一致，会给出失败项，并提示你手动执行：

```bash
sudo systemsetup -settimezone America/New_York
```

（把时区换成面板/配置里给出的目标 IANA 名。）

## 检查项目

1. Clash 与 TUN：未运行时尝试启动 Clash Verge；确认 mihomo 与 TUN（macOS 以 utun / 198.18 路由作尽力判断）
2. 系统时区：Windows 可自动修正；macOS 给出手动命令；并检查自动设置时区
3. 节点锁定：策略组被切走时自动切回
4. 出口 IP 三方对比：本机实测、记住的值与 Claude 边缘看到的 IP
5. IP 风险评分：proxycheck.io 与 ip-api
6. DNS：确认由 Clash 的 fake-ip 接管（`198.18.0.0/15`）
7. IPv6 泄露
8. api.anthropic.com 连通性（是否被地区封锁；405/401/404 视为正常）
9. 环境变量：第三方中转变量（ANTHROPIC_BASE_URL 等）与代理变量（macOS 还会看 `launchctl getenv`）
10. 第三方接口残留：Claude 配置文件和模型切换脚本（只报告，不删除，不打印密钥）
11. 其他：系统语言、Claude 桌面版与 Claude Code CLI 是否已安装
12. 浏览器环境（固定检查组，非可选）：
    - **静态**：扫描本机 Chrome / Edge / Brave 各配置的 Preferences（只读），检查 WebRTC IP 策略、`accept_languages` 与出口地区是否一致；Firefox 则看 `media.peerconnection.enabled`。代理/指纹类扩展仅作信息提示。静态警告单项扣 5 分，本组静态合计最多约扣 20 分。
    - **实时**（仅检查面板）：页面先通过 STUN（Google / Cloudflare）做 WebRTC ICE 采集，再把公网候选 IP、浏览器时区、语言、`navigator.webdriver` 交给预检。公网 IP 与记住的出口不一致 → 失败（-25）；WebRTC 公网 IPv6、时区/语言不符、webdriver=true → 警告。命令行单独跑预检时会提示「请从面板运行实时检查」，不扣分。

启动后，后台监控默认每 5 分钟复查一次，发现 IP 或节点变化时会提醒（macOS 用系统通知）。默认**不会**因变化而关闭 Claude；若确需关闭，在 `preflight.json` 把 `monitorKillOnChange` 设为 `true`。

## 命令行参数

| Windows | macOS | 作用 |
| --- | --- | --- |
| `-NoLaunch` | `--no-launch` | 只检查，不启动 Claude，也不开启后台监控 |
| `-NoPause` | `--no-pause` | 结束后不等待按键 |
| `-Force` | `--force` | 即使检查有失败项也启动 |
| `-Relearn` | `--relearn` | 忘掉记住的 IP、节点和时区，按当前环境重新记住 |

## 配置文件 preflight.json

大多数字段留空即可，脚本会自动探测或学习。只在自动探测失败时手动填写：

| 字段 | 说明 |
| --- | --- |
| `expectedIp` / `expectedLoc` | 期望的出口 IP 与国家代码（自动学习） |
| `claudeGroup` | Claude 专用策略组名，默认 `Claude` |
| `expectedNode` | 该组应使用的节点（自动学习） |
| `mainGroup` / `pinMainGroup` | 额外需要锁定的策略组，以及是否锁定 |
| `timezone` | 目标时区（自动学习）。Windows：如 `Eastern Standard Time`；macOS：IANA，如 `America/New_York` |
| `claudeAumid` / `claudeExe` | （Windows）Claude 桌面版应用 ID 或 exe 路径 |
| `claudeApp` | （macOS）Claude.app 路径，如 `/Applications/Claude.app` |
| `clashExe` / `clashApp` | Clash Verge 程序路径（自动探测） |
| `proxyUrl` / `controllerUrl` / `controllerSecret` | 代理与外部控制地址（默认从 Clash Verge 运行配置读取；密钥不会被打印） |
| `warnRisk` / `failRisk` | IP 风险分的警告和失败阈值，默认 33 / 66 |
| `monitorIntervalMin` | 后台监控间隔（分钟），默认 5 |
| `monitorKillOnChange` | IP 变化时是否自动关闭 Claude，默认 `false` |

## 目录结构

```text
├── claude-common.ps1 / claude-preflight.ps1 / claude-monitor.ps1 / claude-panel.ps1   # Windows
├── claude-panel.html / install.cmd / install.ps1
├── mac/
│   ├── claude_common.py / claude_preflight.py / claude_monitor.py / claude_panel.py  # macOS
│   ├── claude-panel.html   # 与根目录面板共用同一套 UI
│   └── install.command
├── LICENSE                 # CC BY-NC 4.0
└── README.md
```

## 隐私

- 所有检查都在本机运行。为测量出口 IP 和风险分，会访问 ipinfo.io、proxycheck.io、ip-api.com，以及 claude.ai / api.anthropic.com 的公开 trace 地址。
- 检查面板在做「浏览器环境」实时检查时，会从本机向 Google（`stun.l.google.com`）和 Cloudflare（`stun.cloudflare.com`）的 **STUN** 服务器发起短暂连接，仅用于收集 WebRTC 公网候选地址；不会上传其它浏览器数据。
- `preflight.json`、`browser-check.json`、日志和面板配置只保存在本地，并已在 `.gitignore` 中排除，请不要上传。
- 脚本不会打印或保存 Clash 外部控制密钥；也不会修改你的浏览器配置（Preferences 只读扫描）。

## 许可证

[CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/deed.zh-hans)：允许个人免费使用、修改和分享，需注明出处，**禁止商业用途**。完整条款见 [LICENSE](LICENSE)。
