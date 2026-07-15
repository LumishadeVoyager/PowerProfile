# 临时: 杀掉所有托盘, 然后前台跑 PowerProfileTray.ps1 抓启动错误
$ErrorActionPreference = 'SilentlyContinue'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*PowerProfileTray.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep -Seconds 2

Write-Host "=== 解析检查 (语法错误立刻报) ===" -ForegroundColor Cyan
$err = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    'E:\PowerProfile\PowerProfileTray.ps1', [ref]$tokens, [ref]$err)
if ($err.Count -gt 0) {
    Write-Host "[X] 语法错误:" -ForegroundColor Red
    foreach ($e in $err) {
        Write-Host ("  Line {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red
    }
} else {
    Write-Host "[OK] 语法检查通过" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== 前台尝试启动 (3 秒后自动 kill) ===" -ForegroundColor Cyan
$job = Start-Job -ScriptBlock {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'E:\PowerProfile\PowerProfileTray.ps1' 2>&1
}
Start-Sleep -Seconds 3
$out = Receive-Job $job
Stop-Job $job -ErrorAction SilentlyContinue
Remove-Job $job -Force -ErrorAction SilentlyContinue

if ($out) {
    Write-Host "脚本输出:" -ForegroundColor Yellow
    $out | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host "无输出 (脚本正常进入消息循环)" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== 当前进程 ===" -ForegroundColor Cyan
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*PowerProfileTray.ps1*' } |
    Select-Object ProcessId, CreationDate | Format-Table -AutoSize
