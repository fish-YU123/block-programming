@echo off
rem Windows launcher: hands over to play.ps1 (which locates Godot and runs it).
rem Set the GODOT environment variable if the engine is not in a common place.
rem Arguments are passed through, e.g.  play.bat -- --python
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0play.ps1" %*
if errorlevel 1 (
	echo.
	echo Launch failed. Press any key to close this window.
	pause >nul
)
endlocal
