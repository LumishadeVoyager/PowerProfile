[CmdletBinding()]
param(
    [ValidateSet('Idle','Balanced','Game','Auto')]
    [string]$Mode = 'Auto',

    [string]$Reason = '',

    [int]$ActivityIdleSec = -1,
    [switch]$WorkstationOnly,
    [switch]$RestoreWorkstation,
    [ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$OperationId='',

    # Read-only: no powercfg calls or runtime state writes.
    [switch]$Diagnose
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PowerProfileDetection.ps1')
. (Join-Path $PSScriptRoot 'PowerProfileLog.ps1')
. (Join-Path $PSScriptRoot 'PowerProfileWorkstation.ps1')
if(-not $Diagnose){Initialize-ProfileLogging $PSScriptRoot 'worker' $OperationId}

# Serialize CLI, tray and settings workers. Auto skips overlaps; manual changes wait.
$workerMutex = New-Object Threading.Mutex($false, 'Global\PowerProfile_Worker')
$workerAcquired = $false
try {
    try { $workerAcquired = $workerMutex.WaitOne($(if ($Mode -eq 'Auto' -and -not $Diagnose -and -not $RestoreWorkstation) { 0 } else { 30000 })) }
    catch [Threading.AbandonedMutexException] { $workerAcquired = $true }
    if (-not $workerAcquired) {
        if ($Mode -ne 'Auto' -or $Diagnose -or $RestoreWorkstation) { throw 'PowerProfile worker is busy; command was not executed.' }
        Write-Host '[AUTO] Previous worker still running; skipped overlapping sample.'
        return
    }
    if($RestoreWorkstation){Restore-WorkstationOverlay $PSScriptRoot $(if($Reason){$Reason}else{'用户请求恢复原参数'});return}


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
        Detection = Read-DetectionOptions $null
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
            $json = Read-AtomicJson $path
            $result.Detection = Read-DetectionOptions $json.detection
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
$DetectionStatePath = Join-Path $PSScriptRoot 'game_detection_state.json'

# === Auto Detection ===========================================================
# Use install paths, per-process activity and PID/start-time session identity.
# Window shape and modules support detection; system-wide load does not prove a game.

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

    $screen = [System.Windows.Forms.Screen]::FromHandle($hwnd).Bounds
    # 容忍 2px 误差 (全屏游戏可能跟桌面尺寸完全一致)
    $isFs = ($w -ge ($screen.Width - 2)) -and ($h -ge ($screen.Height - 2)) -and
        ($rect.Left -le $screen.Left + 2) -and ($rect.Top -le $screen.Top + 2) -and
        ($rect.Right -ge $screen.Right - 2) -and ($rect.Bottom -ge $screen.Bottom - 2)

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
    $processCpu = @{}
    $cpuBefore = @{}
    $watch = [Diagnostics.Stopwatch]::StartNew()
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        try { $cpuBefore[[int]$p.Id] = @{ Seconds = $p.TotalProcessorTime.TotalSeconds; Started = $p.StartTime.Ticks } } catch {}
    }
    for ($i = 0; $i -lt $Count; $i++) {
        try {
            $gpuSamples = Get-Counter '\GPU Engine(*engtype_3D)\Utilization Percentage' -ErrorAction SilentlyContinue
            $sumGpu = if ($gpuSamples) {
                ($gpuSamples.CounterSamples | Measure-Object CookedValue -Sum).Sum
            } else { 0 }
            if ($gpuSamples) {
                $sampleByPid = @{}
                foreach ($s in $gpuSamples.CounterSamples) {
                    if ($s.CookedValue -le 0) { continue }
                    if ($s.Path -match 'pid_(\d+)') {
                        $gpuProcessId = [int]$matches[1]
                        if (-not $sampleByPid.ContainsKey($gpuProcessId)) { $sampleByPid[$gpuProcessId] = 0.0 }
                        $sampleByPid[$gpuProcessId] = [Math]::Max($sampleByPid[$gpuProcessId], [double]$s.CookedValue)
                    }
                }
            }
            if ($gpuSamples) {
                foreach ($key in $sampleByPid.Keys) {
                    if (-not $gpuByPid.ContainsKey($key)) { $gpuByPid[$key] = 0.0 }
                    $gpuByPid[$key] += $sampleByPid[$key]
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
            $gpuVals += [math]::Min([double]$sumGpu, 100.0)
            $cpuVals += $cpuTotal
            $coreMaxVals += $coreMax
        } catch {}
        if ($i -lt ($Count - 1)) { Start-Sleep -Milliseconds $IntervalMs }
    }
    $elapsed = [Math]::Max(0.01, $watch.Elapsed.TotalSeconds)
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        try {
            if ($cpuBefore.ContainsKey([int]$p.Id) -and $cpuBefore[[int]$p.Id].Started -eq $p.StartTime.Ticks) {
                $processCpu[[int]$p.Id] = [Math]::Max(0, 100.0 * ($p.TotalProcessorTime.TotalSeconds - $cpuBefore[[int]$p.Id].Seconds) / $elapsed)
            }
        } catch {}
    }
    $processGpu = @{}
    foreach ($key in $gpuByPid.Keys) { $processGpu[$key] = [Math]::Min(100.0, [double]$gpuByPid[$key] / [Math]::Max(1, $Count)) }
    $topGpuPid = 0
    $topGpuAvg = 0
    $topGpuName = ''
    if ($gpuByPid.Count -gt 0) {
        $topGpu = $gpuByPid.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
        if ($topGpu) {
            $topGpuPid = [int]$topGpu.Key
            $topGpuAvg = [math]::Min(100.0, [double]$topGpu.Value / [Math]::Max(1, $Count))
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
        ProcessCpu = $processCpu
        ProcessGpu = $processGpu
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

function Write-GameDetectionState {
    param($Detection, [int]$InputIdleSeconds)

    try {
        $obj = [PSCustomObject]@{
            observedAt = (Get-Date).ToUniversalTime().ToString('o')
            isGame = [bool]$Detection.IsGame
            forceIdle = [bool]$Detection.ForceIdle
            source = [string]$Detection.Source
            processName = [string]$Detection.ProcessName
            processId = [int]$Detection.ProcessId
            inputIdleSeconds = $InputIdleSeconds
            reason = [string]$Detection.Reason
        }
        Write-AtomicJson $DetectionStatePath $obj
    } catch {}
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
    'wallpaper32', 'wallpaper64', 'wallpaperui', 'wallpaperui32', 'wallpaperui64', 'losslessscaling',
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

    # 用户可能只用手柄启动/进入游戏，键鼠 idle 很长。真实的非排除全屏 3D
    # 本身就是明确的交互信号，可以解除开机保护；Wallpaper/浏览器等仍在硬排除列表。
    $isInteractive3D = $Foreground.IsD3D -and
        -not (Test-ExcludedGameProcess $procLower $Settings.Detection $Script:HardNonGameProcesses)
    if ($isInteractive3D) {
        if (-not $Diagnose) { try { $bootStamp | Out-File -FilePath $releasePath -Encoding ASCII -NoNewline } catch {} }
        return @{
            Active = $false
            Reason = "开机保护已解除: 检测到全屏 3D 进程 $($Foreground.Proc).exe pid=$($Foreground.Pid)"
        }
    }

    if ($IdleSeconds -gt 30 -or ($Script:StartupNeutralProcesses -contains $procLower)) {
        return @{
            Active = $true
            Reason = "开机保护: 等待解锁后用户启动应用, 保持静音 (front=$($Foreground.Proc), idle=${IdleSeconds}s)"
        }
    }

    if (-not $Diagnose) { try { $bootStamp | Out-File -FilePath $releasePath -Encoding ASCII -NoNewline } catch {} }
    return @{
        Active = $false
        Reason = "开机保护已解除: front=$($Foreground.Proc), idle=${IdleSeconds}s"
    }
}

function Test-GameRunning {
    param([string]$CurrentMode = 'Idle', [int]$InputIdleSeconds = -1)
    $fs = Test-FullscreenD3DApp
    $rawIdle = [int][Win32Util]::GetIdleSeconds()
    $idle = if ($InputIdleSeconds -ge 0) { $InputIdleSeconds } else { $rawIdle }

    # Always check the lock, even after this boot's startup guard was released.
    if ([Win32Util]::IsWorkstationLocked()) {
        return @{ IsGame = $false; ForceIdle = $true; Source = 'WorkstationLocked'; Reason = '锁屏/未进入桌面，保持静音' }
    }
    $load = Get-LoadSamples -Count 2 -IntervalMs 700
    $detection = Get-SessionGameDetection -Foreground $fs -Load $load -Options $Settings.Detection `
        -NonGameProcesses $Script:HardNonGameProcesses -StateDirectory $PSScriptRoot -ReadOnly:$Diagnose
    if ($detection.IsGame) {
        # A real library/confirmed game releases startup quiet with native HID input too.
        if (-not $Diagnose) {
            $bootStamp = Get-BootStamp
            if ($bootStamp) { $bootStamp | Out-File (Join-Path $PSScriptRoot 'boot_guard_released.txt') -Encoding ASCII -NoNewline }
        }
        return $detection
    }
    $startupGuard = Test-StartupGuard -Foreground $fs -IdleSeconds $idle
    if ($startupGuard.Active) {
        return @{ IsGame = $false; ForceIdle = $true; Source = 'StartupGuard'; Reason = $startupGuard.Reason }
    }
    if ($CurrentMode -ne 'Game' -and $idle -ge $Settings.UserIdleSec -and $load.AvgCpu -lt 20 -and $load.AvgGpu -lt 10) {
        return @{ IsGame = $false; ForceIdle = $true; Source = 'UserIdleLowLoad'; Reason = "无人输入 ${idle}s 且无游戏、低负载，保持静音" }
    }
    return $detection
}

# === Apply Profile ============================================================
function Invoke-ProfilePowerCfg {
    param([string[]]$Arguments, [switch]$Optional)
    try {
        $output = & powercfg.exe @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw "powercfg failed ($LASTEXITCODE): $($Arguments -join ' '); $output" }
    } catch {
        if ($Optional) { Write-Verbose "Optional power setting unavailable: $_" }
        else { throw }
    }
}

function Set-PowerProfile {
    param(
        [string]$Name,
        [string]$Reason = ''
    )

    Restore-WorkstationOverlay $PSScriptRoot '档位切换，先撤销附加省电'
    Write-ProfileEvent 'profile.apply.start' $Reason -Data @{mode=$Name;settings=$Profiles[$Name]}
    $cfg = $Profiles[$Name]
    if (-not $cfg) { throw "未知模式: $Name" }
    if ($cfg.Min -lt 0 -or $cfg.Min -gt 100 -or $cfg.Max -lt 5 -or $cfg.Max -gt 100 -or
        $cfg.Min -gt $cfg.Max -or $cfg.Boost -lt 0 -or $cfg.Boost -gt 6 -or $cfg.FreqMax -lt 0 -or $cfg.FreqMax -gt 10000) {
        throw "Invalid profile settings for $Name; no power settings applied."
    }

    # 13代 HX P+E 异构: P-core base 2600 / max turbo 4900, E-core base 1900 / max turbo 3600.
    # PROCFREQMAX 系列只限 turbo (能压 4900 到目标, 但不能压 base 之下).
    # 要把 freqMax 设到 < 2600 (低于 P-core base), 必须靠 PROCTHROTTLEMAX 百分比.
    # PROCTHROTTLEMAX 是相对 nominal max (=base clock) 的, 例如 50% × 2600 ≈ 1300.

    $procSub = '54533251-82be-4824-96c1-47b60b740d00'
    $f0Guid  = '75b0ae3f-bce0-45a7-8c89-c9611c25e100'   # PROCFREQMAX (核类 0)
    $f1Guid  = '75b0ae3f-bce0-45a7-8c89-c9611c25e101'   # PROCFREQMAX1 (核类 1, 默认隐藏)

    # unhide 一下 P-core 那个 GUID (idempotent, 多跑无害)
    Invoke-ProfilePowerCfg -Arguments @('/attributes', $procSub, $f1Guid, '-ATTRIB_HIDE') -Optional

    # 根据 freqMax 自动算 PROCTHROTTLEMAX 兜底
    $pcoreBase = 0
    try {
        $localSettings = Read-AtomicJson (Join-Path $PSScriptRoot 'settings.json')
        $baseOverride = $localSettings.processorBaseMHz -as [int]
        if ($baseOverride -ge 500 -and $baseOverride -le 10000) { $pcoreBase = $baseOverride }
    } catch {}
    if ($cfg.FreqMax -eq 0 -or $pcoreBase -eq 0) {
        $throttleMax = $cfg.Max     # 无已校准基频时仅使用 MHz 上限和用户设置的百分比
    } else {
        $calcPct = [int](($cfg.FreqMax * 100) / $pcoreBase)
        # 夹到 [5, 100], 不能 < 5 (否则 CPU 完全不工作)
        $throttleMax = [Math]::Max(5, [Math]::Min($cfg.Max, $calcPct))
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
    Invoke-ProfilePowerCfg -Arguments @('/attributes', $procSub, $eppGuid, '-ATTRIB_HIDE') -Optional
    Invoke-ProfilePowerCfg -Arguments @('/attributes', $procSub, $autonomousGuid, '-ATTRIB_HIDE') -Optional

    Invoke-ProfilePowerCfg -Arguments @('/SETACVALUEINDEX', 'SCHEME_CURRENT', 'SUB_PROCESSOR', 'PERFBOOSTMODE', $cfg.Boost)
    Invoke-ProfilePowerCfg -Arguments @('/SETDCVALUEINDEX', 'SCHEME_CURRENT', 'SUB_PROCESSOR', 'PERFBOOSTMODE', $cfg.Boost)
    Invoke-ProfilePowerCfg -Arguments @('/SETACVALUEINDEX', 'SCHEME_CURRENT', 'SUB_PROCESSOR', 'PROCTHROTTLEMIN', $throttleMin)
    Invoke-ProfilePowerCfg -Arguments @('/SETDCVALUEINDEX', 'SCHEME_CURRENT', 'SUB_PROCESSOR', 'PROCTHROTTLEMIN', $throttleMin)
    Invoke-ProfilePowerCfg -Arguments @('/SETACVALUEINDEX', 'SCHEME_CURRENT', 'SUB_PROCESSOR', 'PROCTHROTTLEMAX', $throttleMax)
    Invoke-ProfilePowerCfg -Arguments @('/SETDCVALUEINDEX', 'SCHEME_CURRENT', 'SUB_PROCESSOR', 'PROCTHROTTLEMAX', $throttleMax)

    # EPP + Autonomous mode (HWP 决定性参数)
    Invoke-ProfilePowerCfg -Arguments @('/SETACVALUEINDEX', 'SCHEME_CURRENT', $procSub, $eppGuid, $epp)
    Invoke-ProfilePowerCfg -Arguments @('/SETDCVALUEINDEX', 'SCHEME_CURRENT', $procSub, $eppGuid, $epp)
    Invoke-ProfilePowerCfg -Arguments @('/SETACVALUEINDEX', 'SCHEME_CURRENT', $procSub, $autonomousGuid, $autonomous)
    Invoke-ProfilePowerCfg -Arguments @('/SETDCVALUEINDEX', 'SCHEME_CURRENT', $procSub, $autonomousGuid, $autonomous)

    # MHz frequency cap (核类 0 = E-core, 核类 1 = P-core); 0 = 无上限
    Invoke-ProfilePowerCfg -Arguments @('/SETACVALUEINDEX', 'SCHEME_CURRENT', $procSub, $f0Guid, $cfg.FreqMax)
    Invoke-ProfilePowerCfg -Arguments @('/SETDCVALUEINDEX', 'SCHEME_CURRENT', $procSub, $f0Guid, $cfg.FreqMax)
    Invoke-ProfilePowerCfg -Arguments @('/SETACVALUEINDEX', 'SCHEME_CURRENT', $procSub, $f1Guid, $cfg.FreqMax) -Optional
    Invoke-ProfilePowerCfg -Arguments @('/SETDCVALUEINDEX', 'SCHEME_CURRENT', $procSub, $f1Guid, $cfg.FreqMax) -Optional
    Invoke-ProfilePowerCfg -Arguments @('/SETACTIVE', 'SCHEME_CURRENT')

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
    Write-ProfileEvent 'profile.apply.success' $Reason -Data @{mode=$Name;frequency=$cfg.FreqMax;minimum=$throttleMin;maximum=$throttleMax;boost=$cfg.Boost;epp=$epp;autonomous=$autonomous}
}

# === Main =====================================================================
if($WorkstationOnly -and -not $Diagnose){
    $current=if(Test-Path (Join-Path $PSScriptRoot 'current_mode.txt')){(Get-Content (Join-Path $PSScriptRoot 'current_mode.txt') -Raw).Trim()}else{'Unknown'}
    Invoke-WorkstationEvaluation $PSScriptRoot $current $Settings.Detection
    return
}
if ($Diagnose) {
    $diagnostic = Test-GameRunning -InputIdleSeconds $ActivityIdleSec
    [PSCustomObject]@{ detection = $diagnostic; options = $Settings.Detection; gameRoots = @(Get-InstalledGameRoots $Settings.Detection) } | ConvertTo-Json -Depth 7
    return
}
if ($Mode -eq 'Auto') {
    $statePath = Join-Path $PSScriptRoot 'current_mode.txt'
    $missCountPath = Join-Path $PSScriptRoot 'game_miss_count.txt'
    $current = if (Test-Path $statePath) { (Get-Content $statePath -Raw).Trim() } else { 'Idle' }

    $detection = Test-GameRunning -CurrentMode $current -InputIdleSeconds $ActivityIdleSec
    Write-GameDetectionState -Detection $detection -InputIdleSeconds $ActivityIdleSec
    $miss = 0
    if (Test-Path $missCountPath) {
        [void][int]::TryParse(((Get-Content $missCountPath -Raw -ErrorAction SilentlyContinue) -as [string]), [ref]$miss)
    }
    $transition = Get-AutoModeTransition $current $detection $miss $Settings.GameExitMissCount
    Write-ProfileEvent 'auto.decision' $detection.Reason -Data @{before=$current;after=$transition.Mode;missCount=$transition.MissCount;source=$detection.Source;process=$detection.ProcessName;processId=$detection.ProcessId;inputIdleSeconds=$ActivityIdleSec}
    $needsApply = $transition.Mode -ne $current
    if ($detection.ForceIdle) {
        $bootStamp = Get-BootStamp
        $guardApplyPath = Join-Path $PSScriptRoot 'boot_guard_idle_applied.txt'
        $appliedBoot = if (Test-Path $guardApplyPath) { (Get-Content $guardApplyPath -Raw).Trim() } else { '' }
        $needsApply = $needsApply -or ($bootStamp -and $appliedBoot -ne $bootStamp)
    }
    if ($needsApply) {
        Set-PowerProfile -Name $transition.Mode -Reason $detection.Reason
        if ($detection.ForceIdle -and $bootStamp) { $bootStamp | Out-File $guardApplyPath -Encoding ASCII -NoNewline }
    }
    [string]$transition.MissCount | Out-File $missCountPath -Encoding ASCII -NoNewline
    Write-Host "[AUTO] mode=$($transition.Mode) miss=$($transition.MissCount)/$($Settings.GameExitMissCount) ($($detection.Reason))"
    Invoke-WorkstationEvaluation $PSScriptRoot $transition.Mode $Settings.Detection
} else {
    $manualReason = if ($Reason) { $Reason } else { "手动切换: 命令行参数 -Mode $Mode" }
    Set-PowerProfile -Name $Mode -Reason $manualReason
    Write-Host "[MANUAL] 切换到 $Mode 模式: $($Profiles[$Mode].Desc)" -ForegroundColor Cyan
}

} catch {
    $message = "{0} PID={1} mode={2} {3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $PID, $Mode, $_.Exception.Message
    if (-not $Diagnose) {
        Write-ProfileEvent 'worker.failed' $_.Exception.Message 'ERROR' @{mode=$Mode;exception=$_.Exception.GetType().FullName;stack=$_.ScriptStackTrace;position=$_.InvocationInfo.PositionMessage}
        try{Restore-WorkstationOverlay $PSScriptRoot '检测或执行失败，撤销附加省电'}catch{Write-ProfileEvent 'workstation.restore.failed' $_.Exception.Message 'ERROR'}
        try { Add-Content (Join-Path $PSScriptRoot 'worker_error.log') -Value $message -Encoding UTF8 } catch {}
    }
    throw
} finally {
    if ($workerAcquired) { $workerMutex.ReleaseMutex() }
    $workerMutex.Dispose()
}
