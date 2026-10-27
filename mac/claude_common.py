# -*- coding: utf-8 -*-
"""Claude 安全启动（macOS 通用版）- 公共函数。"""
from __future__ import annotations

import json
import os
import re
import shutil
import socket
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

ROOT = Path(__file__).resolve().parent
CFG_PATH = ROOT / "preflight.json"
LOG_PATH = ROOT / "preflight.log"
VERGE_DIR = (
    Path.home()
    / "Library"
    / "Application Support"
    / "io.github.clash-verge-rev.clash-verge-rev"
)
BLOCKED_LOC = re.compile(r"^(CN|HK|MO|RU|KP|IR|CU|SY|BY)$")
HOST_RX = re.compile(
    r"kimi|moonshot|deepseek|openrouter|siliconflow|bigmodel|zhipu|dashscope|"
    r"aliyuncs|volces|minimax|anyrouter|api2d|aicodemirror|packycode|"
    r"claude-relay|gptsapi|ohmygpt|xiaomimimo",
    re.I,
)
ENV_BAD = (
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_MODEL",
    "ANTHROPIC_SMALL_FAST_MODEL",
)


def _run(cmd: List[str], timeout: float = 15, env: Optional[dict] = None) -> Tuple[int, str, str]:
    try:
        p = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
            check=False,
        )
        return p.returncode, p.stdout or "", p.stderr or ""
    except FileNotFoundError:
        return 127, "", "not found"
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"
    except Exception as e:  # noqa: BLE001
        return 1, "", str(e)


def read_verge_runtime() -> Dict[str, str]:
    """Tiny line parser for clash-verge.yaml (no PyYAML)."""
    h: Dict[str, str] = {}
    rt = VERGE_DIR / "clash-verge.yaml"
    if not rt.is_file():
        return h
    try:
        text = rt.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return h
    for line in text.splitlines():
        m = re.match(r"^(secret|external-controller|mixed-port|port):\s*(.*)$", line.strip())
        if m:
            h[m.group(1)] = m.group(2).strip().strip("'\"")
    return h


def find_claude_app() -> str:
    for p in (
        Path("/Applications/Claude.app"),
        Path.home() / "Applications" / "Claude.app",
    ):
        if p.is_dir():
            return str(p)
    return ""


def find_clash_app() -> str:
    for name in ("Clash Verge.app", "Clash Verge Rev.app", "ClashX Pro.app"):
        for base in (Path("/Applications"), Path.home() / "Applications"):
            p = base / name
            if p.is_dir():
                return str(p)
    # running process path
    code, out, _ = _run(["pgrep", "-lf", "clash-verge"], timeout=5)
    if code == 0 and out.strip():
        return "running"
    return ""


def find_npm_global_dir() -> str:
    code, out, _ = _run(["npm", "root", "-g"], timeout=10)
    if code == 0 and out.strip():
        return out.strip()
    # common fallbacks
    for p in (
        Path.home() / ".npm-global" / "lib" / "node_modules",
        Path("/usr/local/lib/node_modules"),
        Path.home() / ".nvm",
    ):
        if p.exists():
            return str(p)
    which = shutil.which("claude")
    if which:
        return str(Path(which).parent)
    return ""


DEFAULTS: Dict[str, Any] = {
    "expectedIp": "",
    "expectedLoc": "",
    "expectedNode": "",
    "claudeGroup": "Claude",
    "mainGroup": "",
    "pinMainGroup": False,
    "timezone": "",  # IANA, e.g. America/New_York
    "claudeApp": "",
    "clashApp": "",
    "proxyUrl": "",
    "controllerUrl": "",
    "controllerSecret": "",
    "warnRisk": 33,
    "failRisk": 66,
    "monitorIntervalMin": 5,
    "monitorKillOnChange": False,
    "npmGlobalDir": "",
}


def load_config() -> Dict[str, Any]:
    cfg: Dict[str, Any] = {}
    if CFG_PATH.is_file():
        try:
            cfg = json.loads(CFG_PATH.read_text(encoding="utf-8"))
            if not isinstance(cfg, dict):
                cfg = {}
        except (OSError, json.JSONDecodeError):
            cfg = {}
    changed = False
    for k, v in DEFAULTS.items():
        if k not in cfg:
            cfg[k] = v
            changed = True
    if changed:
        try:
            CFG_PATH.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        except OSError:
            pass

    rt = read_verge_runtime()
    if rt.get("secret"):
        cfg["controllerSecret"] = rt["secret"]
    if rt.get("external-controller"):
        a = rt["external-controller"]
        if a.startswith(":"):
            a = "127.0.0.1" + a
        a = a.replace("0.0.0.0", "127.0.0.1")
        if not a.startswith("http"):
            a = "http://" + a
        cfg["controllerUrl"] = a
    if not cfg.get("controllerUrl"):
        cfg["controllerUrl"] = "http://127.0.0.1:9097"
    if not cfg.get("proxyUrl"):
        port = rt.get("mixed-port") or rt.get("port") or "7897"
        cfg["proxyUrl"] = f"http://127.0.0.1:{port}"
    if not cfg.get("claudeApp"):
        cfg["claudeApp"] = find_claude_app()
    if not cfg.get("clashApp"):
        cfg["clashApp"] = find_clash_app()
    if not cfg.get("npmGlobalDir"):
        cfg["npmGlobalDir"] = find_npm_global_dir()
    return cfg


def save_learned(cfg: Dict[str, Any], vals: Dict[str, Any]) -> None:
    j: Dict[str, Any] = {}
    if CFG_PATH.is_file():
        try:
            j = json.loads(CFG_PATH.read_text(encoding="utf-8"))
            if not isinstance(j, dict):
                j = {}
        except (OSError, json.JSONDecodeError):
            j = {}
    for k, v in vals.items():
        j[k] = v
        cfg[k] = v
    try:
        CFG_PATH.write_text(json.dumps(j, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    except OSError:
        pass


def write_log(line: str) -> None:
    from datetime import datetime, timezone

    try:
        # local time with offset
        now = datetime.now().astimezone()
        stamp = now.strftime("%Y-%m-%d %H:%M:%S %z")
        with LOG_PATH.open("a", encoding="utf-8") as f:
            f.write(f"{stamp} | {line}\n")
    except OSError:
        pass


def curl(args: List[str], timeout: float = 20) -> str:
    """System curl, ignoring HTTPS_PROXY (real TUN path)."""
    env = os.environ.copy()
    for k in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "all_proxy"):
        env.pop(k, None)
    cmd = ["curl", "--noproxy", "*", "-s"] + args
    code, out, _ = _run(cmd, timeout=timeout, env=env)
    return out if code == 0 or out else ""


def curl_code(url: str, timeout: float = 20) -> Tuple[str, str]:
    """Return (http_code, body)."""
    env = os.environ.copy()
    for k in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "all_proxy"):
        env.pop(k, None)
    import tempfile

    fd, tmp = tempfile.mkstemp()
    os.close(fd)
    try:
        cmd = [
            "curl", "--noproxy", "*", "-s", "-m", str(int(timeout)),
            "-o", tmp, "-w", "%{http_code}", url,
        ]
        code, out, _ = _run(cmd, timeout=timeout + 5, env=env)
        body = ""
        try:
            body = Path(tmp).read_text(encoding="utf-8", errors="replace")
        except OSError:
            pass
        http = (out or "000").strip() or "000"
        return http, body
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def get_trace(url: str) -> Dict[str, str]:
    t = curl(["-m", "12", url], timeout=15)
    h: Dict[str, str] = {}
    for line in t.splitlines():
        line = line.strip()
        if "=" in line:
            k, _, v = line.partition("=")
            if re.match(r"^\w+$", k):
                h[k] = v
    return h


def get_proxy_core_pids() -> List[Tuple[str, int]]:
    """Return list of (name, pid) for verge-mihomo / mihomo / clash-meta."""
    found: List[Tuple[str, int]] = []
    for pat in ("verge-mihomo", "mihomo", "clash-meta"):
        code, out, _ = _run(["pgrep", "-fl", pat], timeout=5)
        if code != 0:
            continue
        for line in out.splitlines():
            parts = line.strip().split(None, 1)
            if not parts:
                continue
            try:
                pid = int(parts[0])
            except ValueError:
                continue
            name = pat
            if len(parts) > 1:
                # take basename of first path-like token
                for tok in parts[1].split():
                    base = Path(tok).name
                    if pat in base:
                        name = base
                        break
            found.append((name, pid))
    # dedupe by pid
    seen = set()
    uniq = []
    for n, p in found:
        if p not in seen:
            seen.add(p)
            uniq.append((n, p))
    return uniq


def clash_verge_running() -> bool:
    code, _, _ = _run(["pgrep", "-f", "Clash Verge|clash-verge"], timeout=5)
    return code == 0


def has_utun() -> bool:
    """Best-effort Clash/mihomo TUN: a utun tied to fake-ip 198.18.0.0/15, not any system utun."""
    # Prefer route evidence: 198.18.0.1 (or 198.19.0.1) egresses via utunN
    for dest in ("198.18.0.1", "198.19.0.1"):
        code, out, _ = _run(["route", "-n", "get", dest], timeout=8)
        if code == 0 and out and re.search(r"interface:\s*utun\d+", out, re.I):
            return True
    # ifconfig: only count utun that has an inet in 198.18.0.0/15
    code, out, _ = _run(["ifconfig"], timeout=8)
    if code == 0 and out:
        cur = False
        for line in out.splitlines():
            if re.match(r"^utun\d+:", line):
                cur = True
                continue
            # next interface header ends the block (name at column 0)
            if cur and re.match(r"^[A-Za-z0-9].*:", line):
                cur = False
            if cur and re.search(r"\binet\s+198\.(18|19)\.", line):
                return True
    # Linux fallback for testing: tun/utun mentioned on a 198.18/19 route
    code2, out2, _ = _run(["ip", "route"], timeout=5)
    if code2 == 0 and out2 and ("198.18" in out2 or "198.19" in out2):
        if re.search(r"\b(u?tun)\d*\b", out2, re.I):
            return True
    return False

def has_fake_ip_route() -> bool:
    """Best-effort: 198.18.0.0/15 style routes used by Clash fake-ip / TUN."""
    for cmd in (
        ["netstat", "-rn"],
        ["route", "-n", "get", "198.18.0.1"],
        ["ip", "route"],
    ):
        code, out, _ = _run(cmd, timeout=8)
        if code == 0 and ("198.18" in out or "198.19" in out):
            return True
    return False


def get_system_iana_tz() -> str:
    """Read IANA timezone from /etc/localtime symlink (macOS / Linux)."""
    try:
        link = os.readlink("/etc/localtime")
        # e.g. /var/db/timezone/zoneinfo/America/New_York or ../usr/share/zoneinfo/...
        for marker in ("zoneinfo/", "Zoneinfo/"):
            if marker in link:
                return link.split(marker, 1)[1]
        if "/" in link and not link.startswith("/"):
            return link
    except OSError:
        pass
    # TZ env
    if os.environ.get("TZ"):
        return os.environ["TZ"]
    # timedatectl (Linux test)
    code, out, _ = _run(["timedatectl", "show", "-p", "Timezone", "--value"], timeout=5)
    if code == 0 and out.strip():
        return out.strip()
    return ""


def auto_timezone_status() -> Optional[bool]:
    """True if auto timezone ON, False if OFF, None if unknown (no sudo)."""
    # macOS plist (often readable without sudo)
    for cmd in (
        ["defaults", "read", "/Library/Preferences/com.apple.timezone.auto", "Active"],
        ["defaults", "read", "com.apple.timezone.auto", "Active"],
    ):
        code, out, _ = _run(cmd, timeout=5)
        if code == 0:
            v = out.strip().lower()
            if v in ("1", "true", "yes"):
                return True
            if v in ("0", "false", "no"):
                return False
    return None


def dns_fake_ip(host: str = "api.anthropic.com") -> Optional[str]:
    try:
        infos = socket.getaddrinfo(host, 443, socket.AF_INET, socket.SOCK_STREAM)
        if not infos:
            return None
        ip = infos[0][4][0]
        return ip
    except OSError:
        return None


def is_fake_ip(ip: str) -> bool:
    # 198.18.0.0/15
    try:
        parts = [int(x) for x in ip.split(".")]
        if len(parts) != 4:
            return False
        return parts[0] == 198 and parts[1] in (18, 19)
    except ValueError:
        return False


def ipv6_exit() -> Optional[str]:
    env = os.environ.copy()
    for k in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "all_proxy"):
        env.pop(k, None)
    code, out, _ = _run(
        ["curl", "--noproxy", "*", "-6", "-s", "-m", "6", "https://api64.ipify.org"],
        timeout=10,
        env=env,
    )
    out = (out or "").strip()
    if code != 0 or not out or ":" not in out:
        return None
    return out


def launchctl_getenv(name: str) -> str:
    code, out, _ = _run(["launchctl", "getenv", name], timeout=5)
    if code == 0:
        return (out or "").strip()
    return ""


def env_var_present(name: str) -> bool:
    if os.environ.get(name):
        return True
    if launchctl_getenv(name):
        return True
    return False


def get_system_lang() -> str:
    code, out, _ = _run(["defaults", "read", "-g", "AppleLanguages"], timeout=5)
    if code == 0 and out.strip():
        # (en-US, "zh-Hans-CN", ...)
        m = re.search(r'"?([a-z]{2}[-_][A-Za-z0-9]+)"?', out)
        if m:
            return m.group(1).replace("_", "-")
        return out.strip()[:40]
    lang = os.environ.get("LANG", "")
    return lang.split(".")[0] if lang else "unknown"


def claude_running() -> bool:
    # macOS: Claude.app
    code, out, _ = _run(["pgrep", "-fl", "Claude"], timeout=5)
    if code != 0:
        return False
    for line in out.splitlines():
        low = line.lower()
        if "claude.app" in low or "/applications/claude" in low:
            return True
        # avoid matching our own scripts
        if "claude_" in low or "claude-" in low or "claude_preflight" in low:
            continue
        if re.search(r"\bClaude\b", line) and "python" not in low:
            # heuristic
            if "Helper" in line or "Claude" in line:
                return True
    # simpler: pgrep -x Claude or mdfind
    code2, _, _ = _run(["pgrep", "-x", "Claude"], timeout=5)
    return code2 == 0


def start_claude_app(cfg: Dict[str, Any]) -> bool:
    app = cfg.get("claudeApp") or find_claude_app()
    if app and app.endswith(".app"):
        code, _, _ = _run(["open", "-a", app], timeout=15)
        return code == 0
    # name fallback
    code, _, _ = _run(["open", "-a", "Claude"], timeout=15)
    return code == 0


def start_clash(cfg: Dict[str, Any]) -> bool:
    app = cfg.get("clashApp") or ""
    if app and app.endswith(".app"):
        code, _, _ = _run(["open", "-a", app], timeout=15)
        return code == 0
    for name in ("Clash Verge", "Clash Verge Rev"):
        code, _, _ = _run(["open", "-a", name], timeout=10)
        if code == 0:
            return True
    return False


# ---- mihomo external controller ----

def ctl_raw(cfg: Dict[str, Any], method: str, path: str, body: Optional[str] = None) -> Tuple[bool, str]:
    base = (cfg.get("controllerUrl") or "http://127.0.0.1:9097").rstrip("/")
    url = base + path
    data = body.encode("utf-8") if body else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json; charset=utf-8")
    secret = cfg.get("controllerSecret") or ""
    if secret:
        req.add_header("Authorization", "Bearer " + secret)
    # force no proxy
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=3) as resp:
            text = resp.read().decode("utf-8", errors="replace")
            return True, text
    except Exception:  # noqa: BLE001
        return False, ""


def ctl_get(cfg: Dict[str, Any], path: str) -> Optional[Any]:
    ok, text = ctl_raw(cfg, "GET", path)
    if not ok or not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def ctl_get_group(cfg: Dict[str, Any], group: str) -> Optional[Any]:
    if not group:
        return None
    return ctl_get(cfg, "/proxies/" + urllib.parse.quote(group, safe=""))


def ctl_select_node(cfg: Dict[str, Any], group: str, node: str) -> bool:
    if not group or not node:
        return False
    body = json.dumps({"name": node}, ensure_ascii=False)
    ok, _ = ctl_raw(cfg, "PUT", "/proxies/" + urllib.parse.quote(group, safe=""), body)
    return ok


def notify(title: str, text: str) -> None:
    # escape for AppleScript
    def esc(s: str) -> str:
        return s.replace("\\", "\\\\").replace('"', '\\"')

    script = f'display notification "{esc(text)}" with title "{esc(title)}"'
    _run(["osascript", "-e", script], timeout=10)


def kill_claude() -> int:
    """Only used when monitorKillOnChange is true."""
    n = 0
    code, out, _ = _run(["pgrep", "-x", "Claude"], timeout=5)
    if code == 0:
        for line in out.splitlines():
            try:
                pid = int(line.strip())
                os.kill(pid, 15)
                n += 1
            except (ValueError, OSError):
                pass
    return n
