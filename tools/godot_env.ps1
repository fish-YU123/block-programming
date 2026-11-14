# 定位 Godot 引擎可执行文件（Windows 自带 PowerShell 5.1 与 PowerShell 7 都可用；
# macOS / Linux 上装了 PowerShell 也能用）。
#
# 用法：
#     . "$PSScriptRoot\tools\godot_env.ps1"
#     $godot = Find-Godot
#     & $godot --headless --path . --script res://tests/lang_test.gd
#
# 查找顺序：$env:GODOT → PATH 里的 godot / godot4 / Godot → 各平台常见安装路径。
# 找不到会 throw，信息里带怎么指定。

function Find-Godot {
	[CmdletBinding()]
	param(
		[string] $Path = $env:GODOT
	)

	if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
		return (Resolve-Path -LiteralPath $Path).Path
	}

	foreach ($name in 'godot', 'godot4', 'Godot', 'godot-mono') {
		$cmd = Get-Command $name -ErrorAction SilentlyContinue
		if ($cmd) { return $cmd.Source }
	}

	$candidates = @()
	foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
		if ($base) { $candidates += (Join-Path $base 'Godot\Godot.exe') }
	}
	if ($env:ProgramData) { $candidates += (Join-Path $env:ProgramData 'chocolatey\bin\godot.exe') }
	if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\Godot\Godot.exe') }
	$candidates += @(
		'C:\Godot\Godot.exe',
		'D:\Godot\Godot.exe',
		'/Applications/Godot.app/Contents/MacOS/Godot',
		'/usr/local/bin/godot',
		'/usr/bin/godot'
	)
	if ($HOME) {
		$candidates += (Join-Path $HOME 'scoop\apps\godot\current\Godot.exe')
		$candidates += (Join-Path $HOME 'Applications/Godot.app/Contents/MacOS/Godot')
	}

	foreach ($c in $candidates) {
		if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) {
			return (Resolve-Path -LiteralPath $c).Path
		}
	}

	# 版本化目录，例如 C:\Program Files\Godot_v4.7-stable_win64\Godot_v4.7-stable_win64.exe
	$roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, $env:USERPROFILE, 'C:\', 'D:\') |
		Where-Object { $_ -and (Test-Path -LiteralPath $_) }
	foreach ($root in $roots) {
		$dirs = Get-ChildItem -LiteralPath $root -Directory -Filter 'Godot*' -ErrorAction SilentlyContinue
		foreach ($dir in $dirs) {
			$exe = Get-ChildItem -LiteralPath $dir.FullName -Filter 'Godot*.exe' -File -ErrorAction SilentlyContinue |
				Where-Object { $_.Name -notmatch 'console' } |
				Select-Object -First 1
			if ($exe) { return $exe.FullName }
		}
	}

	throw ("找不到 Godot 可执行文件（需要 Godot 4.7 或更新的标准版）。`n" +
		"  显式指定：`$env:GODOT = 'C:\路径\Godot.exe'`n" +
		"  Windows 双击版一般在 C:\Program Files\Godot\Godot.exe")
}
