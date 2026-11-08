#!/bin/sh
set -e
cd "$(dirname "$0")"
GODOT="${GODOT:-/Users/boyu/Desktop/Godot.app/Contents/MacOS/Godot}"
echo "== 语言/VM 测试 =="
"$GODOT" --headless --path . --script res://tests/lang_test.gd
echo "== 单位/经济/面板 =="
"$GODOT" --headless --path . --script res://tests/flyer_test.gd
"$GODOT" --headless --path . --script res://tests/economy_test.gd
"$GODOT" --headless --path . --script res://tests/editor_test.gd
"$GODOT" --headless --path . --script res://tests/place_test.gd
echo "== 世界测试 =="
"$GODOT" --headless --path . --script res://tests/world_test.gd
echo "== 战斗/联机 =="
"$GODOT" --headless --path . --script res://tests/combat_test.gd
"$GODOT" --headless --path . --script res://tests/net_test.gd
echo "== 预设单位测试 =="
"$GODOT" --headless --path . --script res://tests/flyer_test.gd
echo "== 资源模块测试 =="
"$GODOT" --headless --path . --script res://tests/economy_test.gd
echo "== 代码面板测试 =="
"$GODOT" --headless --path . --script res://tests/editor_test.gd
echo "== 资源链路测试 =="
"$GODOT" --headless --path . --script res://tests/economy_flow_test.gd
echo "== 放置单位测试 =="
"$GODOT" --headless --path . --script res://tests/place_test.gd
