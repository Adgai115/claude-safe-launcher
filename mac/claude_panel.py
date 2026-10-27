#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Claude 安全启动 · 主题面板（macOS 本地网页界面）
协议与 Windows claude-panel.ps1 对齐，共用 claude-panel.html。
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, List, Optional

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
import claude_common as C  # noqa: E402

PRE = ROOT / "claude_preflight.py"
HTML_PATH = ROOT / "claude-panel.html"
STATE_FILE = ROOT / "panel.json"
LOG_FILE = ROOT / "preflight.log"
SRV_LOG = ROOT / "panel-server.log"
PORT = 47832
URL = f"http://127.0.0.1:{PORT}/"


def slog(msg: str) -> None:
    try:
        with SRV_LOG.open("a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S") + " " + msg + "\n")
    except OSError:
        pass


def get_theme() -> str:
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8")).get("theme") or "anime"
    except Exception:  # noqa: BLE001
        return "anime"


def set_theme(t: str) -> None:
    try:
        STATE_FILE.write_text(json.dumps({"theme": t}, ensure_ascii=False), encoding="utf-8")
    except OSError:
        pass


def port_in_use(port: int) -> bool:
    import socket

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.settimeout(0.5)
        s.connect(("127.0.0.1", port))
        s.close()
        return True
    except OSError:
        return False


def open_browser(url: str) -> None:
    chrome_candidates = [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
        str(Path.home() / "Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
    ]
    for chrome in chrome_candidates:
        if Path(chrome).is_file():
            ud = ROOT / "panel-chrome"
            ud.mkdir(exist_ok=True)
            subprocess.Popen(
                [
                    chrome,
                    f"--app={url}",
                    "--window-size=1040,880",
                    f"--user-data-dir={ud}",
                    "--no-first-run",
                    "--no-default-browser-check",
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            return
    # default browser
    subprocess.Popen(
        ["open", url],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


class Job:
    def __init__(self) -> None:
        self.proc: Optional[subprocess.Popen] = None
        self.tmp: Optional[Path] = None
        self.lock = threading.Lock()


JOB = Job()
LAST = time.time()
QUIT = False


def start_preflight(launch: bool, relearn: bool) -> None:
    with JOB.lock:
        if JOB.proc and JOB.proc.poll() is None:
            return
        if JOB.tmp and JOB.tmp.is_file():
            try:
                JOB.tmp.unlink()
            except OSError:
                pass
        fd, tmp = tempfile.mkstemp(prefix="csl-panel-", suffix=".txt")
        os.close(fd)
        JOB.tmp = Path(tmp)
        flags = ["--no-pause"]
        if not launch:
            flags.append("--no-launch")
        if relearn:
            flags.append("--relearn")
        # Line-buffered output into temp file
        env = os.environ.copy()
        env["PYTHONUNBUFFERED"] = "1"
        # Append lines as they come
        out_f = open(JOB.tmp, "w", encoding="utf-8", buffering=1)  # noqa: SIM115
        JOB.proc = subprocess.Popen(
            [sys.executable, "-u", str(PRE)] + flags,
            stdout=out_f,
            stderr=subprocess.STDOUT,
            cwd=str(ROOT),
            env=env,
            start_new_session=True,
        )
        # keep file handle alive via process; close in wait thread
        def _wait() -> None:
            try:
                JOB.proc.wait()
            finally:
                try:
                    out_f.close()
                except Exception:  # noqa: BLE001
                    pass

        threading.Thread(target=_wait, daemon=True).start()


def read_poll(from_idx: int) -> Dict[str, Any]:
    done = (JOB.proc is None) or (JOB.proc.poll() is not None)
    lines: List[str] = []
    next_idx = from_idx
    if JOB.tmp and JOB.tmp.is_file():
        all_text = None
        for _ in range(5):
            try:
                # share read while writer may append
                with JOB.tmp.open("r", encoding="utf-8", errors="replace") as f:
                    all_text = f.read()
                break
            except OSError:
                time.sleep(0.04)
        if all_text is None:
            all_text = ""
            done = False
        parts = all_text.splitlines()
        # if not done, last line may be incomplete
        if done:
            complete = parts
        elif len(parts) > 1:
            complete = parts[:-1]
        else:
            complete = []
        if len(complete) > from_idx:
            lines = complete[from_idx:]
        next_idx = max(from_idx, len(complete))
    return {"lines": lines, "next": next_idx, "done": bool(done)}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: Any) -> None:  # noqa: A003
        slog(fmt % args)

    def _send(self, body: bytes, content_type: str = "application/json; charset=utf-8", code: int = 200) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, obj: Any, code: int = 200) -> None:
        self._send(json.dumps(obj, ensure_ascii=False).encode("utf-8"), code=code)

    def do_GET(self) -> None:  # noqa: N802
        global LAST, QUIT
        LAST = time.time()
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        qs = urllib.parse.parse_qs(parsed.query)

        try:
            if path == "/":
                html = HTML_PATH.read_text(encoding="utf-8").replace("__THEME__", get_theme())
                self._send(html.encode("utf-8"), "text/html; charset=utf-8")
            elif path == "/api/poll":
                from_s = (qs.get("from") or ["0"])[0]
                try:
                    from_idx = int(from_s)
                except ValueError:
                    from_idx = 0
                self._json(read_poll(from_idx))
            elif path == "/api/claude":
                self._json({"running": C.claude_running()})
            elif path == "/api/theme":
                t = (qs.get("t") or [""])[0]
                if t and t.isalpha() and t.islower():
                    set_theme(t)
                self._json({"ok": True})
            elif path == "/api/ping":
                self._json({"ok": True})
            elif path == "/api/run":
                # also allow GET for simplicity
                launch = (qs.get("launch") or ["0"])[0] == "1"
                relearn = (qs.get("relearn") or ["0"])[0] == "1"
                start_preflight(launch, relearn)
                self._json({"ok": True})
            elif path == "/api/log":
                if LOG_FILE.is_file():
                    subprocess.Popen(["open", "-t", str(LOG_FILE)], start_new_session=True)
                self._json({"ok": True})
            elif path == "/api/quit":
                self._json({"ok": True})
                QUIT = True
            else:
                self._json({}, code=404)
        except Exception as e:  # noqa: BLE001
            slog(f"request error {self.path}: {e}")
            try:
                self._json({}, code=500)
            except Exception:  # noqa: BLE001
                pass

    def do_POST(self) -> None:  # noqa: N802
        global LAST
        LAST = time.time()
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        if path == "/api/browser":
            try:
                if body and length < 200000:
                    data = json.loads(body.decode("utf-8"))
                    if not isinstance(data, dict):
                        raise ValueError("not object")
                    if "ts" not in data:
                        data["ts"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
                    out = ROOT / "browser-check.json"
                    out.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
                    slog("browser-check.json written")
                self._json({"ok": True})
            except Exception as e:  # noqa: BLE001
                slog(f"browser json error: {e}")
                self._json({"ok": False}, code=400)
            return
        # other POSTs: ignore body, behave like GET
        self.do_GET()


def main() -> int:
    global LAST, QUIT
    if not HTML_PATH.is_file():
        print(f"缺少 {HTML_PATH}", file=sys.stderr)
        return 1
    if not PRE.is_file():
        print(f"缺少 {PRE}", file=sys.stderr)
        return 1

    if port_in_use(PORT):
        if not os.environ.get("CSL_PANEL_NO_OPEN"):
            open_browser(URL)
        print(f"面板已在运行，已重新打开 {URL}")
        return 0

    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.daemon_threads = True
    slog(f"server start pid {os.getpid()}")
    if not os.environ.get("CSL_PANEL_NO_OPEN"):
        open_browser(URL)
    print(f"面板已启动: {URL}")

    try:
        while not QUIT:
            server.handle_request()
            running = JOB.proc is not None and JOB.proc.poll() is None
            if (time.time() - LAST) > 45 and not running:
                # also check if anyone is still connected — idle exit like Windows
                break
            # handle_request blocks until one request; reset timeout via socket
            server.timeout = 1.0
    except KeyboardInterrupt:
        pass
    finally:
        slog("server exit (idle or quit)")
        try:
            server.server_close()
        except Exception:  # noqa: BLE001
            pass
    return 0


if __name__ == "__main__":
    # Use timeout-aware loop: ThreadingHTTPServer.handle_request with timeout
    # Re-implement main with better idle loop
    def run() -> int:
        global LAST, QUIT
        if not HTML_PATH.is_file() or not PRE.is_file():
            print("缺少 claude-panel.html 或 claude_preflight.py", file=sys.stderr)
            return 1
        if port_in_use(PORT):
            if not os.environ.get("CSL_PANEL_NO_OPEN"):
                open_browser(URL)
            print(f"面板已在运行，已重新打开 {URL}")
            return 0
        server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
        server.timeout = 1.0
        server.daemon_threads = True
        slog(f"server start pid {os.getpid()}")
        if not os.environ.get("CSL_PANEL_NO_OPEN"):
            open_browser(URL)
        print(f"面板已启动: {URL}  （关闭页面约 45 秒后自动退出）")
        try:
            while not QUIT:
                server.handle_request()
                running = JOB.proc is not None and JOB.proc.poll() is None
                if (time.time() - LAST) > 45 and not running:
                    break
        except KeyboardInterrupt:
            pass
        finally:
            slog("server exit (idle or quit)")
            try:
                server.server_close()
            except Exception:  # noqa: BLE001
                pass
            if JOB.proc and JOB.proc.poll() is None:
                try:
                    JOB.proc.terminate()
                except Exception:  # noqa: BLE001
                    pass
        return 0

    raise SystemExit(run())
