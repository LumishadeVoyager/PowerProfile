# Install.ps1 — 一键部署: 测试 + 创建开机自启任务
# 以管理员 PowerShell 运行: powershell -ExecutionPolicy Bypass -File E:\PowerProfile\Install.ps1

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkerPath = Join-Path $ScriptDir 'PowerProfile.ps1'
$TrayPath = Join-Path $ScriptDir 'PowerProfileTray.ps1'
$VbsPath = Join-Path $ScriptDir 'Start-Tray.vbs'

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  PowerProfile 安装" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

# 1. 验证管理员
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[X] 必须以管理员 PowerShell 运行!" -ForegroundColor Red
    Write-Host "    关闭后重新打开管理员 PowerShell 再运行" -ForegroundColor Yellow
    pause
    exit 1
}
Write-Host "[1/5] 管理员权限 OK" -ForegroundColor Green

# 2. 验证文件存在
foreach ($f in @($WorkerPath, $TrayPath, $VbsPath, (Join-Path $ScriptDir 'PowerProfileLogic.ps1'), (Join-Path $ScriptDir 'PowerProfileDetection.ps1'))) {
    if (-not (Test-Path $f)) {
        Write-Host "[X] 文件缺失: $f" -ForegroundColor Red
        exit 1
    }
}
Write-Host "[2/5] 脚本文件齐全" -ForegroundColor Green
foreach($name in @('Start-PowerProfile.ps1','PowerProfileVersion.ps1','PowerProfileModernUI.ps1','PowerProfileUI.cs','Read-SystemStatus.ps1','PowerProfileLog.ps1','PowerProfileWorkstation.ps1','PowerProfileWorkstation.cs','workdays.2026.json','legacy\PowerProfileTray.ps1')) {
    if(-not (Test-Path (Join-Path $ScriptDir $name))){throw "Missing file: $name"}
}
. (Join-Path $ScriptDir 'PowerProfileVersion.ps1')
if(-not(Test-Path (Join-Path $ScriptDir 'settings.json'))){Copy-Item -LiteralPath (Join-Path $ScriptDir 'settings.example.json') -Destination (Join-Path $ScriptDir 'settings.json')}
foreach($name in @('version.json','PowerProfileCState.ps1','PowerProfileUpdate.ps1','Check-PowerProfileUpdate.ps1','PowerProfileWelcomeUI.ps1','USER_GUIDE.md')){if(-not(Test-Path (Join-Path $ScriptDir $name))){throw "Missing file: $name"}}
foreach($name in @('PowerProfileWorkspaceAsync.ps1','PowerProfileWorkspace.cs','PowerProfileWorkspace.ps1','PowerProfileWorkspaceData.ps1','PowerProfileWorkspaceCharts.cs','PowerProfileConnectionUI.ps1','PowerProfileConnectionProbe.py')){if(-not(Test-Path (Join-Path $ScriptDir $name))){throw "Missing file: $name"}}
foreach($name in @('PowerProfileGameAnalytics.cs','PowerProfileInsights.ps1','PowerProfileInsightsUI.cs')){if(-not(Test-Path (Join-Path $ScriptDir $name))){throw "Missing file: $name"}}
Write-Host 'C-state 稳定性保护默认关闭；保留 Windows 原设置。现有配置不会被覆盖。' -ForegroundColor Cyan
foreach($name in @('PowerProfileTelemetry.ps1','PowerProfileLogViewer.cs')){if(-not (Test-Path (Join-Path $ScriptDir $name))){throw "Missing file: $name"}}
foreach($name in @('PowerProfileEnergy.cs','PowerProfileEnergyUI.ps1','PowerProfileFileIO.cs')){if(-not (Test-Path (Join-Path $ScriptDir $name))){throw "Missing file: $name"}}
Initialize-LegacyConfiguration $ScriptDir

# 3. 测试 Worker 脚本
Write-Host "[3/5] 测试 Worker 脚本..." -ForegroundColor Yellow
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $WorkerPath -Mode 'Idle'
    if ($LASTEXITCODE -ne 0) { throw "Worker exited with code $LASTEXITCODE" }
    Write-Host "      已临时切到 Idle 模式" -ForegroundColor Green
} catch {
    Write-Host "[X] Worker 脚本失败: $_" -ForegroundColor Red
    exit 1
}

# 4. 创建开机自启任务
Write-Host "[4/5] 创建开机自启任务..." -ForegroundColor Yellow

$taskName = 'PowerProfile Tray'

# 先删除旧任务
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$VbsPath`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$trigger.Delay = 'PT15S'  # 登录后延迟 15 秒
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $taskName `
    -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description 'PowerProfile 托盘自动启动' `
    -Force | Out-Null

Write-Host "      任务名: $taskName" -ForegroundColor Green

# 5. 立刻启动托盘
Write-Host "[5/5] 启动托盘..." -ForegroundColor Yellow

# 杀掉已存在的实例
Get-Process powershell -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -like '*PowerProfileTray*' -or $_.MainWindowTitle -like '*PowerProfile*'
} | Stop-Process -Force -ErrorAction SilentlyContinue

Start-Process wscript.exe -ArgumentList "`"$VbsPath`"" -WindowStyle Hidden
Start-Sleep -Seconds 3

Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host "  [OK] 安装完成!" -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Green
Write-Host ""
Write-Host "现在右下角任务栏应该有个小图标 (可能在 ^ 里面)" -ForegroundColor Cyan
Write-Host ""
Write-Host "图标含义:" -ForegroundColor Yellow
Write-Host "  绿色电源图标 = 静音模式；请按自己的 CPU 调整频率" -ForegroundColor Green
Write-Host "  蓝色电源图标 = 均衡模式" -ForegroundColor Cyan
Write-Host "  红色电源图标 = 游戏模式；实际性能受硬件与温度限制" -ForegroundColor Red
Write-Host ""
Write-Host "使用方法:" -ForegroundColor Yellow
Write-Host "  - 左键单击图标 = 打开统一工作台"
Write-Host "  - 右键单击图标 = 弹出菜单选模式"
Write-Host "  - 双击图标 = 打开日志"
Write-Host ""
Write-Host "自动行为:" -ForegroundColor Yellow
Write-Host "  - 按设置的检测间隔检查游戏"
Write-Host "  - 启动游戏自动切 Game"
Write-Host "  - 游戏退出自动切回 Idle (前提是你之前是 Game 模式)"
Write-Host ""
Write-Host "如果切换不灵敏, 右键托盘选具体模式" -ForegroundColor Gray
Write-Host "首次使用指南 / 插座接入 / 自动更新：设置 → 常用设置 → 使用指南与自动更新" -ForegroundColor Cyan
Write-Host "完整使用手册：$(Join-Path $ScriptDir 'USER_GUIDE.md')" -ForegroundColor Cyan
Write-Host ""
