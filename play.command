#!/bin/sh
# 双击此文件启动游戏（macOS）。游戏退出后会自动关掉这个终端窗口。
cd "$(dirname "$0")" || exit 1
GODOT="${GODOT:-/Users/boyu/Desktop/Godot.app/Contents/MacOS/Godot}"
"$GODOT" --path "$(pwd)" "$@"
STATUS=$?
# 退出后关掉这个 Terminal 窗口（只关名字里带 play.command 的窗口）
osascript -e 'tell application "Terminal" to close (every window whose name contains "play.command")' >/dev/null 2>&1
exit $STATUS
