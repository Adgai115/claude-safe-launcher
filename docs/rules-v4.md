# 检查规则 v4.0.0（第一批：规则文件）

权威数据源：`rules/checks.json`（UTF-8、无 BOM、LF）。本文件是给人看的摘要；**以 JSON 为准**。

## 严重度（三档）

| JSON `severity` | 界面文案 | 是否挡住安全启动 |
|---|---|---|
| `must_fix` | 必须修 | 是（`canLaunchSafely=false`） |
| `should_fix` | 建议修 | 否 |
| `info` | 仅提示 | 否 |

历史别名「失败 / 警告 / 信息」仅作展示映射，不再作为规则主键。

运行结果 `status` 另含 **`error`**（检查未能完成：超时/配置不可读）：扣分恒 0；任一 `must_fix` 为 `error` 则 `verdict=blocked`。详见 `docs/preflight-json-schema.md`（FROZEN candidate v1）。

## 分类与条数（32）

产品裁定后：`api.anthropic.com` 连通归入 **代理与网络**（`category=proxy-net`，稳定 id 仍为 `exit.api_anthropic`）。

| category | 标题 | 条数 |
|---|---|---|
| `proxy-net` | 代理与网络 | 10 |
| `exit` | 出口一致性 | 8 |
| `locale` | 地区一致性 | 6 |
| `cfg` | 本机配置 | 7 |
| `auto` | 浏览器自动化痕迹 | 1 |

（裁定前口头「9+9」在把 API 连通挪到代理与网络后变为 10+8；总条数仍为 32。）

另有保留分类 `meta`，只含 `meta.unmapped`（`multi`，扣分 0，`fixType=none`）：preflight 遇到没有有效规则 id 的检查项时，以它、`status=error` 记入 JSON 并写明原因，不编造 id。它不计入上面的 32 条。

## 参考评分（不挡启动）

```
score = max(0, 100 − Σ 本次生效的 refDeduction)
```

- **唯一实现**：`claude-rules.ps1` 的 `Get-CslRulesScore`（CLI / 面板共用）。
- **浏览器静态警告 cap**：`staticBrowserCap=20`（见 JSON `scoring.staticBrowserCheckIds`）；超额部分降为 `info`、不再计入扣分。
- 下列项 **`refDeduction` 固定为 0**（仅提示）：`exit.ip_risk_*`、`cfg.https_proxy`、`cfg.claude_desktop`、`locale.system_lang`；无策略组时的 `net.node_lock` 运行时覆盖为 `info`/0。
- 面板与 CLI **禁止各自重算** 25/8；面板只展示本模块写出的分数。

## 安全启动判定（与分数脱钩）

`canLaunchSafely =` 没有任何一条 **`must_fix` 且 failed**。  
`-Force` 仍可在不安全时强启（既有行为）。

## v4 产品裁定摘要（相对 v3.x）

1. **TUN**：以 Clash 配置 `tun.enable` + 默认路由走 Clash TUN 为准；统一文案「TUN 已开启 / 未开启…」；不再用「系统有无 utun」当通过条件（消除 Mac 误报）。
2. **无策略组**：`net.node_lock` → 仅提示、0 分、无修复按钮。
3. **Mac envfix**：`cfg.env_relay_user.fixable` 仅 Windows；Mac 只提示手动删。
4. **api.anthropic.com** → `proxy-net`（见上）。
5. **HTTPS_PROXY / Claude 桌面版 / IP 风险库**：仅提示、0 分。
6. **静默改系统**：v4 起时区/`Start-Process` Clash 改为确认框（本批规则文件标 `notes`；行为改在后续 PR）。

## 字段说明（每条 check）

| 字段 | 含义 |
|---|---|
| `id` | 稳定 id（跨版本尽量不改）；第 2 批起 preflight 的 JSON / 评分直接使用它（不再有 `item.N`） |
| `category` | 上表五类之一 |
| `title` | 短标题 |
| `checks` / `expected` | 查什么 / 期望 |
| `severity` | `must_fix` \| `should_fix` \| `info` |
| `refDeduction` | 参考扣分（失败时） |
| `fixType` / `fixId` | `none` \| `confirm` \| `manual`；`confirm` 时 `fixId` 非空（面板只看 fixId） |
| `containsIp` | `current`/`expected` 可能含出口或 WebRTC IP |
| `multi` | 可选，`true` = 同一 id 允许在结果里出现多次（每个浏览器配置 / 变量 / 文件一行）；其余 id 重复出现视为无法映射 |
| `recheckWin` / `recheckMac` | 修复后复检命令（可为 null） |
| `platforms` | `win` / `mac` |
| `masking` / `notes` | 脱敏约定与备注 |

脱敏**只调用**既有 `Mask-Value` / `Protect-Secret`（`claude-common.ps1`）；本批不新增/不改掩码 helper。Issue 导出格式由 v3.3.0（`feat/issue-export`）拥有。

## 与实现的关系

- 本批：**规则文件 + 单一评分模块 + `-Json` 结构化输出骨架**。
- 不改 `mac/`；不改 issue 导出；对 `claude-preflight.ps1` / `claude-panel.*` 只做最小接线。
