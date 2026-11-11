#!/bin/sh
# 一键跑全部 headless 测试。可用 GODOT=/path/to/godot ./run_tests.sh 覆盖引擎路径。
set -e
cd "$(dirname "$0")"
GODOT="${GODOT:-/Users/boyu/Desktop/Godot.app/Contents/MacOS/Godot}"
for t in lang_test world_test texture_test flyer_test rover_test ai_battle_test blue_ai_test team_color_test economy_test economy_flow_test input_test editor_test place_test combat_test buildings_test power_test logistics_test logistics2_test status_badge_test weapons_test orders_test path_test net_test mp_test; do
	echo "== $t =="
	"$GODOT" --headless --path . --script "res://tests/$t.gd" -- --world-seed=20261108
done
echo "全部测试通过"
