#!/bin/sh
# 一键跑全部 headless 测试。可用 GODOT=/path/to/godot ./run_tests.sh 覆盖引擎路径。
set -e
cd "$(dirname "$0")"
GODOT="${GODOT:-/Users/boyu/Desktop/Godot.app/Contents/MacOS/Godot}"
for t in lang_test world_test flyer_test economy_test economy_flow_test editor_test place_test combat_test buildings_test net_test; do
	echo "== $t =="
	"$GODOT" --headless --path . --script "res://tests/$t.gd"
done
echo "全部测试通过"
