@echo off
chcp 65001 >nul
title PowerProfile 强制重启托盘 (需管理员)

REM 验证 admin
net session >nul 2>&1
if %errorlevel% NEQ 0 (
    echo.
    echo [错误] 必须以管理员身份运行!
    echo.
    echo 请关闭这个窗口, 然后:
    echo   1. 在文件管理器找到这个 .cmd 文件
    echo   2. 右键 - 以管理员身份运行
    echo.
    pause
    exit /b 1
)

echo === admin 权限 OK, 开始清理 ===
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_restart_tray.ps1"
echo.
echo === 完成 ===
pause
