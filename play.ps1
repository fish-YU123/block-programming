# Windows 启动器（双击 play.bat，或在这里执行 .\play.ps1）。
# 参数原样传给 Godot，例如：
#     .\play.ps1 -- --python
#     .\play.ps1 -- --world-seed=12345
# 引擎路径用环境变量指定：$env:GODOT = 'C:\Godot\Godot.exe'

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path $root 'tools\godot_env.ps1')

$godot = Find-Godot
$forward = @($args)

Push-Location $root
try {
	& $godot --path . @forward
	$status = $LASTEXITCODE
}
finally {
	Pop-Location
}

exit $status
