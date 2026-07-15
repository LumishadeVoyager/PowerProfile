# 关掉所有托盘 / VBS / Worker 残留, 启动一个新实例
$ErrorActionPreference = 'SilentlyContinue'

# === 检测 admin, 不是就自动 elevate (杀 admin 跑的幽灵进程必须 admin) ===
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "需要管理员权限以杀掉历史遗留的 admin 进程, 弹 UAC 请确认..." -ForegroundColor Yellow
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath
    )
    exit 0
}

Write-Host "=== 清理所有 PowerProfile 相关进程 (admin 权限) ===" -ForegroundColor Cyan

# 顺手把所有 CommandLine 为空的 powershell.exe (历史 admin 进程通常这样) 也列出来给用户确认
$ghosts = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { [string]::IsNullOrEmpty($_.CommandLine) }
if ($ghosts) {
    Write-Host "  检测到 CommandLine 为空的 powershell 幽灵进程 (大概率是历史残留):" -ForegroundColor Yellow
    foreach ($g in $ghosts) {
        Write-Host ("    幽灵 PID {0} 启动于 {1}" -f $g.ProcessId, $g.CreationDate) -ForegroundColor Magenta
        Stop-Process -Id $g.ProcessId -Force
    }
}

# 杀所有 powershell 跑 PowerProfileTray.ps1 / PowerProfile.ps1 + 所有 wscript 跑 Start-Tray.vbs
$victims = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='wscript.exe'" |
    Where-Object {
        $_.CommandLine -like '*PowerProfileTray*' -or
        $_.CommandLine -like '*Start-Tray.vbs*' -or
        ($_.CommandLine -like '*PowerProfile.ps1*' -and $_.CommandLine -like '*-Mode*')
    }

if ($victims) {
    foreach ($p in $victims) {
        Write-Host ("  杀 PID {0} ({1})" -f $p.ProcessId, $p.Name) -ForegroundColor Yellow
        Stop-Process -Id $p.ProcessId -Force
    }
    Start-Sleep -Seconds 1
} else {
    Write-Host "  没有运行中的相关进程" -ForegroundColor Gray
}

# 确认全部死透
$still = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='wscript.exe'" |
    Where-Object {
        $_.CommandLine -like '*PowerProfileTray*' -or
        $_.CommandLine -like '*Start-Tray.vbs*'
    }
if ($still) {
    Write-Host "[警告] 仍有残留:" -ForegroundColor Red
    $still | Select-Object ProcessId, Name | Format-Table -AutoSize
    foreach ($p in $still) { Stop-Process -Id $p.ProcessId -Force }
    Start-Sleep -Seconds 1
}

# Mutex 没主动释放就重启? 不要紧, 进程死了 OS 会自动收回
Write-Host "[OK] 全部清理完成" -ForegroundColor Green

# 启动一个新实例
Write-Host ""
Write-Host "=== 启动新实例 ===" -ForegroundColor Cyan
Start-Process wscript.exe -ArgumentList '"E:\PowerProfile\Start-Tray.vbs"'
Start-Sleep -Seconds 2

$now = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*PowerProfileTray.ps1*' }
Write-Host ""
Write-Host "当前托盘实例:" -ForegroundColor Cyan
if ($now) {
    $now | Select-Object ProcessId, @{N='Started';E={$_.CreationDate}} | Format-Table -AutoSize
    Write-Host "[OK] 托盘已运行" -ForegroundColor Green
} else {
    Write-Host "[X] 托盘没起来!" -ForegroundColor Red
}

# 显示生命周期日志最后几行
$life = 'E:\PowerProfile\tray_lifecycle.log'
if (Test-Path $life) {
    Write-Host ""
    Write-Host "--- tray_lifecycle.log 最后 6 行 ---" -ForegroundColor Cyan
    Get-Content $life -Tail 6
}
