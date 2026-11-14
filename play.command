#!/bin/sh
# macOS 双击启动（Windows 用 play.bat，Linux 用 play.sh）。
# 游戏退出后自动关掉这个终端窗口；引擎找不到时停住，方便看提示。
cd "$(dirname "$0")" || exit 1

if ! . ./tools/godot_env.sh; then
	printf '\n按回车关闭窗口…'
	read -r _
	exit 1
fi

"$GODOT" --path . "$@"
STATUS=$?

# 只在 macOS 的 Terminal 里有意义；其它情况静默跳过
if command -v osascript >/dev/null 2>&1; then
	osascript -e 'tell application "Terminal" to close (every window whose name contains "play.command")' >/dev/null 2>&1
fi
exit $STATUS
