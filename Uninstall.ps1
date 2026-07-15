# Uninstall.ps1 — 一键卸载
# 以管理员 PowerShell 运行: powershell -ExecutionPolicy Bypass -File E:\PowerProfile\Uninstall.ps1

$ErrorActionPreference = 'SilentlyContinue'

Write-Host ""
Write-Host "PowerProfile 卸载中..." -ForegroundColor Yellow

# 1. 删除任务
Unregister-ScheduledTask -TaskName 'PowerProfile Tray' -Confirm:$false
Write-Host "[1/3] 已删除开机自启任务" -ForegroundColor Green

# 2. 杀掉运行中的托盘
Get-Process powershell -ErrorAction SilentlyContinue | Where-Object {
    try { $_.CommandLine -like '*PowerProfileTray*' } catch { $false }
} | Stop-Process -Force
Get-Process wscript -ErrorAction SilentlyContinue | Where-Object {
    try { $_.CommandLine -like '*Start-Tray*' } catch { $false }
} | Stop-Process -Force
Write-Host "[2/3] 已停止运行中的托盘" -ForegroundColor Green

# 3. 恢复默认 powercfg
& powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PERFBOOSTMODE 2 | Out-Null
& powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PERFBOOSTMODE 2 | Out-Null
& powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 5 | Out-Null
& powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 5 | Out-Null
& powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 | Out-Null
& powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 | Out-Null
& powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PROCFREQMAX 0 | Out-Null
& powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PROCFREQMAX 0 | Out-Null
& powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PROCFREQMAX1 0 | Out-Null
& powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PROCFREQMAX1 0 | Out-Null
& powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PROCFREQMAX2 0 | Out-Null
& powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PROCFREQMAX2 0 | Out-Null
& powercfg /SETACTIVE SCHEME_CURRENT | Out-Null
Write-Host "[3/3] 已恢复默认电源设置" -ForegroundColor Green

Write-Host ""
Write-Host "卸载完成。E:\PowerProfile 文件夹保留 (可手动删除)" -ForegroundColor Cyan
Write-Host ""
