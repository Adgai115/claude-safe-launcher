#!/bin/bash
# Claude Safe Launcher (macOS) 安装：给脚本加执行权限，并在桌面创建「Claude 安全启动」
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

echo "=============================================="
echo "  Claude 安全启动 · macOS 安装"
echo "=============================================="

if ! command -v python3 >/dev/null 2>&1; then
  echo "未找到 python3。请先安装 Xcode 命令行工具："
  echo "  xcode-select --install"
  echo "安装完成后重新双击本文件。"
  read -r -p "按回车键退出…" _
  exit 1
fi

chmod +x "$DIR/claude_preflight.py" "$DIR/claude_monitor.py" "$DIR/claude_panel.py" "$DIR/install.command" 2>/dev/null || true

DESKTOP="${HOME}/Desktop"
APP_NAME="Claude 安全启动"
APP_PATH="${DESKTOP}/${APP_NAME}.app"
CMD_FALLBACK="${DESKTOP}/${APP_NAME}.command"

# 清理旧版「Claude 检查面板」
for old in "${DESKTOP}/Claude 检查面板.app" "${DESKTOP}/Claude 检查面板.command"; do
  if [ -e "$old" ]; then rm -rf "$old"; fi
done

PY="$(command -v python3)"
PANEL="$DIR/claude_panel.py"

# 路径里的反斜杠与引号做最小转义，供嵌入 shell / AppleScript
esc_sh() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }
DIR_Q="'$(esc_sh "$DIR")'"
PY_Q="'$(esc_sh "$PY")'"
PANEL_Q="'$(esc_sh "$PANEL")'"
SHELL_LINE="cd ${DIR_Q} && ${PY_Q} ${PANEL_Q} > /dev/null 2>&1 &"

write_command_fallback() {
  cat > "$CMD_FALLBACK" <<CEOF
#!/bin/bash
cd "$DIR"
exec "$PY" "$PANEL"
CEOF
  chmod +x "$CMD_FALLBACK"
  echo "已创建桌面快捷方式: ${APP_NAME}.command"
}

if command -v osacompile >/dev/null 2>&1; then
  TMP_SCRIPT="$(mktemp "${TMPDIR:-/tmp}/cslXXXXXX.applescript")"
  # AppleScript 字符串转义：反斜杠与双引号
  AS_LINE=$(printf '%s' "$SHELL_LINE" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf 'do shell script "%s"\n' "$AS_LINE" > "$TMP_SCRIPT"
  rm -rf "$APP_PATH"
  if osacompile -o "$APP_PATH" "$TMP_SCRIPT" 2>/dev/null; then
    echo "已创建桌面应用: ${APP_NAME}.app"
    rm -f "$TMP_SCRIPT"
    [ -f "$CMD_FALLBACK" ] && rm -f "$CMD_FALLBACK"
  else
    rm -f "$TMP_SCRIPT"
    echo "osacompile 失败，改用 .command 快捷方式"
    write_command_fallback
  fi
else
  write_command_fallback
fi

echo ""
echo "安装完成。双击桌面上的「Claude 安全启动」打开检查面板："
echo "可以「只检查」，也可以「检查并启动」。"
echo ""
echo "若系统拦截未签名应用：右键 → 打开，或在「隐私与安全性」中允许。"
read -r -p "按回车键关闭…" _
