#!/bin/sh
# 双击此文件即可启动游戏（macOS）
cd "$(dirname "$0")" || exit 1
GODOT="${GODOT:-/Users/boyu/Desktop/Godot.app/Contents/MacOS/Godot}"
exec "$GODOT" --path "$(pwd)"
