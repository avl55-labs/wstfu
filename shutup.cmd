@echo off
:: WSTFU - double-click installer. Asks for elevation, then runs the script.
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0wstfu.ps1" shutup
echo.
pause
