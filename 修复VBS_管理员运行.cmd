@echo off
chcp 65001 >nul
title 恢复 Virtualization-Based Security (VBS) — 需管理员
echo.
echo === 检查管理员 ===
net session >nul 2>&1
if %errorlevel% NEQ 0 (
    echo [错误] 必须以管理员身份运行!
    echo 右键这个 .cmd 文件 → 以管理员身份运行
    pause
    exit /b 1
)
echo admin OK
echo.

echo === 当前状态 ===
bcdedit /enum {current} | findstr /i "hypervisor"
echo.

echo === [1/1] 启用 Hyper-V hypervisor ===
bcdedit /set hypervisorlaunchtype auto
if %errorlevel% EQU 0 (
    echo [OK] hypervisorlaunchtype = auto
) else (
    echo [X] 失败!
    pause
    exit /b 1
)

echo.
echo === 效果验证 ===
bcdedit /enum {current} | findstr /i "hypervisor"
echo.
echo === 注意 ===
echo [重要] 重启后需要进 BIOS 确认 VMX (Intel Virtualization Technology) 是 Enabled.
echo [重要] 重启后才生效.
echo.
echo 完成后系统会正常启动 hypervisor, 不再触发 VSM 初始化失败的 kernel-power 41 关机.
echo.
pause
