#!/bin/sh
set -e
cd "$(dirname "$0")"
GODOT="${GODOT:-/Users/boyu/Desktop/Godot.app/Contents/MacOS/Godot}"
echo "== 语言/VM 测试 =="
"$GODOT" --headless --path . --script res://tests/lang_test.gd
echo "== 世界测试 =="
"$GODOT" --headless --path . --script res://tests/world_test.gd
echo "== 预设单位测试 =="
"$GODOT" --headless --path . --script res://tests/flyer_test.gd
echo "== 放置单位测试 =="
"$GODOT" --headless --path . --script res://tests/place_test.gd
