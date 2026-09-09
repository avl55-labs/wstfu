@echo off
:: WSTFU - read-only status report. Changes nothing.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0wstfu.ps1" status
echo.
pause
