#!/bin/sh
# 定位 Godot 引擎可执行文件（macOS / Linux，以及 Windows 上的 Git Bash、MSYS2、Cygwin）。
#
# 用法（被其它脚本 source）：
#     . "$(dirname "$0")/tools/godot_env.sh"
#     "$GODOT" --headless --path . --script res://tests/lang_test.gd
#
# 用法（单独执行，打印找到的路径）：
#     ./tools/godot_env.sh
#
# 查找顺序：$GODOT → PATH 里的 godot / godot4 / Godot → 各平台常见安装路径。
# 找不到时打印提示并以非 0 退出（被 source 时是 return 1）。

GODOT_ENV_SH='1'

_godot_is_exec() {
	[ -n "$1" ] && [ -x "$1" ]
}

_find_godot() {
	if _godot_is_exec "${GODOT:-}"; then
		printf '%s\n' "$GODOT"
		return 0
	fi

	for name in godot godot4 godot4.7 Godot godot-mono; do
		path=$(command -v "$name" 2>/dev/null) || continue
		if _godot_is_exec "$path"; then
			printf '%s\n' "$path"
			return 0
		fi
	done

	# macOS（含 Homebrew cask 与用户目录安装）
	for path in \
		/Applications/Godot.app/Contents/MacOS/Godot \
		/Applications/Godot_mono.app/Contents/MacOS/Godot \
		"${HOME:-/nonexistent}/Applications/Godot.app/Contents/MacOS/Godot" \
		"${HOME:-/nonexistent}/Applications/Godot_mono.app/Contents/MacOS/Godot" \
		/opt/homebrew/bin/godot \
		/usr/local/bin/godot; do
		if _godot_is_exec "$path"; then
			printf '%s\n' "$path"
			return 0
		fi
	done

	# Linux（发行版包、官方便携版、Flatpak、Snap、AppImage 常见落点）
	for path in \
		/usr/bin/godot /usr/bin/godot4 /usr/local/bin/godot /usr/local/bin/godot4 \
		/bin/godot /snap/bin/godot /opt/godot/godot /opt/godot/godot4 \
		/usr/share/godot/godot \
		"${HOME:-/nonexistent}/.local/bin/godot" \
		"${HOME:-/nonexistent}/bin/godot" \
		"${HOME:-/nonexistent}/Applications/Godot_v4.7-stable_linux.x86_64" \
		"${HOME:-/nonexistent}/Godot/Godot" \
		"${HOME:-/nonexistent}"/Godot_v4*_linux*; do
		if _godot_is_exec "$path"; then
			printf '%s\n' "$path"
			return 0
		fi
	done

	# Windows（Git Bash / MSYS2 下的 /c、/d 路径；未展开的 glob 会原样保留，[ -x ] 自然失败）
	for path in \
		"/c/Program Files/Godot/Godot.exe" \
		"/c/Program Files"/Godot*/Godot*.exe \
		"/c/Program Files (x86)/Godot/Godot.exe" \
		"/c/Program Files (x86)/"Godot*/Godot*.exe \
		/c/Godot*/Godot*.exe \
		/d/Godot*/Godot*.exe \
		/c/ProgramData/chocolatey/bin/godot.exe \
		"${LOCALAPPDATA:-/nonexistent}"/Programs/Godot*/Godot*.exe \
		"${HOME:-/nonexistent}"/scoop/apps/godot*/current/Godot*.exe; do
		if _godot_is_exec "$path"; then
			printf '%s\n' "$path"
			return 0
		fi
	done

	return 1
}

if ! GODOT=$(_find_godot); then
	{
		echo "找不到 Godot 可执行文件（需要 Godot 4.7 或更新的标准版）。"
		echo "  · 已安装但不在常见位置：export GODOT=/path/to/godot"
		echo "  · macOS 一般在 /Applications/Godot.app/Contents/MacOS/Godot"
		echo "  · Windows 双击版一般在 C:\\Program Files\\Godot\\Godot.exe，可用 \$env:GODOT 指定"
		echo "  · Linux 用发行版包安装的通常已在 PATH 里（godot）"
	} >&2
	return 1 2>/dev/null || exit 1
fi
export GODOT

# 被单独执行时把路径打出来，方便排查
if [ "${0##*/}" = "godot_env.sh" ]; then
	printf '%s\n' "$GODOT"
fi
