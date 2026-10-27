# v3.3.0 验收标准（草案，2026-10-27 04:17）

## 单测通用标准（合并必要条件）
- 每个测试文件都有「报错即失败」机制（trap + $ErrorActionPreference=Stop）；任何未捕获报错 → FAILED、退出码 1。附反向验证。
- Windows PowerShell 5.1 连跑 10 次：FAIL = 0、SKIP = 0、退出码 = 0、日志无任何报错；PASS 数按小节与预期逐节对账，差异必须写出断言名和原因。
- 平台判断不得依赖 $IsWindows。
- 测试方自有的 CLI/面板回归脚本同样适用。

## 功能项（详见路线图）
- envFixEnabled（默认 true）/ envFixKeep（默认空）。
- 确认名单只显示变量名和动作，不显示值（含打码值）；-FixEnv 先问 y/N，-Yes 跳过（CHANGELOG 写明行为变化）。
- 冲突跳过后逐项跟踪撤销状态，被跳过项之后仍可撤销（v3.2.0 已知问题，必修）。
- 通配符枚举机器级变量（只影响提示）。
- issue-export、PATH 截断修复。
- （必修，来自 v3.2.0）测试用内存存储记录所有 GetUserEntry/SetUserEntry 调用名，断言撤销全程无空变量名调用。
- （必修）preflight/envfix 中 foreach (@($x.prop)) 写法全部改为显式跳过 $null。
