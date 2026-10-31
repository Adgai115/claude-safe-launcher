# Windows v3.5.3

本目录是 Windows 默认安装版本。它通过外部环境检查、按记录标准修复及运行期观测降低可识别的使用风险，不保证账号免受限制，分数也不表示封号概率。

## 安装与基准

1. 下载完整仓库并解压，运行仓库根目录的 `install.cmd`。桌面快捷方式会打开本目录的面板。
2. 使用 Windows PowerShell 5.1、Edge 或 Chrome、Claude 桌面版及已开启外部控制的 Clash Verge Rev。默认检查策略组 `Claude`，请先在自己的代理配置中准备该组。
3. 面板打开后默认「检查并修复」。首次缺少标准时，会尝试根据可确认的出口、策略组节点和时区建立基准；完整检查有阻断项时不会保存新基准。想先只读检查，可用下方命令行入口。
4. 核对环境后，可以用「记住当前环境」明确更新基准。已有基准不会为了放行异常环境而自动改写。

配置保存在本目录的 `preflight.json`，默认不随仓库提供。可参考 `preflight.example.json`，其中没有出口 IP、节点或凭据。外部控制器信息由 Clash Verge 运行配置在本机读取，无需把密钥写进仓库。

从旧版升级时，先保留自己的配置和备份。需要沿用标准，可以在本机将旧 `preflight.json` 复制到本目录，再执行只读检查。新版变量备份采用 Windows DPAPI CurrentUser 加密，旧版无法解密新版备份；不要删除仍需撤销的备份。

## 检查与修复

- 共 15 组检查，包含代理/TUN、时区、节点、出口、DNS、参考网络信号、环境变量、浏览器参考信息、官方地区、Claude 实际连接及客户端日志告警。
- 「只读检查」不更换节点、不修改时区、不清理环境变量、不建立基准；日志及面板浏览器快照仍会更新。
- 「检查并修复」「修复并启动 Claude」可以恢复记录的时区和指定策略组；必要时启动已配置的 Clash Verge、启用 TUN，并复查。不会关闭 TUN 或改成 DIRECT。
- 正常 Claude Code 认证和模型变量按用途保留。显式 `-FixEnv` 仍需预览与确认；备份和撤销只在本机执行。
- 不注入、挂接或读取 Claude 的进程内存，不修改其程序或登录数据，不主动断开连接、强制重连或关闭 Claude。

## 评分如何联动

卡片、计数、临时评分、最终评分和扣分原因使用同一份带权重的检查明细。计数按检查组统计，不把多条日志当成多个通过项目。已确认失败默认扣 25 分，已确认的时区偏差扣 8 分；参考项和未知状态不会凭空扣分。

圆环显示「已检项目评分」，同时列出已检查、待核实、参考/无数据的组数。100 分不代表每组都已核实。检查异常中止或最终分数与明细不一致时，不显示分数。

后台只读复查 TUN/代理内核、时区、预设节点、Claude 域名出口、官方地区、实际连接及日志告警。偏差和复查恢复会同步改变卡片与评分；其他组保留最近一次完整检查结果。旧快照不会覆盖较新的结果，过期观测会标明待更新并保留已确认问题。

## 关闭面板后是否继续监控

| 操作 | 关闭面板后的行为 |
| --- | --- |
| 仅打开面板、只读检查或检查并修复 | 不会因此启动独立常驻监控；面板发起的周期观测停止，本地面板服务空闲约 30 分钟后退出 |
| 「修复并启动 Claude」并成功启动或确认客户端运行 | 启动独立后台监控，关闭面板后继续；默认约每 5 分钟复查环境、约每 30 秒观测实际连接和日志 |
| Claude 退出 | 独立后台监控结束 |

上述周期是调度间隔，查询耗时和重试会影响实际时间。后台监控默认按记录标准修复时区、节点和 TUN，可在本机配置 `monitorAutoRepair=false` 改为仅提醒。连接归属与日志观测始终只读，旧 `monitorKillOnChange` 配置不再执行关闭 Claude 的操作。

面板打开时每 5 秒读取快照，独立观测进程完成后至少间隔 15 秒再开始下一轮。单次观测超过 20 秒只停止该观测进程，稍后重试；快速检查最多 120 秒，完整检查最多 240 秒，超时不会关闭 Claude。

## 命令行

在本目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\claude-preflight.ps1 -NoLaunch -NoPause
powershell -NoProfile -ExecutionPolicy Bypass -File .\claude-preflight.ps1 -NoLaunch -NoPause -CheckMode full
```

`-ApplySettings` 允许按标准修复；`-Relearn` 明确记录环境。新版 `-Force` 不绕过地区或已确认风险的阻断。退出码：0 检查完成且没有启动阻断（仍可能待核实），1 有阻断风险，2 检查未完成，3 地区资料不足而暂停自动启动。

面板使用 `-ResultPath` / `-RunId` 的 schemaVersion 2 结果与结构化进度。根目录保留的 v4 预览 `-Json` / `-JsonPath` 接口未移除，但不是此版本的评分和启动入口。

## 验证

脚本测试使用临时副本、合成数据和模拟请求，不修改实际代理配置或用户环境变量：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\verify.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-risk.ps1
```

浏览器回归需要 Node.js、Playwright 和 Edge。运行前在临时目录安装依赖，并通过环境变量指定，避免把依赖或浏览器数据提交进仓库：

```powershell
$qa = Join-Path $env:TEMP 'claude-launcher-browser-qa'
npm install --prefix $qa playwright
$env:CSL_PLAYWRIGHT_MODULE = Join-Path $qa 'node_modules\playwright'
$env:CSL_EDGE_EXE = Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'
node .\tests\verify-live.cjs
node .\tests\verify-score.cjs
node .\tests\verify-native-hang.cjs
```

`verify-assessment.ps1` 验证带权重的评分与核心复查；`verify-score.cjs` 自动调用它生成临时合成数据，再验证检查中、偏差、恢复、过期和错误分数的界面联动。`verify-native-hang.cjs` 用隔离的原生 PowerShell 后台模拟超时，确认心跳、重试和检查进程回收。

截图和结果默认写入系统临时目录。仓库不包含真实 `preflight.json`、日志、浏览器配置、会话数据、变量备份或本机出口信息。

## 来源与边界

[官方支持地区](https://support.claude.com/en/articles/8461763-where-can-i-access-claude)、[桌面网络要求](https://code.claude.com/docs/en/desktop#network-access-requirements)、[账号告警说明](https://support.claude.com/en/articles/8241253-safeguards-warnings-and-appeals)。地区名单保留来源和获取时间，刷新失败时最多使用 7 天内缓存。

连接核验只覆盖已观测的活跃连接。日志扫描仅保留错误类别、时间和文件名；没有相关告警不等于账号健康，近期日志中的告警也可能已经处理。网络诊断会访问公开探测服务，本工具不会上传对话或凭据。
