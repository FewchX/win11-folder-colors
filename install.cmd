@echo off
rem Double-click to install. Runs install.ps1 past the default script execution policy.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
