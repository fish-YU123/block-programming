#!/bin/sh
# 一键跑全部 headless 测试（macOS / Linux；Windows 请用 run_tests.ps1，Git Bash、MSYS2 下本脚本也能跑）。
#
#   ./run_tests.sh                  # 全部
#   ./run_tests.sh lang world       # 只跑名字里含 lang 或 world 的
#   GODOT=/path/to/godot ./run_tests.sh
#   WORLD_SEED=123 ./run_tests.sh
#
# 测试是自动发现的：tests/*_test.gd，新增测试文件不用改这里。
cd "$(dirname "$0")" || exit 1
. ./tools/godot_env.sh || exit 1

SEED="${WORLD_SEED:-20261108}"
selected=""

for path in tests/*_test.gd; do
	[ -e "$path" ] || continue
	name=${path##*/}
	name=${name%.gd}
	if [ "$#" -eq 0 ]; then
		selected="$selected $name"
		continue
	fi
	for want in "$@"; do
		case $name in
		*"$want"*)
			selected="$selected $name"
			break
			;;
		esac
	done
done

if [ -z "${selected# }" ]; then
	echo "没有匹配「$*」的测试。" >&2
	exit 1
fi

echo "引擎：$GODOT"
echo "世界种子：$SEED"
count=0
failed=0
failed_list=""

for t in $selected; do
	count=$((count + 1))
	echo "== $t =="
	if ! "$GODOT" --headless --path . --script "res://tests/$t.gd" -- --world-seed="$SEED"; then
		failed=$((failed + 1))
		failed_list="$failed_list $t"
	fi
done

echo
if [ "$failed" -ne 0 ]; then
	echo "$count 套测试里有 $failed 套失败：$failed_list" >&2
	exit 1
fi
echo "$count 套测试全部通过"
