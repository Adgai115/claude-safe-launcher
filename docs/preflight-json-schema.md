# preflight JSON 输出（**FROZEN v1** · `schemaVersion: 1`）

> **状态：v1 已冻结（v4.0.0）。** 实现以本文件 + `claude-rules.ps1` 为准；下面「冻结键清单」是键名的唯一权威，`tests/rules.Tests.ps1` 会解析本文件并与实际 JSON 的键集合逐个对比（缺 0、多 0）。
>
> **版本规则：改键名必须升 schemaVersion。** 重命名、删除任何键，或改变键的含义 / 类型，都必须同时把 `schemaVersion` 升为 2（以此类推）并更新本文件和测试；只新增键也要先升版本并写进清单（不允许悄悄多键）。消费方（面板、问题说明导出、R5 端到端、外部脚本）应先读 `schemaVersion`，不认识的版本不要硬解析。

## 如何得到

```text
powershell -NoProfile -ExecutionPolicy Bypass -File claude-preflight.ps1 -Json -NoLaunch -NoPause
```

- 人类可读日志仍写 stdout。
- 只有带 `-Json` 才写结构化结果（v4.0.0 起；不带就不生成也不覆盖），默认写到同目录 **`preflight-result.json`**（UTF-8 无 BOM）。
- `-JsonPath <文件路径>`：配合 `-Json` 写到指定文件；目标目录必须已存在，否则打印 `CSL_JSON_ERROR=` 并以退出码 2 退出（不自动创建）；只给 `-JsonPath` 不给 `-Json` 也同样报错退出，不写任何文件。
- `-Json` 时额外打印：`CSL_JSON_PATH=<path>`。
- 有可修项时 stdout 可出现：`CSL_FIX_ID=<fixId>`（面板据此显示修复按钮，不依赖中文文案）。

## 顶层形状

```json
{
  "schemaVersion": 1,
  "rulesVersion": "4.0.0",
  "generatedAt": "2026-10-27T05:00:00Z",
  "platform": "win",
  "score": 72,
  "scoreMode": "reference_only",
  "canLaunchSafely": false,
  "verdict": "blocked",
  "summary": {
    "must_fix_failed": 1,
    "should_fix_failed": 2,
    "info": 3,
    "passed": 25,
    "error": 1
  },
  "checks": [
    {
      "id": "net.tun",
      "category": "proxy-net",
      "title": "TUN / 虚拟网卡",
      "severity": "must_fix",
      "status": "failed",
      "current": "TUN 未开启…",
      "expected": "TUN 已开启（按 Clash 配置与路由判定）",
      "refDeductionRule": 25,
      "refDeductionApplied": 25,
      "isStaticBrowser": false,
      "recheck": "powershell -NoProfile -ExecutionPolicy Bypass -File claude-preflight.ps1 -NoLaunch -NoPause",
      "fixType": "manual",
      "fixId": null,
      "containsIp": false,
      "masked": true
    }
  ],
  "browserCap": {
    "staticWarnSumBeforeCap": 28,
    "staticWarnSumAfterCap": 20,
    "cap": 20
  }
}
```

## 冻结键清单（v1，机器可读）

测试按下面的表解析：「范围」= `top`（顶层）、`summary`、`checks`（`checks[]` 每一行）、`browserCap`；「必有」= `是` 表示每份 JSON / 每一行都必须有，`否` 表示只在条件满足时才出现。表里没有的键不允许出现。

| 范围 | 键 | 必有 |
|---|---|---|
| top | `schemaVersion` | 是 |
| top | `rulesVersion` | 是 |
| top | `generatedAt` | 是 |
| top | `platform` | 是 |
| top | `score` | 是 |
| top | `scoreMode` | 是 |
| top | `canLaunchSafely` | 是 |
| top | `verdict` | 是 |
| top | `summary` | 是 |
| top | `checks` | 是 |
| top | `browserCap` | 是 |
| summary | `must_fix_failed` | 是 |
| summary | `should_fix_failed` | 是 |
| summary | `info` | 是 |
| summary | `passed` | 是 |
| summary | `error` | 是 |
| checks | `id` | 是 |
| checks | `category` | 是 |
| checks | `title` | 是 |
| checks | `severity` | 是 |
| checks | `status` | 是 |
| checks | `current` | 是 |
| checks | `expected` | 是 |
| checks | `recheck` | 是 |
| checks | `fixType` | 是 |
| checks | `fixId` | 是 |
| checks | `containsIp` | 是 |
| checks | `masked` | 是 |
| checks | `refDeductionRule` | 是 |
| checks | `refDeductionApplied` | 是 |
| checks | `isStaticBrowser` | 是 |
| checks | `notes` | 否 |
| browserCap | `staticWarnSumBeforeCap` | 是 |
| browserCap | `staticWarnSumAfterCap` | 是 |
| browserCap | `cap` | 是 |

- `refDeductionRule`：目录里这条规则的参考扣分（int）；`refDeductionApplied`：这次实际扣的分（受 cap / hint-only / `error` 恒 0 影响，int）。`isStaticBrowser`：该 id 是否属于受 cap 约束的静态浏览器检查（bool）。
- `notes`（否）：只在调用方给出原因时才有，目前只有 `meta.unmapped` 行带。
- `schemaVersion` 的类型是整数 `1`（不是字符串）。

## `status`（每条 check）

| 值 | 含义 | 参考扣分 | 对 `verdict` |
|---|---|---|---|
| `passed` | 通过 | 0 | — |
| `failed` | 查完了，未达预期 | 按目录 refDeduction 扣分，实际值见 `refDeductionApplied`（受 cap / hint-only） | `must_fix` → `blocked` |
| `error` | **未能完成**（超时、配置不可读等），**不是** failed | **恒为 0** | 任意 `must_fix` 且 `error` → `blocked`（不得为 `ok`）；`current` 写明原因（已脱敏；`meta.unmapped` 行例外：原因写 `notes`，`current` 留空） |
| `info` | 仅提示 | 0 | — |
| `skipped` | 跳过 | 0 | — |

## 修复字段（取代旧 `fixable`）

| 字段 | 类型 | 说明 |
|---|---|---|
| `fixType` | enum `none` \| `confirm` \| `manual` | `confirm` = 确认框 + 备份 + 可撤销 |
| `fixId` | string \| null | 修复动作 id；`none`/`manual` 时为 null；**面板只凭 `fixId` 是否非空显示修复按钮** |

## `id`（v4.0.0 第 2 批起）

`checks[].id` 是 `rules/checks.json` 里的**真实规则 id**（如 `exit.api_anthropic`），不再有 `item.N` 占位。`claude-preflight.ps1` 的每个检查调用点（`Say-Fail` / `Say-Warn` / `Say-Note` / `Soft-BrowserWarn`）写死一个 `-Id`，同一调用点永远映射到同一个 id（确定、与运行顺序无关）。

- 只有失败 / 警告 / 提示项会写进 JSON；通过项和纯信息行不记录。
- 同一个 id 只有目录里标 `"multi": true` 时才会出现多次（每个浏览器配置 / 变量 / 文件一行）：`net.node_lock`、`net.browser_webrtc_chromium`、`net.browser_webrtc_firefox`、`locale.browser_lang_static`、`cfg.env_relay_user`、`cfg.env_relay_machine`、`cfg.residue_claude`。
- **无法映射**的项（没有 id、id 不在目录里、非 `multi` 的 id 重复）**不丢、也不编造 id**：以目录里的保留 id **`meta.unmapped`**（`category=meta`，`multi: true`，不属于那 33 条检查）、**`status=error`** 写进 JSON，原因写在**该行的 `notes`**（形如「未映射：id 不在 rules/checks.json 里」，不回显原 id，所以 JSON 里 `item.` 出现 0 次）；`current` 留空，不带任何原文。`error` 行评分器不扣分，但 `severity` 仍随原级别（FAIL → `must_fix`，所以仍会 `canLaunchSafely=false` / `verdict=blocked`）；分数由 preflight 按原权重补扣，与 d025841 一致。屏幕上同时提示。测试保证 preflight 自身不会产生这种项。
- 验收（R0）：JSON 里每个 `id` 都在 `rules/checks.json` 里；除 `multi` 外无重复；`item.` 出现 0 次；同样的输入下，`score`、`canLaunchSafely`、每项 `status`、`fixId` 与 d025841 一致，只有 `id` 字段的值不同（唯一例外：未映射项按上条记为 `error`）。
- `browser-check.json` 解析失败的警告记在专门的 **`browser.check_parse`**（`category=auto`，`should_fix`，扣 3，`fixType=none`；产品裁定，不再挂在 `exit.webrtc_srflx` 下）。
- 行里的 `expected` / `title` / `category` 来自目录；可选字段 `notes`（字符串）只在调用方给出时才有，目前只有 `meta.unmapped` 行带（写明未映射原因），其它行没有该字段；`current` 仍只含名称与状态（无值、无 `*`、无 `=`）。
- `fixId`：目录里 `fixType=confirm` 的规则，只有 preflight 真有对应确认修复时才带 `fixId`——目前只有文本含「用户级」的失败项（用户级环境变量）带 `fixType=confirm` + `envfix.user-anthropic`，与 d025841 的规则一模一样（不再看 id）；其余所有行 `fixType=none`、`fixId=null`——包括 `net.clash_running` / `net.node_lock` / `locale.system_tz`（和 d025841 一样；这些确认修复接入后再放开）。

已知 `fixId`（confirm）：

| fixId | check id |
|---|---|
| `clash.start` | `net.clash_running` |
| `proxy.node-lock` | `net.node_lock` |
| `locale.timezone` | `locale.system_tz` |
| `envfix.user-anthropic` | `cfg.env_relay_user`（原检查组「环境变量」一键修） |

## `containsIp`

布尔：`current` / `expected` 中**可能**含出口 IP 或 WebRTC IP 时为 `true`（导出/展示时走既有 IP 保留+警告约定）。目录里已标的 id：`net.ipv6_leak`、`exit.local_ip`、`exit.three_way_ip`、`exit.webrtc_srflx`、`exit.webrtc_ipv6`、`exit.ip_risk_*`。

## 其它顶层字段

| 字段 | 说明 |
|---|---|
| `schemaVersion` | 固定整数 `1`（v1 已冻结）；改键名必须升版本（见文首） |
| `score` / `scoreMode` | 参考分；`scoreMode` = `reference_only` |
| `canLaunchSafely` | 无 `must_fix` 的 `failed` **且** 无 `must_fix` 的 `error` |
| `verdict` | `ok` \| `blocked` \| `force`（`-Force` 强启时） |
| `summary.error` | `status=error` 的条数 |

**不要**放 controller secret、完整 token、未掩码密钥。脱敏只调用既有 `Mask-Value` / `Protect-Secret`。
