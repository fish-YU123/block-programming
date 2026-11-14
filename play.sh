#!/bin/sh
# macOS / Linux 启动器（Linux 与 macOS 都用这个；Windows 用 play.bat）。
# 参数原样传给 Godot，例如：
#     ./play.sh -- --python              # 本地 Python 模式
#     ./play.sh -- --world-seed=12345    # 复现某张地图
set -e
cd "$(dirname "$0")" || exit 1
. ./tools/godot_env.sh || exit 1
exec "$GODOT" --path . "$@"
