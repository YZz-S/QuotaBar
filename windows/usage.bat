@echo off
rem API Usage Show (Windows) 启动器 —— 双击或命令行调用
rem 常驻刷新用: usage.bat --watch 300
chcp 65001 >nul
python "%~dp0api_usage.py" %*
echo.
pause
