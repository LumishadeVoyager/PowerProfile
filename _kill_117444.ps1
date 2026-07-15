# 直接按 PID 杀 117444 + 重启托盘 (跑在 admin 上下文)
$ErrorActionPreference = 'SilentlyContinue'

$target = 117444
Write-Host "=== 强杀 PID $target ===" -ForegroundColor Cyan
taskkill /F /PID $target 2>&1
Start-Sleep 1

$still = Get-Process -Id $target -ErrorAction SilentlyContinue
if ($still) {
    Write-Host "[X] 还活着!" -ForegroundColor Red
} else {
    Write-Host "[OK] 已死" -ForegroundColor Green
}

# 也杀所有 commandline 空的 powershell (清其他幽灵)
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { [string]::IsNullOrEmpty($_.CommandLine) } |
    ForEach-Object {
        Write-Host ("杀幽灵 PID {0}" -f $_.ProcessId) -ForegroundColor Yellow
        Stop-Process -Id $_.ProcessId -Force
    }

# 启新托盘
Start-Sleep 1
Write-Host "=== 启动新托盘 ===" -ForegroundColor Cyan
Start-Process wscript.exe -ArgumentList '"E:\PowerProfile\Start-Tray.vbs"'
Start-Sleep 3

Write-Host "=== 当前托盘进程 ===" -ForegroundColor Cyan
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*PowerProfileTray.ps1*' } |
    Select-Object ProcessId, CreationDate | Format-Table -AutoSize

Write-Host "=== lifecycle 最后 3 行 ===" -ForegroundColor Cyan
Get-Content 'E:\PowerProfile\tray_lifecycle.log' -Tail 3
Write-Host ""
Write-Host "完成. 按任意键关闭..."
[void][Console]::ReadKey()
