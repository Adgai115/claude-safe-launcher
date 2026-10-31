# Claude Safe Launcher

在启动 Claude 桌面版之前检查环境，按记录的标准修复可确认偏差，并在使用时观察实际连接与客户端日志。工具用于降低可识别的风险，不保证免封；检查分数不是账号安全概率。

## Windows 默认版本：v3.5.3

1. 下载完整仓库并解压。
2. 运行根目录的 `install.cmd`。
3. 桌面「Claude 安全启动」会打开 `windows/claude-panel.ps1`，默认执行「检查并修复」。

需要 Windows 10/11、Windows PowerShell 5.1、Edge 或 Chrome、Claude 桌面版，以及已开启外部控制和 TUN 的 Clash Verge Rev。默认使用 `Claude` 策略组，请先准备自己的代理配置。

- 15 组检查，实际明细、顶部计数、卡片扣分和评分同步更新。
- 按记录的标准复查时区、节点、出口、TUN；保留正常 Claude Code 认证与模型变量。
- 通过 Windows TCP 归属补足代理缺少进程信息的情况，只读核对 Claude 官方服务连接。
- 只报告近期日志中的告警类别，无日志不等于账号异常，也不等于账号健康。
- 耗时观测在独立进程执行，有超时和重试，避免拖住面板。
- 不注入或挂接 Claude，不读取其进程内存、不改登录数据，不主动断连或关闭 Claude。

完整的安装、配置、升级、评分和命令行说明见 **[Windows 使用说明](windows/README.md)**，变更范围见 [v3.5.3 发布说明](docs/windows-v3.5.3.md)。移动解压目录后重新运行安装脚本即可。

### 关闭面板后还会监控吗

| 使用方式 | 关闭面板后 |
| --- | --- |
| 仅打开面板、只读检查或检查并修复 | 不会因此启动独立常驻监控；面板的周期观测停止 |
| 「修复并启动 Claude」并成功启动或确认客户端运行 | 独立监控继续：默认约每 5 分钟检查环境、约每 30 秒观测连接和日志 |
| Claude 退出 | 独立监控退出 |

独立监控默认按标准修复时区、节点和 TUN；配置 `monitorAutoRepair=false` 可改为仅提醒。不会因关闭面板而关闭 Claude，也不会因观测异常主动断开 Claude 连接。

### 分数表示什么

分数从实际带权重的检查结果计算。已确认失败默认扣 25 分，已确认时区偏差扣 8 分；参考项和未知状态不会凭空扣分。界面同时展示待核实和参考组数，100 分不代表全部核实。异常中止或明细与分数不一致时不显示分数。

首次使用请核对地区、出口和预设标准。Windows 本机配置、日志、浏览器目录、变量备份均不应提交到 Git；仓库只提供无凭据的 `windows/preflight.example.json`。

## macOS

macOS 实现保留在 `mac/`，本次 Windows 更新不改变其行为。进入该目录运行 `install.command`，或：

```bash
cd mac
python3 claude_panel.py
```

依赖 Python 3、系统 `curl`、`osascript`、Clash Verge Rev 和 Claude 桌面版。详细要求与旧功能见 [原有使用说明](docs/legacy-README.md)。

## 保留的 v4 JSON 预览接口

根目录的脚本、`claude-rules.ps1`、`rules/checks.json` 及原有测试保持兼容。已有调用根目录 `claude-preflight.ps1 -Json -JsonPath ...` 的工具不需要迁移；它们不是新版 Windows 默认入口。

- [v4 规则文档](docs/rules-v4.md)
- [v4 JSON 预览格式](docs/preflight-json-schema.md)
- [更新日志](CHANGELOG.md)

新版 Windows 的结构化进度与完整结果使用 schemaVersion 2，由 `windows/claude-diagnostics.ps1` 统一生成和核对。根目录预览文档中的旧行为仅适用于根目录预览实现，请勿将其视为新版 Windows 的启动或评分规则。

## 验证

```powershell
# 新版 Windows：隔离脚本、连接归属、日志分类与结果回归
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\tests\verify.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\tests\verify-risk.ps1

# 保留的根目录预览接口回归
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\rules.Tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\envfix.Tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\issueexport.Tests.ps1
```

新版浏览器回归及依赖设置见 [Windows 测试说明](windows/README.md#验证)。截图、结果和依赖默认在临时目录，不提交运行数据。

## 许可

[CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/deed.zh-hans)：允许非商业使用、修改和分享，需注明出处。完整条款见 [LICENSE](LICENSE)。