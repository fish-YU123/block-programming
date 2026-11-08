#!/bin/sh
# 一键跑全部 headless 测试（macOS，Godot 路径按需修改）
set -e
GODOT="${GODOT:-/Users/boyu/Desktop/Godot.app/Contents/MacOS/Godot}"
cd "$(dirname "$0")"
echo "== 语言 VM 单元测试 =="
"$GODOT" --headless --path . --script res://tests/lang_test.gd 2>&1 | grep -v "user://logs\|rotate_file\|copy (core\|Unicode parsing"
echo "== 单位驱动集成测试 =="
"$GODOT" --headless --path . --script res://tests/integration_test.gd 2>&1 | grep -v "user://logs\|rotate_file\|copy (core\|Unicode parsing"
echo "== 默认示例代码可编译 =="
"$GODOT" --headless --path . --script res://tests/default_source_test.gd 2>&1 | grep -v "user://logs\|rotate_file\|copy (core\|Unicode parsing"
