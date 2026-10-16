@echo off
rem Double-click to uninstall. Resets every colored folder first.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
echo.
pause
