# 更新日志

## Unreleased

### v4.0.0（第一批 · 规则文件 + 结构化 JSON + 单一评分）

- 新增 `rules/checks.json`：32 条检查的权威目录（`must_fix` / `should_fix` / `info`），含产品裁定（TUN=Clash `tun.enable`+路由、`api.anthropic`→`proxy-net`、HTTPS_PROXY/桌面版/IP 风险仅提示 0 分、Mac envfix 仅 win `fixable` 等）。
- 新增 `docs/rules-v4.md`、`docs/preflight-json-schema.md`（JSON 键名 **DRAFT**，未产品冻结）。
- 新增 `claude-rules.ps1`：`Get-CslRulesScore` / `New-CslPreflightResult` 为 CLI 与面板共用的**唯一**参考评分入口；`score = max(0,100−ΣrefDeduction)`，浏览器静态警告 cap 20；`canLaunchSafely` 仅看 must_fix。
- `claude-preflight.ps1`：接入规则评分；新增 `-Json`；写出 `preflight-result.json`（含每条 `current` / `expected` / `recheck`，供后续 issue 导出读取）。不改 Mask-Value / Protect-Secret。
- `claude-panel.html`：去掉本地 25/8 重算，分数只取自预检「一致性评分」行。
- 新增 `tests/rules.Tests.ps1`。
- JSON 输出冻结候选 v1：`status` 含 `error`（扣 0；must_fix error → blocked）；`fixType`/`fixId` 取代 `fixable`；`containsIp`；`summary.error`。面板修复按钮跟 `CSL_FIX_ID`/`fixId`（如 `envfix.user-anthropic`），不再依赖「用户级」文案。
- JSON 的 `current` 对环境变量项只输出变量名和状态（如 `用户级 NAME：已设置`），不含值、不含打码值（无 `=`、无 `*`）；覆盖第 9 组用户级变量和 `HTTPS_PROXY=…`。屏幕和 CLI 上的检查行不变。新增断言用 `CSL_TEST_CANARY` 金丝雀值锁定。
- 修复回归：`claude-rules.ps1` 不再在脚本作用域设置 `Set-StrictMode -Version Latest`（dot-source 进 preflight 后严格模式泄漏到 `claude-common.ps1`，`Load-Config` 等在 CLI 中抛 PropertyNotFoundStrict）。新增断言锁定调用方不受严格模式影响。
- **不在本批**：不改 `mac/`；issue 导出沿用 v3.3.0 已发布实现，v4 未改动；不改静默 Start-Process / tzutil 行为（标在规则 notes，后续 PR）。

### v4.0.0（第 2 批 · 真实规则 id）

- `claude-preflight.ps1`：评分与 `preflight-result.json` 的每条检查改用 `rules/checks.json` 的真实规则 id（如 `exit.api_anthropic`），取代 `item.N` 占位；每个检查调用点映射确定，无法映射的项以保留 id `meta.unmapped`（目录新增，`multi`）、`status=error` 写进 JSON 并写明原因（不编造 id，分数按原权重照扣）；`score` / `canLaunchSafely` / 每项 `status` 与 `fixId` 与 d025841 一致（只有 `id` 值不同；`fixType` 也恢复为 d025841 的 none，仅「用户级」失败项为 confirm）；`current` 仍只含名称与状态。目录新增可选 `multi`，并去掉 3 条 `expected` 里的 `*`。目录新增 `browser.check_parse`（`auto`，`should_fix`，扣 3）承接「browser-check.json 解析失败」警告（产品裁定，不再用 `exit.webrtc_srflx`）；未映射项的原因写进该行 `notes`，`current` 留空；`claude-rules.ps1` 的行新增可选 `notes` 字段（仅调用方给出时才有）。
- 脱敏（R4）：`preflight-result.json` 每条检查项的 `current` 复用 v3.3.0 issue 导出的 `Protect-CslIssueValue`：路径用户名 → `%USERPROFILE%`、计算机名 → `<PC>`、订阅链接 / 节点域名遮罩、`controllerSecret` / 令牌不输出；出口 IP / WebRTC IP 默认保留，`-HideIp` 时遮罩；原文含公网 IP 的行 `containsIp=true`（`-HideIp` 后照样 true）。`tests/rules.Tests.ps1` 新增 40 条断言（175 → 215）。
- JSON 文件改为显式开启（R4a）：`claude-preflight.ps1` 只有带 `-Json` 才写 `preflight-result.json`，不带就不生成也不覆盖（以前每次运行都写到脚本目录）；新增 `-JsonPath <文件路径>`，配合 `-Json` 把 JSON 写到指定文件，目标目录不存在就在任何检查之前报错退出（`CSL_JSON_ERROR=`，退出码 2，不自动创建），只给 `-JsonPath` 不给 `-Json` 同样报错退出（退出码 2，提示需配合 `-Json`，不写任何文件）。面板和 issue 导出不读这个文件，行为不变。`claude-rules.ps1` 新增 `Resolve-CslPreflightJsonPath` / `Save-CslPreflightResultJson`；`tests/rules.Tests.ps1` 新增 36 条断言（215 → 251）。
- 测试（R2，n2b）：`tests/envfix.Tests.ps1` 新增一节，在子进程里走真实的 `claude-preflight.ps1 -UndoFix` 路径（临时目录里的脚本副本 + 内存变量表，只用 `CSL_TEST_*` 金丝雀），断言「已恢复」行只有变量名，不含值、`*` 和 `=`；envfix 断言数 292 → 299（Windows）。仅测试改动。
- 测试加固（R3）：`tests/envfix.Tests.ps1` 里所有读取测试自己生成的备份文件的地方都先 `Test-Path`，文件缺失时跳过读取、每条依赖它的断言记一次失败（断言总数不变，不再连带未捕获报错）；三份测试的未捕获报错行前缀改为 `UNCAUGHT`，`(?m)^\s*FAIL(?!ED)\b` 只数断言失败、`(?m)^\s*UNCAUGHT\b` 只数未捕获报错，分别与汇总行的 N、M 一致；仅测试改动，无产品代码变化。

## v3.3.0（一期 · Windows）

- 新增「问题说明」导出：面板对不可一键修复的失败/警告项提供「复制问题说明」，页脚提供「复制全部问题」与「隐藏 IP」开关；整屏布局保持不变。
- CLI：`-ExportIssues`（建议配合 `-NoLaunch -NoPause`）打印相同四段结构文本；可选 `-HideIp`。
- 每条说明含：问题、当前状态（脱敏）、期望状态、复查命令；固定结尾「请只给出建议，确认后再修改；不要修改 Claude Code 自身依赖的环境变量。」
- 脱敏：路径用户名 → `%USERPROFILE%`；计算机名 → `<PC>`；订阅链接与节点域名/IP 全部遮罩；出口 IP / WebRTC IP 默认保留并附提示行「本说明包含你的出口 IP，粘贴前请确认」，「隐藏 IP」/ `-HideIp` 时一并遮罩并省略提示行。`controllerSecret` / 令牌绝不输出。复用 `Mask-Value` / `Protect-Secret`。
- **不调用**任何本地或云端 agent，只生成可复制文本。
- 问题说明在面板侧由已有检查结果生成（无新增写接口）；注入 `__CSL_USERPROFILE__` / `__CSL_COMPUTERNAME__` 供脱敏。既有 `/api/*` 仍走 v3.2.0 同源安全门。
- 新增 `claude-issueexport.ps1` 与 `tests/issueexport.Tests.ps1`。
- 测试：所有测试文件统一加上「报错即失败」：任何未捕获的报错都输出 FAILED、退出码 1，不再打印 ALL PASSED。
- 测试：用记录型内存存储直接断言修复 / 撤销过程中不会以空变量名读写环境变量。
- 修复：`claude-envfix.ps1` / `claude-preflight.ps1` 中所有遍历 `@($x.属性)` 的循环都先显式跳过 `$null`（备份 `entries` 里混入 null 元素时撤销不再报错）；新增静态检查测试锁定这一写法。
- 修复（v3.2.0 已知问题）：撤销逐项记录状态。冲突跳过的变量在备份里保持「可撤销」，其余变量标记为已撤销；处理好冲突后用 `-UndoFix -UndoId <id>` 可单独撤销被跳过的变量，不会再动已撤销的变量；全部条目都撤销后整份备份才算已撤销。旧备份的整份 `undone` 标记照常兼容。`-ListFixes` 显示「部分已撤销」，撤销结果提示如何重试。
- 修复：通配符模式（如默认 `ANTHROPIC_*`）现在也枚举机器级变量名（只读 HKLM 环境变量键），只存在于机器级的匹配项会在检查第 9 组和修复计划里提示「需要管理员手动处理」；只影响提示，从不改写机器级变量。
- **行为变化**：`-FixEnv` 现在先列出确认名单并问 y/N，只有回答 y 才修改；回答 n、直接回车、读不到输入都视为不同意，不改系统、不写备份（退出码 1）。`-NoPause` 下同样会问。脚本或无人值守请加新开关 `-Yes` 跳过确认。v3.2.0 的「显式 `-FixEnv` 即视为同意」不再成立。
- **行为变化**：确认名单只显示变量名和动作（「将清除 User 变量名」），不再显示值，打码值也不显示；CLI 预览、修复结果、撤销结果和面板「修复」「撤销」确认框一致。
- 新增 `preflight.json` 配置：`envFixEnabled`（默认 `true`，设为 `false` 时 `-FixEnv` 和面板「修复」不做任何修改，撤销和列表照常可用）；`envFixKeep`（默认空，列出的变量名（可用通配符）在一键修复时保留，确认名单里显示为「保留」）。
- 修复（v3.2.0 已知问题）：面板第 9 组「环境变量」卡片里的每一行都完整换行显示，长 PATH 类值不再被省略号截断；其他卡片的通过/提示行仍保持一行。失败/警告行里没有空格的长串也会正常折行。
- 已知限制：Mac 端这一版没有改动。
- 撤销备份中若有条目缺少变量名（name 缺失、为空、空白或 null），整份备份按损坏处理，拒绝撤销并提示「备份文件损坏（有条目缺少变量名）」，绝不以空变量名读写环境变量。
- 新增单测：部分撤销的备份在自动清理时不会被删除，跳过的条目清理后仍可撤销。
- 损坏的撤销备份一律不自动清理：不占保留名额，清理时直接跳过；`-ListFixes` 标为「损坏（不会自动清理）」并给出文件路径。
- 读不到机器级注册表（权限不够、键不存在）时，回退到 v3.2.0 的行为，只查用户级，不报错。
- 面板：卡片里的行放不下时，不再被悄悄截掉，而是把次要的行（先通过/提示，再从下往上）折叠成一行「还有 N 条未显示」，鼠标悬停看全文；整页在 1280×800 下不用滚动。
- 面板：折叠行包含失败时显示「还有 N 条未显示（含 X 条失败）」并用失败色（无渐变、无粉色）；卡片标题状态和计数（如「失败 4」）包含被折叠的失败。截图见 `docs/screenshots/`。
- `-ListFixes`、撤销冲突提示和修复/撤销结果只写变量名和动作，不再出现任何值（打码值也去掉）：列表每条形如 `CSL_TEST_SKIP_A: 已删除（可撤销）`，冲突提示为「冲突: 变量名 当前值与修复后不一致，已跳过」；面板撤销冲突框同样只显示变量名。第 9 组检查卡片里的检测结果仍带打码值，排到 v3.4.0。

## v3.2.0（一期 · Windows）


- 新增用户级中转环境变量一键修复 / 撤销：检查第 9 组与 CLI/面板共用同一模式源（默认 `ANTHROPIC_*` 列表，可用 `-FixVarPattern` 或 `preflight.json` 的 `fixVarPatterns`）。
- CLI：`-FixEnv` / `-DryRun` / `-UndoFix [-UndoId <id>]` / `-ListFixes` / `-TestMode`；显式 `-FixEnv`/`-UndoFix` 视为同意，可与 `-NoPause` 同用；纯 `-NoPause` 绝不自动修。
- 修复后从用户级注册表重新核对，并广播 `WM_SETTINGCHANGE`「Environment」；面板与 CLI 提示「新开的终端才会生效」。
- 面板第 9 组提供「修复」「撤销上次修复」，走 `/api/envfix`（plan/apply/undo/list），确认框展示脱敏值。
- 备份目录 `backups/`（已 gitignore），保留至少 10 条可撤销记录；两次修复后一次撤销回到最早原值；冲突时 `-NoPause` 跳过并非 0 退出。
- `-TestMode` 仅允许 `CSL_TEST_` 前缀；非 TestMode 拒绝含 `CSL_TEST_` 的模式。
- 脱敏集中到 `claude-common.ps1` 的 `Protect-Secret` / `Mask-Value`（预留 Path→`%USERPROFILE%`、URL 掩码，供 v3.3.0 复用）。
- 用户级读写走注册表原始值（`DoNotExpandEnvironmentNames` + `GetValueKind` / `SetValue`+kind / `DeleteValue`），保留 String vs ExpandString；空字符串与「不存在」区分。
- `-FailAtIndex`（仅 TestMode）验证整单回滚；重复撤销报告 already undone；损坏备份报错且不改系统。
- 面板 API：Host/Origin/JSON Content-Type/`X-CSL-Token` 校验；loopback 绑定；撤销 undo-plan → 冲突选择 → undo-apply。
- 已知限制：Mac 端这一版没有改动；Machine 级变量只提示需管理员手动处理，不提权修改。
- 修复：备份写入失败时立即中止，不删除任何用户变量（`Write-CslEnvBackup` 写入后校验可读可解析）。
- 修复：修复备份 id 改为 UTC `yyyyMMddTHHmmssfff`，取「当前时间」与「已有最大 id + 1ms」中较晚者，单调递增；同一秒多次修复、已有更晚 id、时钟回拨时都按真实先后排序，`-UndoFix` 撤销最近一次。
- 修复：`-TestMode` 下撤销（含 DryRun/plan）校验整条连通链变量名均为 `CSL_TEST_*`；面板 `undo-plan`/`undo-apply` 传入 TestMode。
- 加固：撤销因冲突跳过的备份写入 `skipped` 名单，清理时永不删除该类备份（原值留在文件中可手动恢复）。
- 已知问题：撤销时冲突跳过的变量，该次备份会被标记为已撤销，无法再用 `-UndoFix` 恢复；备份文件保留不删，值可从文件手动恢复；v3.3.0 修复。
- 修复：撤销失败时 CLI 不再在 Windows PowerShell 5.1 上打出红色报错和空的「[警告]」行（冲突列表为空或含空值时跳过）。（`8c82758`）
- 修复：缺少 `entries` 字段或 `entries` 为 null 的备份按损坏处理（提示与损坏备份一致），撤销其他备份时不再在 5.1 上报 NullArray。（`435c1df`）
- 测试：单测改用 `[Environment]::OSVersion.Platform` 判断平台（5.1 没有 `$IsWindows`，此前 4 条备份不可写用例在 Windows 上被跳过）；任何未捕获的报错都判失败、退出码 1。（`7a69c37`）

## v3.1.0（一期 · Windows）

- 新增第 12 组「浏览器环境」检查：扫描 Chrome、Edge、Brave 各配置的 WebRTC 设置和语言，以及 Firefox 的 WebRTC 开关；面板里实测 WebRTC 公网 IP、浏览器时区、语言和自动化标记。（#3）
- WebRTC 公网 IP 和出口 IP 不一致判失败，扣 25 分；静态扣分封顶 20 分。（#3）
- 语言规则：en 开头不报；不带地区的语言和出口国家的常用语言不一致时给警告，不扣分，归入「建议修」。（#3）
- 每个浏览器配置单独显示一行，比如「Chrome · Profile 1（您的 Chrome）」。（#3）
- 修复：浏览器快照按 UTC 判断是否过期，时钟超前的快照也会判成过期。（#3）
- 面板一屏显示全部 12 组，机械主题改用纯色线条。（#3）
- 已知限制：Mac 端这一版没有改动，也没在真机上验证过。
- 回归测试：Windows（PS 5.1）全部通过。

## v3.0.0

基线版本（合并一期浏览器检查前）。对应提交 `6263c36`。

- 新增 `.gitattributes`，统一换行格式。（#1）
- 修复：Windows 端 DNS fake-ip 范围。（#2）
