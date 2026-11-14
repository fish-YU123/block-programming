#!/bin/sh
# 重新生成 docs/ 下的预览图（窗口化渲染，逐张跑；没有可用显卡的机器请跳过）。
#
#   ./tests/preview/render_all.sh           # 全部
#   ./tests/preview/render_all.sh hud mp    # 只渲染名字里含 hud / mp 的
#
# 引擎查找与根目录定位和 run_tests.sh 一致（见 tools/godot_env.sh）。
set -e
cd "$(dirname "$0")/../.." || exit 1
. ./tools/godot_env.sh || exit 1

SHOTS="preview_shot unit_preview weapons_preview build_preview construction_preview
	hud_preview anim_preview team_preview charger_preview panel_preview
	mp_preview loading_preview"

selected=""
for shot in $SHOTS; do
	if [ "$#" -eq 0 ]; then
		selected="$selected $shot"
		continue
	fi
	for want in "$@"; do
		case $shot in
		*"$want"*)
			selected="$selected $shot"
			break
			;;
		esac
	done
done

if [ -z "${selected# }" ]; then
	echo "没有匹配「$*」的截图脚本。" >&2
	exit 1
fi

echo "引擎：$GODOT"
for script in $selected; do
	echo "== $script.gd"
	"$GODOT" --path . --script "res://tests/preview/$script.gd"
done
