# 一键跑全部 headless 测试（Windows；macOS / Linux 用 run_tests.sh）。
#
#   .\run_tests.ps1                 # 全部
#   .\run_tests.ps1 lang world      # 只跑名字里含 lang 或 world 的（按名字过滤）
#   .\run_tests.ps1 -Godot 'C:\Godot\Godot.exe'
#   .\run_tests.ps1 -Seed 123
#
# 测试是自动发现的：tests/*_test.gd，新增测试文件不用改这里。

[CmdletBinding(PositionalBinding = $false)]
param(
	[Parameter(ValueFromRemainingArguments = $true)]
	[string[]] $Filter = @(),

	[string] $Godot = '',

	[string] $Seed = '20261108'
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path $root 'tools\godot_env.ps1')

if (-not $Godot) { $Godot = Find-Godot }
if (-not (Test-Path -LiteralPath $Godot -PathType Leaf)) {
	throw "指定的 Godot 不存在：$Godot"
}

$tests = Get-ChildItem -LiteralPath (Join-Path $root 'tests') -Filter '*_test.gd' -File |
	Sort-Object Name |
	ForEach-Object { $_.BaseName }

if ($Filter.Count -gt 0) {
	$tests = @($tests | Where-Object {
		$name = $_
		$matched = $false
		foreach ($want in $Filter) {
			if ($want -and ($name -like "*$want*")) { $matched = $true; break }
		}
		$matched
	})
}

if ($tests.Count -eq 0) {
	Write-Host "没有匹配「$($Filter -join ' ')」的测试。" -ForegroundColor Yellow
	exit 1
}

Write-Host "引擎：$Godot"
Write-Host "世界种子：$Seed"

$failed = @()
$count = 0
foreach ($t in $tests) {
	$count++
	Write-Host "== $t =="
	Push-Location $root
	try {
		& $Godot --headless --path . --script "res://tests/$t.gd" -- --world-seed=$Seed
		if ($LASTEXITCODE -ne 0) { $failed += $t }
	}
	finally {
		Pop-Location
	}
}

Write-Host ''
if ($failed.Count -gt 0) {
	Write-Host "$count 套测试里有 $($failed.Count) 套失败：$($failed -join ' ')" -ForegroundColor Red
	exit 1
}
Write-Host "$count 套测试全部通过" -ForegroundColor Green
