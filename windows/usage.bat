@echo off
rem QuotaBar (Windows) launcher -- double-click or run from a shell
rem Watch mode: usage.bat --watch 300
chcp 65001 >nul
python "%~dp0api_usage.py" %*
echo.
pause
