[CmdletBinding()]
param(
    [ValidateSet('Idle','Balanced','Game','Auto')]
    [string]$Mode = 'Auto',

    [string]$Reason = ''
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
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr OpenInputDesktop(uint dwFlags, bool fInherit, uint dwDesiredAccess);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool SwitchDesktop(IntPtr hDesktop);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool CloseDesktop(IntPtr hDesktop);
    public const uint DESKTOP_SWITCHDESKTOP = 0x0100;
    public static uint GetIdleSeconds() {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(lii);
        if (!GetLastInputInfo(ref lii)) return 0;
        return (GetTickCount() - lii.dwTime) / 1000;
    }
    public static bool IsWorkstationLocked() {
        IntPtr hDesktop = OpenInputDesktop(0, false, DESKTOP_SWITCHDESKTOP);
        if (hDesktop == IntPtr.Zero) return true;
        bool canSwitch = SwitchDesktop(hDesktop);
        CloseDesktop(hDesktop);
        return !canSwitch;
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
        Pid = $procId
    }
}

function Get-ProcessLabel {
    param([int]$ProcessId, [string]$FallbackName = '')
    if ($ProcessId -gt 0) {
        $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($p) { return "$($p.ProcessName).exe pid=$ProcessId" }
        return "pid=$ProcessId"
    }
    if ($FallbackName) { return "$FallbackName.exe" }
    return '(unknown)'
}

function Get-TopCpuProcess {
    try {
        $sample = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.IDProcess -gt 0 -and $_.Name -notin @('_Total', 'Idle') } |
            Sort-Object PercentProcessorTime -Descending |
            Select-Object -First 1
        if ($sample) {
            return @{
                Name = $sample.Name
                Pid = [int]$sample.IDProcess
                Cpu = [int]$sample.PercentProcessorTime
                Label = (Get-ProcessLabel -ProcessId ([int]$sample.IDProcess) -FallbackName $sample.Name)
            }
        }
    } catch {}
    return @{ Name = ''; Pid = 0; Cpu = 0; Label = 'unknown' }
}

function Get-LoadSamples {
    param([int]$Count = 3, [int]$IntervalMs = 700)
    $gpuVals = @()
    $cpuVals = @()
    $coreMaxVals = @()  # 每次采样所有核心里最高的占用 (识别单核瓶颈游戏, 如 RimWorld)
    $gpuByPid = @{}
    for ($i = 0; $i -lt $Count; $i++) {
        try {
            $gpuSamples = Get-Counter '\GPU Engine(*engtype_3D)\Utilization Percentage' -ErrorAction SilentlyContinue
            $sumGpu = if ($gpuSamples) {
                ($gpuSamples.CounterSamples | Measure-Object CookedValue -Sum).Sum
            } else { 0 }
            if ($gpuSamples) {
                foreach ($s in $gpuSamples.CounterSamples) {
                    if ($s.CookedValue -le 0) { continue }
                    if ($s.Path -match 'pid_(\d+)') {
                        $gpuProcessId = [int]$matches[1]
                        if (-not $gpuByPid.ContainsKey($gpuProcessId)) { $gpuByPid[$gpuProcessId] = 0.0 }
                        $gpuByPid[$gpuProcessId] += [double]$s.CookedValue
                    }
                }
            }
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
    $topGpuPid = 0
    $topGpuAvg = 0
    $topGpuName = ''
    if ($gpuByPid.Count -gt 0) {
        $topGpu = $gpuByPid.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
        if ($topGpu) {
            $topGpuPid = [int]$topGpu.Key
            $topGpuAvg = [math]::Min(100, [double]$topGpu.Value / [Math]::Max(1, $Count))
        }
    }
    if ($topGpuPid -gt 0) {
        try {
            $topGpuProcess = Get-Process -Id $topGpuPid -ErrorAction SilentlyContinue
            if ($topGpuProcess) { $topGpuName = $topGpuProcess.ProcessName.ToLower() }
        } catch {}
    }
    $topCpu = Get-TopCpuProcess
    return @{
        MinGpu = if ($gpuVals.Count) { ($gpuVals | Measure-Object -Minimum).Minimum } else { 0 }
        MinCpu = if ($cpuVals.Count) { ($cpuVals | Measure-Object -Minimum).Minimum } else { 0 }
        MinCoreMax = if ($coreMaxVals.Count) { ($coreMaxVals | Measure-Object -Minimum).Minimum } else { 0 }
        AvgGpu = if ($gpuVals.Count) { ($gpuVals | Measure-Object -Average).Average } else { 0 }
        AvgCpu = if ($cpuVals.Count) { ($cpuVals | Measure-Object -Average).Average } else { 0 }
        AvgCoreMax = if ($coreMaxVals.Count) { ($coreMaxVals | Measure-Object -Average).Average } else { 0 }
        TopGpuPid = $topGpuPid
        TopGpuName = $topGpuName
        TopGpuAvg = $topGpuAvg
        TopGpuLabel = if ($topGpuPid -gt 0) { Get-ProcessLabel -ProcessId $topGpuPid } else { 'none' }
        TopCpuPid = $topCpu.Pid
        TopCpuValue = $topCpu.Cpu
        TopCpuLabel = $topCpu.Label
    }
}

function Format-LoadSummary {
    param($Load)
    return "GPU3D=$([int]$Load.AvgGpu)% topGPU=$($Load.TopGpuLabel) $([int]$Load.TopGpuAvg)% CPU=$([int]$Load.AvgCpu)% topCPU=$($Load.TopCpuLabel) $($Load.TopCpuValue)% corePeak=$([int]$Load.AvgCoreMax)%"
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
    'cursor', 'sublime_text', 'notepad++', 'atom', 'codex', 'codex-app', 'chatgpt',
    'claude', 'windsurf', 'trae', 'zed', 'windowsterminal', 'wt', 'powershell', 'pwsh', 'cmd',
    # 视频播放/编辑
    'vlc', 'mpv', 'mpc-hc64', 'mpc-be64', 'potplayermini64', 'potplayer',
    'obs64', 'davinci', 'adobepremierepro', 'aftereffects',
    # 图片/PDF
    'photoshop', 'illustrator', 'acrord32', 'foxitreader', 'sumatrapdf',
    # 系统/Shell
    'explorer', 'dwm', 'taskmgr', 'mmc', 'consent', 'logonui', 'lockapp',
    'sihost', 'shellexperiencehost', 'startmenuexperiencehost', 'searchhost', 'searchapp',
    'textinputhost', 'applicationframehost', 'userinit', 'winlogon',
    # 桌面动态壁纸/开机组件 (可持续使用 GPU, 但绝不是游戏)
    'wallpaper32', 'wallpaper64', 'wallpaperui32', 'wallpaperui64',
    'msedgewebview2', 'widgetservice', 'widgetboard', 'crossdeviceservice',
    'hwinfo64', 'rtss', 'rtsshooksloader64',
    # 设计
    'figma', 'sketch', 'xd',
    # 游戏启动器 (Steam Big Picture/Epic/Battle.net 等大屏幕模式是 UI 不是游戏)
    # 实际游戏启动后前台是游戏进程, 不影响游戏检测
    'steam', 'steamwebhelper', 'epicgameslauncher', 'battle.net', 'gog galaxy',
    'origin', 'eaapp', 'eadesktop', 'uplay', 'ubisoftconnect',
    'riotclientservices', 'riotclientux'
)

# 硬排除: 所有已知非游戏 GUI 即使全屏 + D3D + 高负载, 也不按游戏处理.
# 这覆盖浏览器、Codex/IDE、桌面壳、Steam 大屏幕和动态壁纸等 UI.
$Script:HardNonGameProcesses = @($Script:NonGameProcesses | Select-Object -Unique)

$Script:StartupNeutralProcesses = @(
    @(
        '', '(unknown)', 'explorer', 'dwm', 'logonui', 'lockapp', 'sihost',
        'shellexperiencehost', 'startmenuexperiencehost', 'searchhost', 'searchapp',
        'textinputhost', 'applicationframehost', 'userinit', 'winlogon'
    ) + $Script:NonGameProcesses | Select-Object -Unique
)

function Get-BootStamp {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os -and $os.LastBootUpTime) {
            $boot = $os.LastBootUpTime
            if ($boot -is [DateTime]) {
                return $boot.ToString('yyyy-MM-ddTHH:mm:ss')
            }
            return ([System.Management.ManagementDateTimeConverter]::ToDateTime([string]$boot)).ToString('yyyy-MM-ddTHH:mm:ss')
        }
    } catch {}
    return ''
}

function Test-StartupGuard {
    param($Foreground, [int]$IdleSeconds)

    $bootStamp = Get-BootStamp
    if (-not $bootStamp) { return @{ Active = $false; Reason = '' } }

    $releasePath = Join-Path $PSScriptRoot 'boot_guard_released.txt'
    $releasedBoot = if (Test-Path $releasePath) {
        (Get-Content $releasePath -Raw -ErrorAction SilentlyContinue).Trim()
    } else { '' }
    if ($releasedBoot -eq $bootStamp) {
        return @{ Active = $false; Reason = '' }
    }

    $procLower = if ($Foreground.Proc) { $Foreground.Proc.ToLower() } else { '' }
    $locked = $false
    try { $locked = [Win32Util]::IsWorkstationLocked() } catch {}
    if ($locked) {
        return @{
            Active = $true
            Reason = "开机保护: 锁屏/未进入桌面, 保持静音 (front=$($Foreground.Proc), idle=${IdleSeconds}s)"
        }
    }

    if ($IdleSeconds -gt 30 -or ($Script:StartupNeutralProcesses -contains $procLower)) {
        return @{
            Active = $true
            Reason = "开机保护: 等待解锁后用户启动应用, 保持静音 (front=$($Foreground.Proc), idle=${IdleSeconds}s)"
        }
    }

    try { $bootStamp | Out-File -FilePath $releasePath -Encoding ASCII -NoNewline } catch {}
    return @{
        Active = $false
        Reason = "开机保护已解除: front=$($Foreground.Proc), idle=${IdleSeconds}s"
    }
}

function Test-GameRunning {
    $fs = Test-FullscreenD3DApp
    $idle = [Win32Util]::GetIdleSeconds()

    $startupGuard = Test-StartupGuard -Foreground $fs -IdleSeconds $idle
    if ($startupGuard.Active) {
        return @{ IsGame = $false; ForceIdle = $true; Reason = $startupGuard.Reason }
    }

    # Layer 1: 用户离开判定 (保留, 但加双重确认防止手柄误判)
    #   低负载时直接 Idle; 全屏 3D 也不能只凭窗口形态切 Game
    $quickSample = Get-LoadSamples -Count 1 -IntervalMs 0
    if ($idle -gt $Settings.UserIdleSec) {
        if ($quickSample.MinGpu -lt 10 -and $quickSample.MinCoreMax -lt 30 -and $quickSample.MinCpu -lt 20) {
            return @{ IsGame = $false
                Reason = "人离开 ${idle}s + 低负载 ($(Format-LoadSummary $quickSample))" }
        }
    }

    # 以下层需要采样数据, 才开始耗时采样
    $load = Get-LoadSamples -Count 3 -IntervalMs 700
    $loadSummary = Format-LoadSummary $load

    # 前台进程是否在 GUI 黑名单 (浏览器/Office/IDE 等)
    # 硬排除列表不会进入 GUI 高负载兜底, 避免浏览器/WebGL/Codex/Steam 大屏幕误判.
    $fgProcLower = $fs.Proc.ToLower()
    $fgIsGuiApp  = $Script:NonGameProcesses -contains $fgProcLower
    $fgIsHardNonGame = $Script:HardNonGameProcesses -contains $fgProcLower
    $topGpuIsHardNonGame = $Script:HardNonGameProcesses -contains $load.TopGpuName

    # 层 2: 全屏 + D3D 只是候选; 必须有真实负载才切 Game, 避免 Steam 大屏幕/Codex/软件全屏误判.
    if ($fs.IsFs -and $fs.IsD3D -and -not $fgIsGuiApp) {
        if ($load.MinGpu -ge 15 -or $load.MinCoreMax -ge 45 -or $load.MinCpu -ge 20) {
            return @{
                IsGame = $true
                Reason = "全屏3D活跃 [$($fs.Proc).exe pid=$($fs.Pid)] $loadSummary"
            }
        }
        return @{
            IsGame = $false
            Reason = "全屏3D但低负载 [$($fs.Proc).exe pid=$($fs.Pid)] 不切 Game; $loadSummary"
        }
    }

    # 层 3: 全屏 + D3D + GUI 黑名单进程 - 非硬排除 GUI 唯有大负载才算.
    if ($fs.IsFs -and $fs.IsD3D -and -not $fgIsHardNonGame -and $load.MinGpu -ge 40 -and $load.MinCoreMax -ge 70) {
        return @{
            IsGame = $true
            Reason = "GUI全屏高负载 [$($fs.Proc).exe pid=$($fs.Pid)] $loadSummary"
        }
    }

    if ($fgIsHardNonGame) {
        return @{
            IsGame = $false
            Reason = "前台是硬排除 GUI [$($fs.Proc).exe pid=$($fs.Pid)] 不切 Game; $loadSummary"
        }
    }

    # 前台是浏览器/Office/IDE 时, 跳过层 4/5/6
    # 这些应用看视频/网页 WebGL/AI 推理 GPU 占用可以很高, 但不该判 Game
    if ($fgIsGuiApp) {
        return @{
            IsGame = $false
            Reason = "前台是 [$($fs.Proc).exe pid=$($fs.Pid)] (黑名单 GUI), 不切 Game; $loadSummary"
        }
    }

    # 桌面动态壁纸、WebView 等后台渲染器会持续占用 GPU；没有真实游戏前台时，
    # 不让它们独自触发纯负载兜底，避免开机后桌面被误判为 Game。
    if ($topGpuIsHardNonGame) {
        return @{
            IsGame = $false
            Reason = "GPU 最高进程是后台排除项 [$($load.TopGpuLabel)], 不切 Game; $loadSummary"
        }
    }

    # 层 4: 单核瓶颈型 - 任一核心持续 >= 85% (后台编译/CK3/模拟器)
    if ($load.MinCoreMax -ge 85) {
        return @{
            IsGame = $true
            Reason = "单核瓶颈: $loadSummary"
        }
    }

    # 层 5: 多线程高负载 (烤机、3A 大作多核优化、视频导出)
    if ($load.MinGpu -ge 50 -and $load.MinCpu -ge 30) {
        return @{
            IsGame = $true
            Reason = "GPU+CPU 高负载: $loadSummary"
        }
    }

    # 层 6: 纯 GPU 重负载 (后台渲染、AI 推理、Furmark)
    if ($load.MinGpu -ge 70) {
        return @{
            IsGame = $true
            Reason = "GPU 重载: $loadSummary"
        }
    }

    return @{
        IsGame = $false
        Reason = "无游戏信号: fs=$($fs.IsFs) d3d=$($fs.IsD3D) front=$($fs.Proc).exe pid=$($fs.Pid); $loadSummary"
    }
}

# === Apply Profile ============================================================
function Set-PowerProfile {
    param(
        [string]$Name,
        [string]$Reason = ''
    )

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
    if (-not $Reason) { $Reason = '未记录原因' }
    $Reason = ($Reason -replace '\s+', ' ').Trim()
    $logLine = "{0}  switched to {1} (Boost={2} FreqMax={3}MHz throttle={4}%-{5}% EPP={6} Autonomous={7}) Reason: {8}" -f `
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Name, $cfg.Boost, $cfg.FreqMax, `
        $throttleMin, $throttleMax, $epp, $autonomous, $Reason
    Add-Content -Path $logPath -Value $logLine -Encoding UTF8
}

# === Main =====================================================================
if ($Mode -eq 'Auto') {
    $statePath = Join-Path $PSScriptRoot 'current_mode.txt'
    $missCountPath = Join-Path $PSScriptRoot 'game_miss_count.txt'
    $current = if (Test-Path $statePath) { (Get-Content $statePath -Raw).Trim() } else { 'Idle' }

    $detection = Test-GameRunning
    if ($detection.ForceIdle) {
        $bootStamp = Get-BootStamp
        $guardApplyPath = Join-Path $PSScriptRoot 'boot_guard_idle_applied.txt'
        $appliedBoot = if (Test-Path $guardApplyPath) {
            (Get-Content $guardApplyPath -Raw -ErrorAction SilentlyContinue).Trim()
        } else { '' }
        $needsGuardApply = ($current -ne 'Idle') -or ($bootStamp -and $appliedBoot -ne $bootStamp)

        if ($needsGuardApply) {
            Set-PowerProfile -Name 'Idle' -Reason $detection.Reason
            Write-Host "[AUTO] 强制保持 Idle ($($detection.Reason))" -ForegroundColor Green
            if ($bootStamp) {
                $bootStamp | Out-File -FilePath $guardApplyPath -Encoding ASCII -NoNewline
            }
        } else {
            Write-Host "[AUTO] 保持 Idle ($($detection.Reason))" -ForegroundColor Gray
        }
        '0' | Out-File -FilePath $missCountPath -Encoding ASCII -NoNewline
    } elseif ($detection.IsGame) {
        # 检测到游戏 - 切 Game, 重置 miss 计数
        if ($current -ne 'Game') {
            Set-PowerProfile -Name 'Game' -Reason $detection.Reason
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
            $reason = "连续 $miss 次无游戏; 最后一次检测: $($detection.Reason)"
            Set-PowerProfile -Name 'Idle' -Reason $reason
            Write-Host "[AUTO] 连续 $miss 次无游戏 -> 切回 Idle 模式 ($reason)" -ForegroundColor Green
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
    $manualReason = if ($Reason) { $Reason } else { "手动切换: 命令行参数 -Mode $Mode" }
    Set-PowerProfile -Name $Mode -Reason $manualReason
    Write-Host "[MANUAL] 切换到 $Mode 模式: $($Profiles[$Mode].Desc)" -ForegroundColor Cyan
}
