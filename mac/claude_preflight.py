#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Claude 桌面版 启动前检查 + 自动设置（macOS 通用版）
用法: python3 claude_preflight.py [--force] [--no-pause] [--no-launch] [--relearn]
配置: 同目录 preflight.json（controllerSecret 不会被打印）
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
import claude_common as C


class Items:
    def __init__(self) -> None:
        self.items: List[Dict[str, Any]] = []

    def add(self, level: str, text: str, weight: int) -> None:
        self.items.append({"Level": level, "Text": text, "Weight": weight})


ITEMS = Items()


def say_head(t: str) -> None:
    print()
    print(f"== {t}")


def say_pass(t: str) -> None:
    print(f"  [通过] {t}")


def say_info(t: str) -> None:
    print(f"  [信息] {t}")


def say_fix(t: str) -> None:
    print(f"  [修复] {t}")


def say_note(t: str) -> None:
    print(f"  [提示] {t}")
    ITEMS.add("NOTE", t, 0)


def say_warn(t: str, w: int = 8) -> None:
    print(f"  [警告] {t}")
    ITEMS.add("WARN", t, w)


def say_fail(t: str, w: int = 25) -> None:
    print(f"  [失败] {t}")
    ITEMS.add("FAIL", t, w)


def main() -> int:
    ap = argparse.ArgumentParser(description="Claude 安全启动 - 启动前检查 (macOS)")
    ap.add_argument("--force", action="store_true", help="即使有必须修项也启动")
    ap.add_argument("--no-pause", action="store_true", help="结束时不等待")
    ap.add_argument("--no-launch", action="store_true", help="只检查，不启动 Claude / 监控")
    ap.add_argument("--relearn", action="store_true", help="忘掉记住的 IP/节点/时区并重新学习")
    args = ap.parse_args()

    cfg = C.load_config()
    if args.relearn:
        C.save_learned(cfg, {"expectedIp": "", "expectedLoc": "", "expectedNode": "", "timezone": ""})

    print("==============================================")
    print("   Claude 桌面版 启动前检查 v3（macOS 通用版）")
    if args.relearn:
        print("   [重新学习] 将按当前环境重新记住出口 IP / 节点 / 时区")
    mode = "   [NoLaunch 测试模式]" if args.no_launch else ""
    print(f"   {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}{mode}")
    print("==============================================")

    # ---------- 1. Clash Verge / TUN ----------
    say_head("1. Clash Verge 与 TUN 模式")
    cores = C.get_proxy_core_pids()
    verge = C.clash_verge_running()
    utun = C.has_utun()
    route_ok = C.has_fake_ip_route()
    tun_ready = bool(cores) and (utun or route_ok)

    if not tun_ready:
        if not verge:
            if cfg.get("clashApp") and str(cfg["clashApp"]).endswith(".app"):
                say_fix(f"Clash Verge 未运行，正在启动: {cfg['clashApp']}")
                C.start_clash(cfg)
            elif cfg.get("clashApp") == "running":
                say_info("检测到 Clash 相关进程，但 TUN 未就绪，等待中…")
            else:
                say_fail("Clash Verge 未运行，也没找到安装位置（可在 preflight.json 里填写 clashApp）")
        else:
            say_info("Clash Verge 已运行，但 TUN 未就绪，等待中…")
        deadline = time.time() + 30
        while time.time() < deadline:
            time.sleep(2)
            cores = C.get_proxy_core_pids()
            utun = C.has_utun()
            route_ok = C.has_fake_ip_route()
            if cores and (utun or route_ok):
                break

    if cores:
        name, pid = cores[0]
        say_pass(f"代理内核 {name} 运行中 (PID {pid})")
    else:
        say_fail("代理内核 (mihomo) 未运行")

    if cores and (utun or route_ok):
        detail = []
        if utun:
            detail.append("utun 存在")
        if route_ok:
            detail.append("198.18 路由存在")
        say_pass("TUN 模式就绪（" + "，".join(detail) + "）")
    else:
        say_fail("30 秒内 TUN 未就绪。请在 Clash Verge 里打开「虚拟网卡模式 (TUN)」")

    # ---------- 2. 时区 ----------
    say_head("2. 系统时区")
    tz = C.get_system_iana_tz()
    if not cfg.get("timezone"):
        tr0 = C.get_trace("https://claude.ai/cdn-cgi/trace")
        iana = None
        if tr0.get("ip"):
            try:
                raw = C.curl(["-m", "12", f"https://ipinfo.io/{tr0['ip']}/json"], timeout=15)
                iana = (json.loads(raw) or {}).get("timezone")
            except Exception:  # noqa: BLE001
                iana = None
        if iana:
            C.save_learned(cfg, {"timezone": iana})
            say_fix(f"首次运行：按出口 IP 所在地设定目标时区 {iana}")
        else:
            say_note(f"无法按出口 IP 判断时区（{iana}），跳过时区检查；可在 preflight.json 里手动填写 timezone（IANA，如 America/New_York）")

    if cfg.get("timezone") and tz and tz != cfg["timezone"]:
        # macOS: do NOT sudo — print exact command
        say_fail(
            f"当前时区 {tz}，目标 {cfg['timezone']}。"
            f"请手动执行: sudo systemsetup -settimezone {cfg['timezone']}"
        )
    elif cfg.get("timezone") and tz == cfg["timezone"]:
        say_pass(f"时区: {tz}")
    elif cfg.get("timezone") and not tz:
        say_warn(f"无法读取系统时区，目标为 {cfg['timezone']}", 5)
    elif not cfg.get("timezone"):
        if tz:
            say_info(f"当前时区: {tz}（未设置目标）")

    auto = C.auto_timezone_status()
    if auto is False:
        say_pass("自动设置时区已关闭")
    elif auto is True:
        say_warn("自动设置时区已开启，时区可能被系统改回", 5)
    else:
        say_info("无法在无管理员权限下确认「自动设置时区」状态（可在 系统设置 → 通用 → 日期与时间 中关闭）")

    # ---------- 3. 节点锁定 ----------
    say_head("3. 节点锁定")
    ctl_ver = C.ctl_get(cfg, "/version")
    if not ctl_ver:
        say_warn(
            f"外部控制器 {cfg.get('controllerUrl')} 无法连接，无法确认/自动切回节点"
            "（请完全退出并重新打开 Clash Verge 使控制器生效）",
            10,
        )
    else:
        ver = ctl_ver.get("version", "?") if isinstance(ctl_ver, dict) else "?"
        say_pass(f"外部控制器已连接 (mihomo {ver})")
        groups: List[str] = []
        if cfg.get("claudeGroup"):
            groups.append(cfg["claudeGroup"])
        if cfg.get("pinMainGroup") and cfg.get("mainGroup"):
            groups.append(cfg["mainGroup"])
        if not cfg.get("expectedNode") and cfg.get("claudeGroup"):
            gi = C.ctl_get_group(cfg, cfg["claudeGroup"])
            if gi and gi.get("now"):
                C.save_learned(cfg, {"expectedNode": str(gi["now"])})
                say_fix(f"首次运行：记住 {cfg['claudeGroup']} 组当前节点 {gi['now']}，以后被切走会自动切回")
        switched = False
        for g in groups:
            info = C.ctl_get_group(cfg, g)
            if not info:
                say_note(f"Clash 里没有名为 {g} 的策略组，跳过节点锁定（建议给 Claude 建一个专用分组，见 README）")
                continue
            now = info.get("now")
            if not cfg.get("expectedNode"):
                say_info(f"{g} 组 → {now}（未设置锁定节点）")
                continue
            if now == cfg["expectedNode"]:
                say_pass(f"{g} 组 → {now}")
            else:
                say_fix(f"{g} 组当前为 {now}，正在切回 {cfg['expectedNode']}")
                if C.ctl_select_node(cfg, g, cfg["expectedNode"]):
                    after = C.ctl_get_group(cfg, g) or {}
                    if after.get("now") == cfg["expectedNode"]:
                        say_pass(f"{g} 组已切回 {after['now']}")
                        switched = True
                    else:
                        say_fail(f"{g} 组切换后仍为 {after.get('now')}")
                else:
                    say_fail(f"{g} 组切换请求失败")
        if switched:
            say_info("已切换节点，等待 3 秒后重新测 IP…")
            time.sleep(3)

    # ---------- 4. 三方 IP ----------
    say_head("4. 出口 IP 三方对比（本机实测 / 期望 / Claude 边缘）")
    local_ip = None
    ipinfo = None
    try:
        raw = C.curl(["-m", "12", "https://ipinfo.io/json"], timeout=15)
        ipinfo = json.loads(raw) if raw else None
    except Exception:  # noqa: BLE001
        ipinfo = None
    if ipinfo and ipinfo.get("ip"):
        local_ip = ipinfo["ip"]
        say_info(
            f"本机实测(ipinfo): {ipinfo.get('ip')} {ipinfo.get('country')} "
            f"{ipinfo.get('city')} / {ipinfo.get('org')}"
        )
    else:
        local_ip = C.curl(["-4", "-m", "12", "https://api.ipify.org"], timeout=15).strip()
        if local_ip:
            say_info(f"本机实测(ipify): {local_ip}")
        else:
            say_warn("本机实测 IP 查询失败（ipinfo / ipify 都无响应）", 5)

    edge: List[Dict[str, str]] = []
    for u in (
        "https://claude.ai/cdn-cgi/trace",
        "https://api.anthropic.com/cdn-cgi/trace",
    ):
        tr = C.get_trace(u)
        host = u.split("//", 1)[1].split("/", 1)[0]
        if tr.get("ip"):
            edge.append({"Host": host, "Ip": tr["ip"], "Loc": tr.get("loc", ""), "Colo": tr.get("colo", "")})
            say_info(f"Claude 边缘({host}): ip={tr['ip']} loc={tr.get('loc')} colo={tr.get('colo')}")
        elif host == "claude.ai":
            say_fail("无法访问 claude.ai/cdn-cgi/trace")
        else:
            say_info(f"{host} 不提供 trace（忽略）")

    edge_loc = edge[0]["Loc"] if edge else ""
    if edge_loc and C.BLOCKED_LOC.match(edge_loc):
        say_fail(f"Claude 看到你位于 {edge_loc}，这是 Claude 不支持的地区，请检查代理规则是否让 Claude 走了代理")

    if not cfg.get("expectedIp"):
        ips = list({*(e["Ip"] for e in edge), *([local_ip] if local_ip else {})})
        ips = [x for x in ips if x]
        uniq = list(dict.fromkeys(ips))
        if edge and edge_loc and not C.BLOCKED_LOC.match(edge_loc) and len(uniq) == 1:
            C.save_learned(cfg, {"expectedIp": uniq[0], "expectedLoc": edge_loc})
            say_fix(f"首次运行：记住当前出口 IP {uniq[0]}（{edge_loc}），以后变化会提醒")
        elif len(uniq) > 1:
            say_warn("各方看到的出口 IP 不一致，暂不记住: " + ", ".join(uniq), 10)
        elif not edge:
            say_warn("测不到 Claude 看到的出口 IP，暂不记住", 10)

    if cfg.get("expectedIp"):
        say_info(f"期望: {cfg['expectedIp']} loc={cfg.get('expectedLoc')}")

    all_ips: List[str] = []
    if cfg.get("expectedIp"):
        all_ips = [e["Ip"] for e in edge]
        if local_ip:
            all_ips.append(local_ip)
    bad = [x for x in all_ips if x != cfg.get("expectedIp")]
    bad_loc = [e for e in edge if e.get("Loc") != cfg.get("expectedLoc")]
    if all_ips and not bad and not bad_loc:
        say_pass(f"三方一致: {cfg['expectedIp']}")
    elif all_ips:
        edge_s = ",".join(f"{e['Host']}:{e['Ip']}/{e['Loc']}" for e in edge)
        say_fail(f"IP 不一致: 本机={local_ip} 边缘={edge_s} 期望={cfg.get('expectedIp')}")

    exit_ip = edge[0]["Ip"] if edge else local_ip

    # ---------- 5. IP 风险 ----------
    say_head("5. IP 风险（proxycheck.io / ip-api）")
    qip = exit_ip or cfg.get("expectedIp") or ""
    pcd = None
    if qip:
        try:
            raw = C.curl(["-m", "15", f"https://proxycheck.io/v2/{qip}?vpn=1&asn=1&risk=1"], timeout=20)
            pc = json.loads(raw) if raw else None
            if pc and str(pc.get("status", "")).lower() in ("ok", "warning"):
                pcd = pc.get(qip)
        except Exception:  # noqa: BLE001
            pcd = None
    if pcd:
        try:
            risk = int(pcd.get("risk") or 0)
        except (TypeError, ValueError):
            risk = 0
        line = (
            f"proxycheck: risk={risk} proxy={pcd.get('proxy')} type={pcd.get('type')} "
            f"/ {pcd.get('provider')} {pcd.get('organisation')}"
        )
        if risk >= int(cfg.get("failRisk") or 66):
            say_fail(f"{line}（≥ {cfg.get('failRisk')}）")
        elif risk >= int(cfg.get("warnRisk") or 33) or pcd.get("proxy") == "yes":
            say_warn(f"{line}（风险偏高）", 10)
        else:
            say_pass(line)
    else:
        say_warn("proxycheck.io 查询失败（可能被限流）", 3)

    ia = None
    if qip:
        try:
            raw = C.curl(
                ["-m", "12", f"http://ip-api.com/json/{qip}?fields=status,countryCode,isp,org,as,proxy,hosting,mobile"],
                timeout=15,
            )
            ia = json.loads(raw) if raw else None
        except Exception:  # noqa: BLE001
            ia = None
    if ia and ia.get("status") == "success":
        line = f"ip-api: {ia.get('countryCode')} {ia.get('isp')} / {ia.get('as')} proxy={ia.get('proxy')} hosting={ia.get('hosting')}"
        if ia.get("hosting") or ia.get("proxy"):
            say_warn(f"{line}（被标记为机房/代理）", 8)
        else:
            say_pass(line)
    else:
        say_note("ip-api 查询失败（忽略）")

    # ---------- 6. DNS ----------
    say_head("6. DNS (fake-ip)")
    dip = C.dns_fake_ip("api.anthropic.com")
    if dip and C.is_fake_ip(dip):
        say_pass(f"api.anthropic.com → {dip}（fake-ip，由 Clash 接管）")
    elif dip:
        say_warn(f"api.anthropic.com → {dip}，不是 fake-ip，DNS 可能未被 Clash 接管", 10)
    else:
        say_warn("api.anthropic.com 解析失败", 5)

    # ---------- 7. IPv6 ----------
    say_head("7. IPv6 泄露")
    v6 = C.ipv6_exit()
    if not v6:
        say_pass("无 IPv6 出口")
    else:
        say_fail(f"存在 IPv6 出口: {v6}，可能绕过代理暴露真实位置")

    # ---------- 8. Anthropic API ----------
    say_head("8. api.anthropic.com 连通性")
    code, body = C.curl_code("https://api.anthropic.com/v1/messages", timeout=15)
    body_one = re.sub(r"\s+", " ", body or "")
    if code in ("401", "404", "405"):
        say_pass(f"HTTP {code}（正常，未被地区封锁）")
    elif code == "403":
        say_fail("HTTP 403，疑似地区封锁: " + body_one[:120])
    elif code in ("000", ""):
        say_fail("无法连接 api.anthropic.com")
    else:
        say_warn(f"HTTP {code}（非预期状态码）", 5)

    # ---------- 9. 环境变量 ----------
    say_head("9. 环境变量")
    found = [n for n in C.ENV_BAD if C.env_var_present(n)]
    if not found:
        say_pass("没有 ANTHROPIC_BASE_URL / AUTH_TOKEN / API_KEY 等第三方中转变量")
    else:
        say_fail("发现变量: " + ", ".join(found) + "（会让 Claude Code 走第三方接口）")
        say_info("请在 shell 配置与 launchctl 中自行删除这些变量（本工具不会自动改系统环境）")

    hp = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy") or C.launchctl_getenv("HTTPS_PROXY")
    if hp:
        say_pass(f"HTTPS_PROXY={hp}")
    else:
        say_warn(f"未设置 HTTPS_PROXY（建议 {cfg.get('proxyUrl')}）", 5)

    # ---------- 10. 残留扫描 ----------
    say_head("10. 第三方接口残留扫描")
    scan: List[Path] = []
    cdir = Path.home() / ".claude"
    for f in ("settings.json", "settings.local.json", "config.json", ".credentials.json"):
        scan.append(cdir / f)
    scan.append(Path.home() / ".claude.json")
    adir = Path.home() / "Library" / "Application Support" / "Claude"
    if adir.is_dir():
        scan.extend(sorted(adir.glob("*.json")))
    residue = 0
    for f in dict.fromkeys(scan):
        if not f.is_file():
            continue
        try:
            txt = f.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        hits: List[str] = []
        keys = re.findall(
            r'"(ANTHROPIC_(?:BASE_URL|AUTH_TOKEN|API_KEY|MODEL|SMALL_FAST_MODEL)|OPENAI_API_KEY|apiKeyHelper|primaryApiKey)"\s*:',
            txt,
        )
        if keys:
            flat = [k if isinstance(k, str) else k[0] for k in keys]
            hits.append("键: " + ",".join(dict.fromkeys(flat)))
        urls = []
        for m in re.finditer(r"https?://([A-Za-z0-9.\-]+)", txt):
            host = m.group(1)
            if C.HOST_RX.search(host):
                urls.append(host)
        if urls:
            hits.append("第三方域名: " + ",".join(dict.fromkeys(urls)))
        if hits:
            residue += 1
            say_warn(f"{f} → " + "；".join(hits), 6)
    if residue == 0:
        say_pass("Claude 配置文件中没有第三方接口 / API Key 残留")

    npm_dir = cfg.get("npmGlobalDir") or ""
    if npm_dir and Path(npm_dir).exists():
        helpers = []
        try:
            for p in Path(npm_dir).iterdir():
                if p.is_file() and re.match(
                    r"^claude-(kimi|deepseek|model|models|multi)[\w\-]*\.(sh|js|mjs|cjs|bash|zsh)$",
                    p.name,
                    re.I,
                ):
                    helpers.append(p.name)
        except OSError:
            pass
        # also search parent bin
        bin_dir = Path(npm_dir)
        if bin_dir.name == "node_modules":
            bin_dir = bin_dir.parent / "bin"
        elif (bin_dir / "bin").is_dir():
            bin_dir = bin_dir / "bin"
        try:
            if bin_dir.is_dir():
                for p in bin_dir.iterdir():
                    if p.is_file() and re.match(
                        r"^claude-(kimi|deepseek|model|models|multi)",
                        p.name,
                        re.I,
                    ):
                        helpers.append(p.name)
        except OSError:
            pass
        helpers = list(dict.fromkeys(helpers))
        if helpers:
            say_warn(f"{npm_dir} 有第三方模型切换脚本: " + ", ".join(helpers) + "（未删除）", 4)
        else:
            say_pass("没有第三方模型切换脚本")

    # ---------- 11. 其他 ----------
    say_head("11. 其他")
    ui = C.get_system_lang()
    if re.match(r"^zh", ui, re.I):
        say_note(f"系统界面语言为 {ui}（一般不影响，可忽略）")
    else:
        say_pass(f"系统界面语言 {ui}")

    app = cfg.get("claudeApp") or C.find_claude_app()
    if app:
        say_pass("Claude 桌面版已安装")
    else:
        say_warn("没找到 Claude 桌面版（可在 preflight.json 里填写 claudeApp，如 /Applications/Claude.app）", 5)

    if shutil.which("claude"):
        say_pass("Claude Code CLI 已安装")
    else:
        say_note("未找到 claude CLI（仅影响命令行版）")

    # ---------- 评分 ----------
    fails = [i for i in ITEMS.items if i["Level"] == "FAIL"]
    warns = [i for i in ITEMS.items if i["Level"] == "WARN"]
    notes = [i for i in ITEMS.items if i["Level"] == "NOTE"]
    lost = sum(i["Weight"] for i in ITEMS.items)
    score = max(0, 100 - int(lost))
    print()
    print("==============================================")
    print(f"  一致性评分: {score} / 100")
    if fails:
        print(f"  【必须修】{len(fails)} 项")
        for i in fails:
            print(f"    - {i['Text']}")
    if warns:
        print(f"  【建议修】{len(warns)} 项")
        for i in warns:
            print(f"    - {i['Text']}")
    if notes:
        print(f"  【不用管】{len(notes)} 项")
        for i in notes:
            print(f"    - {i['Text']}")
    if not (fails or warns or notes):
        print("  全部通过")
    print("==============================================")
    result = "FAIL" if fails else ("WARN" if warns else "PASS")

    # ---------- 启动 ----------
    launched = "no"
    if args.no_launch:
        print("[NoLaunch] 测试模式：不启动 Claude，不启动后台监控。")
        launched = "nolaunch"
    elif not fails or args.force:
        if fails:
            print(f"有 {len(fails)} 项必须修，但使用了 --force，仍然启动。")
        if C.claude_running():
            print("Claude 已在运行，切换到前台…")
            launched = "front"
        else:
            print("正在启动 Claude…")
            launched = "yes"
        if not C.start_claude_app(cfg):
            print("找不到 Claude 桌面版，请先安装，或在 preflight.json 里填写 claudeApp")
            launched = "notfound"
        mon = C.ROOT / "claude_monitor.py"
        if mon.is_file():
            # detach
            logf = open(C.ROOT / "monitor.spawn.log", "a", encoding="utf-8")  # noqa: SIM115
            subprocess_detach(mon, logf)
            print(f"已启动后台监控（每 {cfg.get('monitorIntervalMin', 5)} 分钟检查一次）")
    else:
        print(f"有 {len(fails)} 项必须修，未启动 Claude。修好后重新运行；确需强行启动可加 --force。")

    log_line = (
        f"{result} | score={score} | ip={exit_ip} | tz={tz} | fail={len(fails)} | "
        f"warn={len(warns)} | launch={launched}"
    )
    if args.force:
        log_line += " | force"
    if fails:
        log_line += " | " + "; ".join(i["Text"] for i in fails)
    C.write_log(log_line)

    if not args.no_pause:
        if fails and not args.force:
            print()
            print("按回车键退出")
            try:
                input()
            except EOFError:
                pass
        else:
            print("5 秒后自动关闭…")
            time.sleep(5)

    return 1 if fails and not args.force else 0


def subprocess_detach(script: Path, logf) -> None:
    import subprocess

    subprocess.Popen(
        [sys.executable, str(script)],
        stdout=logf,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        cwd=str(C.ROOT),
    )


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\n已取消")
        raise SystemExit(130)
