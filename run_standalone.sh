#!/bin/zsh
# 独立运行游戏窗口（不打开 / 不依赖编辑器播放）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
GODOT="${GODOT:-/Users/boyu/Desktop/Godot.app/Contents/MacOS/Godot}"
exec "$GODOT" --path "$ROOT" --rendering-driver vulkan "$@"
