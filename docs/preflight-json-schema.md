# preflight JSON 输出（DRAFT · v4.0.0）

> **状态：草稿。** 键名未产品冻结；欢迎在 PR 评论里改。实现以本文件 + `claude-rules.ps1` 的 `New-CslPreflightResult` 为准。

## 如何得到

```text
powershell -NoProfile -ExecutionPolicy Bypass -File claude-preflight.ps1 -Json -NoLaunch -NoPause
```

- 人类可读日志仍写 stdout（可重定向）。
- 结构化结果写到同目录 **`preflight-result.json`**（UTF-8 无 BOM），并在 stdout 末尾打印一行：
  `CSL_JSON_PATH=<绝对或相对路径>`
- `-Json` 与 `-NoLaunch` 可组合；不含密钥明文（走既有 Mask-Value）。

## 顶层形状（DRAFT）

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
    "passed": 26
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
      "fixable": false,
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

## 每条 check 的必备字段（供后续 issue 导出读取）

| 字段 | 说明 |
|---|---|
| `id` | 与 `rules/checks.json` 对齐 |
| `status` | `passed` \| `failed` \| `info` \| `skipped` |
| `current` | 现状（已脱敏） |
| `expected` | 期望 |
| `recheck` | 复检命令（平台对应；可空） |
| `severity` | 规则严重度（运行时可能被降为 info，如 cap 超额） |
| `refDeductionApplied` | 本次实际计入的扣分 |

**不要**在本对象里放 controller secret、完整 token、未掩码 IP 以外的密钥。IP 按既有规则：保留完整值 + 警告行由调用方处理。

## `verdict`

| 值 | 含义 |
|---|---|
| `ok` | `canLaunchSafely=true` |
| `blocked` | 存在 must_fix failed |
| `force` | 本会被 block，但使用了 `-Force` |

面板应读取本 JSON 的 `score` / `canLaunchSafely`，**禁止**再用 25/8 本地重算。
