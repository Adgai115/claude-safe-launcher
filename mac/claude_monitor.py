#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Claude 运行期间后台监控（由 claude_preflight.py 在启动 Claude 后后台运行）
每 monitorIntervalMin 分钟检查：Claude 边缘出口 IP、Claude 策略组节点。
变化时：尝试切回 → 仍不对则系统通知；monitorKillOnChange=true 时关闭 Claude。
Claude 退出后自动结束。单实例（pid 文件）。
测试: python3 claude_monitor.py --once --dry-run
"""
from __future__ import annotations

import argparse
import atexit
import os
import sys
import time
from pathlib import Path
from typing import Any, Dict, List

sys.path.insert(0, str(Path(__file__).resolve().parent))
import claude_common as C

PID_FILE = C.ROOT / "claude-monitor.pid"


def out_mon(t: str, once: bool) -> None:
    if once:
        print(t)


def acquire_pid() -> bool:
    if PID_FILE.is_file():
        try:
            old = int(PID_FILE.read_text().strip())
            # check alive
            os.kill(old, 0)
            return False  # still running
        except (ValueError, OSError, ProcessLookupError):
            pass
    try:
        PID_FILE.write_text(str(os.getpid()), encoding="utf-8")
    except OSError:
        return True

    def _cleanup() -> None:
        try:
            if PID_FILE.is_file() and PID_FILE.read_text().strip() == str(os.getpid()):
                PID_FILE.unlink()
        except OSError:
            pass

    atexit.register(_cleanup)
    return True


def test_state(cfg: Dict[str, Any]) -> Dict[str, Any]:
    r: Dict[str, Any] = {"node": None, "ctlOk": False, "ip": None, "loc": None, "problems": []}
    g = C.ctl_get_group(cfg, cfg.get("claudeGroup") or "")
    if g:
        r["ctlOk"] = True
        r["node"] = g.get("now")
        if cfg.get("expectedNode") and g.get("now") != cfg["expectedNode"]:
            r["problems"].append(f"Claude 组节点变为 {g.get('now')}")
    tr = C.get_trace("https://claude.ai/cdn-cgi/trace")
    r["ip"] = tr.get("ip")
    r["loc"] = tr.get("loc")
    if not r["ip"]:
        r["problems"].append("claude.ai trace 无响应")
    elif cfg.get("expectedIp") and (
        r["ip"] != cfg["expectedIp"] or r["loc"] != cfg.get("expectedLoc")
    ):
        r["problems"].append(f"Claude 看到的 IP 变为 {r['ip']} loc={r['loc']}")
    return r


def invoke_check(cfg: Dict[str, Any], once: bool, dry_run: bool, tag: str) -> None:
    s = test_state(cfg)
    ctl_txt = f"node={s['node']}" if s["ctlOk"] else "node=控制器不可达"
    if not s["problems"]:
        out_mon(f"正常: ip={s['ip']} loc={s['loc']} {ctl_txt}", once)
        if once:
            C.write_log(f"{tag} OK | ip={s['ip']} | {ctl_txt}")
        return
    p = "; ".join(s["problems"])
    C.write_log(f"{tag} CHANGE | {p}")
    out_mon(f"发现变化: {p}", once)
    if dry_run:
        plan: List[str] = []
        if s["ctlOk"]:
            plan.append(f"PUT 切回 {cfg.get('claudeGroup')}/{cfg.get('mainGroup')} → {cfg.get('expectedNode')}")
        else:
            plan.append("控制器不可达，无法自动切回")
        plan.append("若仍不对：弹出系统通知")
        if cfg.get("monitorKillOnChange"):
            plan.append("并关闭 Claude（monitorKillOnChange=true）")
        msg = " → ".join(plan)
        C.write_log(f"{tag} 将执行(未执行): {msg}")
        out_mon(f"[DryRun] 将执行(未执行): {msg}", once)
        return
    if s["ctlOk"] and cfg.get("expectedNode"):
        C.ctl_select_node(cfg, cfg.get("claudeGroup") or "", cfg["expectedNode"])
        if cfg.get("pinMainGroup") and cfg.get("mainGroup"):
            C.ctl_select_node(cfg, cfg["mainGroup"], cfg["expectedNode"])
        time.sleep(3)
        s2 = test_state(cfg)
        if not s2["problems"]:
            C.write_log(f"{tag} FIXED | 已切回 {cfg['expectedNode']} ip={s2['ip']}")
            C.notify("Claude 监控", f"节点曾被切换，已自动切回 {cfg['expectedNode']}（IP {s2['ip']}）")
            return
        p = "; ".join(s2["problems"])
    C.write_log(f"{tag} STILL-WRONG | {p}")
    C.notify("Claude 出口异常", f"{p}。请检查 Clash 节点，期望 IP {cfg.get('expectedIp')}。")
    if cfg.get("monitorKillOnChange"):
        n = C.kill_claude()
        C.write_log(f"{tag} KILLED Claude ({n} 个进程)")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    cfg = C.load_config()
    tag = "[monitor]" + ("[DryRun]" if args.dry_run else "")

    if not acquire_pid():
        C.write_log(f"{tag} 已有监控实例在运行，本实例退出")
        out_mon("已有监控实例在运行，退出", args.once)
        return 0

    if args.once:
        invoke_check(cfg, True, args.dry_run, tag)
        return 0

    waited = 0
    while not C.claude_running() and waited < 90:
        time.sleep(3)
        waited += 3
    if not C.claude_running():
        C.write_log(f"{tag} 90 秒内未检测到 Claude，监控退出")
        return 0
    interval = max(1, int(cfg.get("monitorIntervalMin") or 5)) * 60
    C.write_log(f"{tag} 开始监控，间隔 {interval // 60} 分钟")
    while True:
        invoke_check(cfg, False, args.dry_run, tag)
        slept = 0
        while slept < interval:
            time.sleep(15)
            slept += 15
            if not C.claude_running():
                C.write_log(f"{tag} Claude 已退出，监控结束")
                return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
