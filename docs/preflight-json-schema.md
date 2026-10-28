# preflight JSON 输出（**FROZEN candidate v1** · pending product confirm）

> **状态：冻结候选 v1，待产品最终确认。** 实现以本文件 + `claude-rules.ps1` 为准。键名变更需产品拍板后再动。

## 如何得到

```text
powershell -NoProfile -ExecutionPolicy Bypass -File claude-preflight.ps1 -Json -NoLaunch -NoPause
```

- 人类可读日志仍写 stdout。
- 结构化结果写到同目录 **`preflight-result.json`**（UTF-8 无 BOM）。
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
      "refDeductionApplied": 25,
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

## `status`（每条 check）

| 值 | 含义 | 参考扣分 | 对 `verdict` |
|---|---|---|---|
| `passed` | 通过 | 0 | — |
| `failed` | 查完了，未达预期 | 按 `refDeduction`（受 cap / hint-only） | `must_fix` → `blocked` |
| `error` | **未能完成**（超时、配置不可读等），**不是** failed | **恒为 0** | 任意 `must_fix` 且 `error` → `blocked`（不得为 `ok`）；`current` 写明原因（已脱敏） |
| `info` | 仅提示 | 0 | — |
| `skipped` | 跳过 | 0 | — |

## 修复字段（取代旧 `fixable`）

| 字段 | 类型 | 说明 |
|---|---|---|
| `fixType` | enum `none` \| `confirm` \| `manual` | `confirm` = 确认框 + 备份 + 可撤销 |
| `fixId` | string \| null | 修复动作 id；`none`/`manual` 时为 null；**面板只凭 `fixId` 是否非空显示修复按钮** |

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
| `schemaVersion` | 固定 `1`（本冻结候选） |
| `score` / `scoreMode` | 参考分；`scoreMode` = `reference_only` |
| `canLaunchSafely` | 无 `must_fix` 的 `failed` **且** 无 `must_fix` 的 `error` |
| `verdict` | `ok` \| `blocked` \| `force`（`-Force` 强启时） |
| `summary.error` | `status=error` 的条数 |

**不要**放 controller secret、完整 token、未掩码密钥。脱敏只调用既有 `Mask-Value` / `Protect-Secret`。
