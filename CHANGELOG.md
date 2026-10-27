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
- **不在本批**：不改 `mac/`；不改 issue 导出（归 v3.3.0 / `feat/issue-export`）；不改静默 Start-Process / tzutil 行为（标在规则 notes，后续 PR）。

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
