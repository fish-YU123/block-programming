#!/bin/sh
# 重新生成 docs/ 下的预览图（窗口化渲染，逐张跑；不需要 GPU 的机器可跳过）
set -e
cd "$(dirname "$0")/../.."
GODOT="${GODOT:-/Users/boyu/Desktop/Godot.app/Contents/MacOS/Godot}"

for script in \
	preview_shot.gd \
	unit_preview.gd \
	weapons_preview.gd \
	build_preview.gd \
	construction_preview.gd \
	hud_preview.gd \
	anim_preview.gd \
	team_preview.gd \
	charger_preview.gd \
	panel_preview.gd \
	mp_preview.gd \
	loading_preview.gd
do
	echo "== $script"
	"$GODOT" --path . --script "res://tests/preview/$script"
done
