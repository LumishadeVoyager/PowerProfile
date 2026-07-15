[CmdletBinding()]
param(
    [ValidateSet('Idle','Balanced','Game','Auto')]
    [string]$Mode = 'Auto'
)

$ErrorActionPreference = 'Stop'

# === Mode Definitions =========================================================
# 默认值; 启动时如果存在 settings.json 会读出来覆盖 (用户在托盘"设置"里改的会持久化在那)
$DefaultProfiles = @{
    Idle = @{
        Boost = 0; Min = 50; Max = 100; FreqMax = 1800
        DisplayName = '静音'
    }
    Balanced = @{
        Boost = 1; Min = 60; Max = 99; FreqMax = 3500
        DisplayName = '均衡'
    }
    Game = @{
        Boost = 2; Min = 90; Max = 100; FreqMax = 4500
        DisplayName = '游戏'
    }
}
$DefaultAutoIntervalSec = 20
$DefaultUserIdleSec = 90
$DefaultGameExitMissCount = 6      # 连续 N 次无游戏才退出 Game (防过场/Alt-Tab 误切)

function Read-Settings {
    $path = Join-Path $PSScriptRoot 'settings.json'
    $result = @{
        Profiles = @{}
        AutoIntervalSec = $DefaultAutoIntervalSec
        UserIdleSec = $DefaultUserIdleSec
        GameExitMissCount = $DefaultGameExitMissCount
    }
    # 深拷贝默认值
    foreach ($k in $DefaultProfiles.Keys) {
        $result.Profiles[$k] = @{}
        foreach ($field in $DefaultProfiles[$k].Keys) {
            $result.Profiles[$k][$field] = $DefaultProfiles[$k][$field]
        }
    }
    if (Test-Path $path) {
        try {
            $json = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($json.modes) {
                foreach ($k in 'Idle','Balanced','Game') {
                    $m = $json.modes.$k
                    if ($m) {
                        if ($null -ne $m.freqMax) { $result.Profiles[$k].FreqMax = [int]$m.freqMax }
                        if ($null -ne $m.boost)   { $result.Profiles[$k].Boost   = [int]$m.boost }
                        if ($null -ne $m.min)     { $result.Profiles[$k].Min     = [int]$m.min }
                        if ($null -ne $m.max)     { $result.Profiles[$k].Max     = [int]$m.max }
                        if ($m.name)              { $result.Profiles[$k].DisplayName = [string]$m.name }
                    }
                }
            }
            # 用 -as [int] 防止空字符串/坏值导致 [int] 强转失败; 失败时保留默认值
            $tmp = $json.autoIntervalSec    -as [int]; if ($tmp) { $result.AutoIntervalSec    = $tmp }
            $tmp = $json.userIdleSec        -as [int]; if ($tmp) { $result.UserIdleSec        = $tmp }
            $tmp = $json.gameExitMissCount  -as [int]; if ($tmp) { $result.GameExitMissCount  = $tmp }
        } catch {
            # JSON 坏了用默认; worker 别因此挂掉
        }
    }
    return $result
}

$Settings = Read-Settings
$Profiles = $Settings.Profiles

# === Auto Detection ===========================================================
# 检测逻辑参考现成成熟方案 (不再使用进程白名单):
#   - Windows Game Mode: 前台全屏 + 进程加载 D3D/DXGI/Vulkan 模块
#   - Process Lasso IdleSaver: 鼠标键盘空闲时间 (LASTINPUTINFO)
#   - NVIDIA Optimus: 3D 模块加载 + GPU 持续占用
#
# 综合三层信号:
#   层 1 (一票否决): 鼠标键盘空闲 > 90 秒 -> 直接 Idle (人离开了)
#   层 2 (强信号):    前台全屏 + 加载 3D API + GPU 持续 >= 30% -> Game
#   层 3 (兜底):      GPU 持续 >= 60% AND CPU 持续 >= 40% -> Game (后台渲染/挂机)

# Win32 API
if (-not ('Win32Util' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Win32Util {
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO lii);
    [DllImport("kernel32.dll")] public static extern uint GetTickCount();
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    public static uint GetIdleSeconds() {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(lii);
        if (!GetLastInputInfo(ref lii)) return 0;
        return (GetTickCount() - lii.dwTime) / 1000;
    }
}
'@
}
[void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')

function Test-FullscreenD3DApp {
    $hwnd = [Win32Util]::GetForegroundWindow()
    if ($hwnd -eq [IntPtr]::Zero) { return @{ IsFs = $false; IsD3D = $false; Proc = '' } }

    $rect = New-Object Win32Util+RECT
    [void][Win32Util]::GetWindowRect($hwnd, [ref]$rect)
    $w = $rect.Right - $rect.Left
    $h = $rect.Bottom - $rect.Top

    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    # 容忍 2px 误差 (全屏游戏可能跟桌面尺寸完全一致)
    $isFs = ($w -ge ($screen.Width - 2)) -and ($h -ge ($screen.Height - 2))

    $procId = 0
    [void][Win32Util]::GetWindowThreadProcessId($hwnd, [ref]$procId)
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue

    # 检测进程是否加载了 3D 渲染 API 模块 (Windows Game Mode 同款判定)
    $isD3D = $false
    if ($proc) {
        try {
            $mods = $proc.Modules | Where-Object {
                $_.ModuleName -match '^(d3d9|d3d10|d3d11|d3d12|dxgi|vulkan-1|opengl32)\.dll$'
            }
            $isD3D = ($mods | Measure-Object).Count -gt 0
        } catch {}
    }

    return @{
        IsFs = $isFs
        IsD3D = $isD3D
        Proc = if ($proc) { $proc.ProcessName } else { '(unknown)' }
    }
}

function Get-LoadSamples {
    param([int]$Count = 3, [int]$IntervalMs = 700)
    $gpuVals = @()
    $cpuVals = @()
    $coreMaxVals = @()  # 每次采样所有核心里最高的占用 (识别单核瓶颈游戏, 如 RimWorld)
    for ($i = 0; $i -lt $Count; $i++) {
        try {
            $gpuSamples = Get-Counter '\GPU Engine(*engtype_3D)\Utilization Percentage' -ErrorAction SilentlyContinue
            $sumGpu = if ($gpuSamples) {
                ($gpuSamples.CounterSamples | Measure-Object CookedValue -Sum).Sum
            } else { 0 }
            # 同时拿单核 + 总占用 (一次 Get-Counter 调用拿所有核心)
            $cpuAllCores = Get-Counter '\Processor(*)\% Processor Time' -ErrorAction SilentlyContinue
            $cpuTotal = 0
            $coreMax = 0
            if ($cpuAllCores) {
                foreach ($s in $cpuAllCores.CounterSamples) {
                    if ($s.InstanceName -eq '_total') {
                        $cpuTotal = $s.CookedValue
                    } else {
                        if ($s.CookedValue -gt $coreMax) { $coreMax = $s.CookedValue }
                    }
                }
            }
            $gpuVals += [math]::Min($sumGpu, 100)
            $cpuVals += $cpuTotal
            $coreMaxVals += $coreMax
        } catch {}
        if ($i -lt ($Count - 1)) { Start-Sleep -Milliseconds $IntervalMs }
    }
    return @{
        MinGpu = if ($gpuVals.Count) { ($gpuVals | Measure-Object -Minimum).Minimum } else { 0 }
        MinCpu = if ($cpuVals.Count) { ($cpuVals | Measure-Object -Minimum).Minimum } else { 0 }
        MinCoreMax = if ($coreMaxVals.Count) { ($coreMaxVals | Measure-Object -Minimum).Minimum } else { 0 }
        AvgGpu = if ($gpuVals.Count) { ($gpuVals | Measure-Object -Average).Average } else { 0 }
        AvgCpu = if ($cpuVals.Count) { ($cpuVals | Measure-Object -Average).Average } else { 0 }
        AvgCoreMax = if ($coreMaxVals.Count) { ($coreMaxVals | Measure-Object -Average).Average } else { 0 }
    }
}

# 已知"非游戏 GUI 应用"黑名单 (即便全屏 + D3D 也不算游戏)
# Process Lasso / NVIDIA Optimus 同款策略: 进程黑名单 + 全屏 D3D
$Script:NonGameProcesses = @(
    # Office
    'powerpnt', 'winword', 'excel', 'onenote', 'msaccess', 'outlook', 'visio',
    'wps', 'wpp', 'et', 'wpsoffice',
    # 浏览器
    'chrome', 'msedge', 'firefox', 'brave', 'opera', 'vivaldi', 'iexplore', '360se', '360chrome',
    # 聊天/会议
    'discord', 'wechat', 'qq', 'tim', 'lark', 'feishu', 'dingtalk', 'slack', 'telegram',
    'zoom', 'teams', 'wemeetapp',
    # IDE / 开发
    'code', 'devenv', 'idea64', 'pycharm64', 'clion64', 'webstorm64', 'goland64', 'rider64',
    'cursor', 'sublime_text', 'notepad++', 'atom',
    # 视频播放/编辑
    'vlc', 'mpv', 'mpc-hc64', 'mpc-be64', 'potplayermini64', 'potplayer',
    'obs64', 'davinci', 'adobepremierepro', 'aftereffects',
    # 图片/PDF
    'photoshop', 'illustrator', 'acrord32', 'foxitreader', 'sumatrapdf',
    # 系统/Shell
    'explorer', 'dwm', 'taskmgr', 'mmc', 'consent', 'logonui',
    # 设计
    'figma', 'sketch', 'xd',
    # 游戏启动器 (Steam Big Picture/Epic/Battle.net 等大屏幕模式是 UI 不是游戏)
    # 实际游戏启动后前台是游戏进程, 不影响游戏检测
    'steam', 'steamwebhelper', 'epicgameslauncher', 'battle.net', 'gog galaxy',
    'origin', 'eaapp', 'eadesktop', 'uplay', 'ubisoftconnect',
    'riotclientservices', 'riotclientux'
)

function Test-GameRunning {
    # 优先检查: 前台全屏 + D3D + 非黑名单 -> 直接 Game
    # (手柄玩游戏不动键鼠也能识别, 不会被后续 idle 检测误判)
    $fs = Test-FullscreenD3DApp
    if ($fs.IsFs -and $fs.IsD3D) {
        $procLower = $fs.Proc.ToLower()
        $isBlacklisted = $Script:NonGameProcesses -contains $procLower
        if (-not $isBlacklisted) {
            return @{
                IsGame = $true
                Reason = "全屏3D [$($fs.Proc)] 优先识别"
            }
        }
    }

    # Layer 1: 用户离开判定 (保留, 但加双重确认防止手柄误判)
    #   只在前台**不是**全屏游戏时才考虑 idle (上面已 short-circuit)
    $idle = [Win32Util]::GetIdleSeconds()
    $quickSample = Get-LoadSamples -Count 1 -IntervalMs 0
    if ($idle -gt $Settings.UserIdleSec) {
        if ($quickSample.MinGpu -lt 10 -and $quickSample.MinCoreMax -lt 30) {
            return @{ IsGame = $false
                Reason = "人离开 ${idle}s + 低负载 GPU$([int]$quickSample.AvgGpu)% 核峰$([int]$quickSample.AvgCoreMax)%" }
        }
    }

    # 层 2 (强): 前台全屏 + 加载 3D API + 不在 GUI 黑名单
    #   - 黑名单排除 PPT/Word/浏览器/IDE/视频播放器 等 (它们全屏也加载 D3D)
    #   - 不在黑名单 + 全屏 + D3D 几乎一定是游戏, 不要求占用率
    #   - 这样 RimWorld / 小型独立游戏 / 模拟器 等 GPU/CPU 占用低的游戏也能命中
    if ($fs.IsFs -and $fs.IsD3D) {
        $procLower = $fs.Proc.ToLower()
        $isBlacklisted = $Script:NonGameProcesses -contains $procLower
        if (-not $isBlacklisted) {
            return @{
                IsGame = $true
                Reason = "全屏3D [$($fs.Proc)] 白名单进程"
            }
        }
    }

    # 以下层需要采样数据, 才开始耗时采样
    $load = Get-LoadSamples -Count 3 -IntervalMs 700

    # 前台进程是否在 GUI 黑名单 (浏览器/Office/IDE 等)
    # 如果是, 后续基于负载的层 4/5/6 全部跳过 - 浏览器看视频/网页 WebGL 不算游戏
    $fgProcLower = $fs.Proc.ToLower()
    $fgIsGuiApp  = $Script:NonGameProcesses -contains $fgProcLower

    # 层 3: 全屏 + D3D + GUI 黑名单进程 - 此时唯有大负载才算 (PPT 飙满才认游戏)
    if ($fs.IsFs -and $fs.IsD3D -and $load.MinGpu -ge 40 -and $load.MinCoreMax -ge 70) {
        return @{
            IsGame = $true
            Reason = "GUI全屏高负载 [$($fs.Proc)] GPU $([int]$load.AvgGpu)% 核峰 $([int]$load.AvgCoreMax)%"
        }
    }

    # 前台是浏览器/Office/IDE 时, 跳过层 4/5/6
    # 这些应用看视频/网页 WebGL/AI 推理 GPU 占用可以很高, 但不该判 Game
    if ($fgIsGuiApp) {
        return @{
            IsGame = $false
            Reason = "前台是 [$($fs.Proc)] (黑名单 GUI), 高负载也不算游戏"
        }
    }

    # 层 4: 单核瓶颈型 - 任一核心持续 >= 85% (后台编译/CK3/模拟器)
    if ($load.MinCoreMax -ge 85) {
        return @{
            IsGame = $true
            Reason = "单核瓶颈 核峰 $([int]$load.AvgCoreMax)% 持续"
        }
    }

    # 层 5: 多线程高负载 (烤机、3A 大作多核优化、视频导出)
    if ($load.MinGpu -ge 50 -and $load.MinCpu -ge 30) {
        return @{
            IsGame = $true
            Reason = "高负载 GPU $([int]$load.AvgGpu)% CPU $([int]$load.AvgCpu)% 持续"
        }
    }

    # 层 6: 纯 GPU 重负载 (后台渲染、AI 推理、Furmark)
    if ($load.MinGpu -ge 70) {
        return @{
            IsGame = $true
            Reason = "GPU 重载 $([int]$load.AvgGpu)% 持续"
        }
    }

    return @{
        IsGame = $false
        Reason = "fs=$($fs.IsFs) d3d=$($fs.IsD3D) proc=$($fs.Proc) GPU3D$([int]$load.AvgGpu)% CPU$([int]$load.AvgCpu)% 核峰$([int]$load.AvgCoreMax)%"
    }
}

# === Apply Profile ============================================================
function Set-PowerProfile {
    param([string]$Name)

    $cfg = $Profiles[$Name]
    if (-not $cfg) { throw "未知模式: $Name" }

    # 13代 HX P+E 异构: P-core base 2600 / max turbo 4900, E-core base 1900 / max turbo 3600.
    # PROCFREQMAX 系列只限 turbo (能压 4900 到目标, 但不能压 base 之下).
    # 要把 freqMax 设到 < 2600 (低于 P-core base), 必须靠 PROCTHROTTLEMAX 百分比.
    # PROCTHROTTLEMAX 是相对 nominal max (=base clock) 的, 例如 50% × 2600 ≈ 1300.

    $procSub = '54533251-82be-4824-96c1-47b60b740d00'
    $f0Guid  = '75b0ae3f-bce0-45a7-8c89-c9611c25e100'   # PROCFREQMAX (核类 0)
    $f1Guid  = '75b0ae3f-bce0-45a7-8c89-c9611c25e101'   # PROCFREQMAX1 (核类 1, 默认隐藏)

    # unhide 一下 P-core 那个 GUID (idempotent, 多跑无害)
    & powercfg /attributes $procSub $f1Guid -ATTRIB_HIDE | Out-Null

    # 根据 freqMax 自动算 PROCTHROTTLEMAX 兜底
    $pcoreBase = 2600
    if ($cfg.FreqMax -eq 0) {
        $throttleMax = $cfg.Max     # 无 freq 限制, 用 profile 里的 max
    } else {
        $calcPct = [int](($cfg.FreqMax * 100) / $pcoreBase)
        # 夹到 [5, 100], 不能 < 5 (否则 CPU 完全不工作)
        $throttleMax = [Math]::Max(5, [Math]::Min(100, $calcPct))
    }
    # 保证 Min ≤ Max - 5
    $throttleMin = [Math]::Min($cfg.Min, [Math]::Max(5, $throttleMax - 5))

    # === HWP 关键参数 ===
    # EPP (Energy Performance Preference): 0=极致性能, 100=极致省电
    # autonomousMode: 0 = OS 控 P-state (静音模式严格限频), 1 = HWP autonomous (灵敏 boost)
    $eppGuid        = '36687f9e-e3a5-4dbf-b1dc-15eb381c6863'
    $autonomousGuid = '8baa4a8a-14c6-4451-8e8b-14bdbd197537'
    switch ($cfg.Boost) {
        0       { $epp = 100; $autonomous = 0 }   # Idle: 极致省电 + OS 严格控制
        1       { $epp = 50;  $autonomous = 1 }   # Balanced: 中性 + HWP autonomous
        default { $epp = 0;   $autonomous = 1 }   # Game: 极致性能 + HWP autonomous
    }
    & powercfg /attributes $procSub $eppGuid -ATTRIB_HIDE | Out-Null
    & powercfg /attributes $procSub $autonomousGuid -ATTRIB_HIDE | Out-Null

    & powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PERFBOOSTMODE $cfg.Boost | Out-Null
    & powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PERFBOOSTMODE $cfg.Boost | Out-Null
    & powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN $throttleMin | Out-Null
    & powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN $throttleMin | Out-Null
    & powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX $throttleMax | Out-Null
    & powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX $throttleMax | Out-Null

    # EPP + Autonomous mode (HWP 决定性参数)
    & powercfg /SETACVALUEINDEX SCHEME_CURRENT $procSub $eppGuid        $epp | Out-Null
    & powercfg /SETDCVALUEINDEX SCHEME_CURRENT $procSub $eppGuid        $epp | Out-Null
    & powercfg /SETACVALUEINDEX SCHEME_CURRENT $procSub $autonomousGuid $autonomous | Out-Null
    & powercfg /SETDCVALUEINDEX SCHEME_CURRENT $procSub $autonomousGuid $autonomous | Out-Null

    # MHz frequency cap (核类 0 = E-core, 核类 1 = P-core); 0 = 无上限
    & powercfg /SETACVALUEINDEX SCHEME_CURRENT $procSub $f0Guid $cfg.FreqMax | Out-Null
    & powercfg /SETDCVALUEINDEX SCHEME_CURRENT $procSub $f0Guid $cfg.FreqMax | Out-Null
    & powercfg /SETACVALUEINDEX SCHEME_CURRENT $procSub $f1Guid $cfg.FreqMax | Out-Null
    & powercfg /SETDCVALUEINDEX SCHEME_CURRENT $procSub $f1Guid $cfg.FreqMax | Out-Null
    & powercfg /SETACTIVE SCHEME_CURRENT | Out-Null

    # 记录到 log 方便诊断
    $cfg.AppliedEPP = $epp
    $cfg.AppliedAutonomous = $autonomous

    # 记录算出来的 throttle 值进 log, 方便诊断
    $cfg.AppliedThrottleMin = $throttleMin
    $cfg.AppliedThrottleMax = $throttleMax

    # 写入状态文件供托盘读取
    $statePath = Join-Path $PSScriptRoot 'current_mode.txt'
    $Name | Out-File -FilePath $statePath -Encoding UTF8 -NoNewline

    # 日志
    $logPath = Join-Path $PSScriptRoot 'profile.log'
    $logLine = "{0}  switched to {1} (Boost={2} FreqMax={3}MHz throttle={4}%-{5}% EPP={6} Autonomous={7})" -f `
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Name, $cfg.Boost, $cfg.FreqMax, `
        $throttleMin, $throttleMax, $epp, $autonomous
    Add-Content -Path $logPath -Value $logLine -Encoding UTF8
}

# === Main =====================================================================
if ($Mode -eq 'Auto') {
    $statePath = Join-Path $PSScriptRoot 'current_mode.txt'
    $missCountPath = Join-Path $PSScriptRoot 'game_miss_count.txt'
    $current = if (Test-Path $statePath) { (Get-Content $statePath -Raw).Trim() } else { 'Idle' }

    $detection = Test-GameRunning
    if ($detection.IsGame) {
        # 检测到游戏 - 切 Game, 重置 miss 计数
        if ($current -ne 'Game') {
            Set-PowerProfile -Name 'Game'
            Write-Host "[AUTO] 检测到游戏 -> Game 模式 ($($detection.Reason))" -ForegroundColor Yellow
        } else {
            Write-Host "[AUTO] 维持 Game 模式 ($($detection.Reason))" -ForegroundColor Gray
        }
        '0' | Out-File -FilePath $missCountPath -Encoding ASCII -NoNewline
    } elseif ($current -eq 'Game') {
        # 当前 Game, 这次没检测到 - 累计 miss 次数
        $miss = if (Test-Path $missCountPath) {
            [int]((Get-Content $missCountPath -Raw -ErrorAction SilentlyContinue).Trim())
        } else { 0 }
        $miss++

        $threshold = $Settings.GameExitMissCount
        if ($miss -ge $threshold) {
            # 连续 N 次都没游戏 -> 切回 Idle (N 由 settings 控制, 默认 6 次 ≈ 60-120 秒)
            Set-PowerProfile -Name 'Idle'
            Write-Host "[AUTO] 连续 $miss 次无游戏 -> 切回 Idle 模式" -ForegroundColor Green
            '0' | Out-File -FilePath $missCountPath -Encoding ASCII -NoNewline
        } else {
            $miss | Out-File -FilePath $missCountPath -Encoding ASCII -NoNewline
            Write-Host "[AUTO] 暂无游戏 ($miss/$threshold), 维持 Game 模式 ($($detection.Reason))" -ForegroundColor Gray
        }
    } else {
        # 当前非 Game, 也没游戏 - 不动
        Write-Host "[AUTO] 无游戏, 维持当前 $current 模式 ($($detection.Reason))" -ForegroundColor Gray
    }
} else {
    Set-PowerProfile -Name $Mode
    Write-Host "[MANUAL] 切换到 $Mode 模式: $($Profiles[$Mode].Desc)" -ForegroundColor Cyan
}
