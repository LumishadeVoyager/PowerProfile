# PowerProfileTray.ps1 — 托盘图标 + 自动检测 + 手动切换
# 后台常驻, 状态栏小图标显示当前模式, 右键切换/退出

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkerScript = Join-Path $ScriptDir 'PowerProfile.ps1'
$StatePath = Join-Path $ScriptDir 'current_mode.txt'
$AutoEnabledPath = Join-Path $ScriptDir 'auto_enabled.txt'
$DetectionStatePath = Join-Path $ScriptDir 'game_detection_state.json'
$LegacyIdleQuietStatePath = Join-Path $ScriptDir 'idle_quiet_state.json'
$LifecycleLog = Join-Path $ScriptDir 'tray_lifecycle.log'
$DetectionScript = Join-Path $ScriptDir 'PowerProfileDetection.ps1'
. $DetectionScript
. (Join-Path $ScriptDir 'PowerProfileLog.ps1')
. (Join-Path $ScriptDir 'PowerProfileWorkstation.ps1')
Initialize-ProfileLogging $ScriptDir 'tray'

function Write-LifecycleLog {
    param([string]$Msg)
    try {
        $line = "{0}  PID={1}  {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $PID, $Msg
        Add-Content -Path $LifecycleLog -Value $line -Encoding UTF8
    } catch {}
    Write-ProfileEvent 'tray.lifecycle' $Msg
}

# === 单实例保护: 全局命名 Mutex =============================================
# 标准模式: WaitOne(0) 主动 acquire, 捕获 AbandonedMutexException 接管前任异常退出留下的锁.
$Script:SingleInstanceMutex = $null
try {
    $createdNew = $false
    $Script:SingleInstanceMutex = New-Object System.Threading.Mutex(
        $false, 'Global\PowerProfileTray_v1_Singleton', [ref]$createdNew)
} catch {
    Write-LifecycleLog "[FATAL] Mutex 构造异常: $_"
    exit 1
}
$acquired = $false
try {
    $acquired = $Script:SingleInstanceMutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    # 前任进程异常死亡, Mutex 被遗弃 -> 异常抛出但实际已经接管
    Write-LifecycleLog "[RECOVER] 接管前任异常退出留下的 Mutex"
    $acquired = $true
}
if (-not $acquired) {
    Write-LifecycleLog "[SKIP] 已有活的托盘实例运行, 本次启动退出"
    try { $Script:SingleInstanceMutex.Dispose() } catch {}
    exit 0
}
Write-LifecycleLog "[START] 单实例锁已获取, 托盘启动"

[void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
[void][System.Reflection.Assembly]::LoadWithPartialName('System.Drawing')
[Windows.Forms.Application]::EnableVisualStyles()

# 进程退出时主动释放锁 (避免 PS host 残留)
$ExitHandler = {
    try {
        if ($Script:SingleInstanceMutex) {
            $Script:SingleInstanceMutex.ReleaseMutex()
            $Script:SingleInstanceMutex.Dispose()
        }
    } catch {}
    Write-LifecycleLog "[EXIT] 托盘退出"
}
Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) -Action $ExitHandler | Out-Null

# === 圆角窗体 GDI 辅助 (toast 用) ============================================
if (-not ('GdiUtil' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public class GdiUtil {
    [DllImport("Gdi32.dll")]
    public static extern IntPtr CreateRoundRectRgn(int x1, int y1, int x2, int y2, int w, int h);
}
'@
}

# === Win32 idle 检测 (手动锁定恢复 Auto + 游戏空闲静音保护用) ==================
# LASTINPUTINFO 只追踪鼠标/键盘; XInput packet number 用于补充常见手柄输入.
if (-not ('Win32Idle' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Win32Idle {
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct XINPUT_GAMEPAD {
        public ushort wButtons;
        public byte bLeftTrigger;
        public byte bRightTrigger;
        public short sThumbLX;
        public short sThumbLY;
        public short sThumbRX;
        public short sThumbRY;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct XINPUT_STATE {
        public uint dwPacketNumber;
        public XINPUT_GAMEPAD Gamepad;
    }
    [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO lii);
    [DllImport("kernel32.dll")] public static extern uint GetTickCount();
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("xinput1_4.dll", EntryPoint="XInputGetState")]
    public static extern uint XInputGetState(uint dwUserIndex, out XINPUT_STATE pState);
    public static uint GetIdleSeconds() {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(lii);
        if (!GetLastInputInfo(ref lii)) return 0;
        return (GetTickCount() - lii.dwTime) / 1000;
    }
    public static uint GetXInputPacket(uint index) {
        XINPUT_STATE state = new XINPUT_STATE();
        uint result = XInputGetState(index, out state);
        if (result != 0) return UInt32.MaxValue;
        return state.dwPacketNumber;
    }
}
'@
}

# 已确认游戏优先于键鼠空闲；游戏判断统一由 worker 负责。
function Get-EffectiveIdle {
    $rawIdle = [Win32Idle]::GetIdleSeconds()
    if ($rawIdle -le 30) { return $rawIdle }
    $detection = Read-GameDetectionState
    if ($detection.Fresh -and $detection.IsGame) { return 0 }
    return $rawIdle
}

$Script:ControllerLastPacket = @{}
$Script:ControllerLastActivity = Get-Date

function Get-RawInputIdleSeconds {
    try { return [int][Win32Idle]::GetIdleSeconds() } catch { return 0 }
}

function Get-ControllerIdleSeconds {
    $now = Get-Date
    $sawController = $false
    for ($i = 0; $i -lt 4; $i++) {
        try {
            $packet = [Win32Idle]::GetXInputPacket([uint32]$i)
            if ($packet -ne [uint32]::MaxValue) {
                $sawController = $true
                $key = [string]$i
                if (-not $Script:ControllerLastPacket.ContainsKey($key)) {
                    $Script:ControllerLastPacket[$key] = $packet
                    $Script:ControllerLastActivity = $now
                } elseif ([uint32]$Script:ControllerLastPacket[$key] -ne $packet) {
                    $Script:ControllerLastPacket[$key] = $packet
                    $Script:ControllerLastActivity = $now
                }
            }
        } catch {}
    }

    if (-not $sawController -and $Script:ControllerLastPacket.Count -eq 0) {
        return [int]::MaxValue
    }
    return [int][Math]::Max(0, [Math]::Floor((New-TimeSpan -Start $Script:ControllerLastActivity -End $now).TotalSeconds))
}

function Get-UserActivityIdleSeconds {
    $rawIdle = Get-RawInputIdleSeconds
    $controllerIdle = Get-ControllerIdleSeconds
    return [int][Math]::Min($rawIdle, $controllerIdle)
}

function Read-GameDetectionState {
    if (-not (Test-Path $DetectionStatePath)) {
        return @{ Fresh = $false; IsGame = $false; ForceIdle = $false; Reason = '尚无游戏检测结果' }
    }
    try {
        $j = Read-AtomicJson $DetectionStatePath
        $observedAt = [DateTime]$j.observedAt
        $maxAgeSec = [Math]::Max(60, [int]$Script:Settings.autoIntervalSec * 4)
        $ageSec = [Math]::Abs(((Get-Date).ToUniversalTime() - $observedAt.ToUniversalTime()).TotalSeconds)
        return @{
            Fresh = ($ageSec -le $maxAgeSec)
            IsGame = [bool]$j.isGame
            ForceIdle = [bool]$j.forceIdle
            Source = [string]$j.source
            ProcessName = [string]$j.processName
            ProcessId = [int]$j.processId
            Reason = [string]$j.reason
            AgeSeconds = [int]$ageSec
        }
    } catch {
        return @{ Fresh = $false; IsGame = $false; ForceIdle = $false; Reason = '游戏检测状态不可读' }
    }
}

function Invoke-GameIdleQuietGuard {
    param(
        [int]$ActivityIdleSec,
        [int]$EffectiveIdleSec
    )

    $thresholdMinutes = [int]$Script:Settings.gameIdleQuietMinutes
    if ($thresholdMinutes -le 0) {
        return 'None'
    }

    $thresholdSec = $thresholdMinutes * 60
    $currentMode = Get-CurrentMode
    $needsDetection = ($currentMode -eq 'Game' -and $ActivityIdleSec -ge $thresholdSec -and $EffectiveIdleSec -ne 0)
    $detection = if ($needsDetection) {
        Read-GameDetectionState
    } else {
        @{ Fresh = $false; IsGame = $false; Source = '' }
    }
    $decision = Get-GameIdleQuietDecision `
        -CurrentMode $currentMode `
        -ActivityIdleSec $ActivityIdleSec `
        -ThresholdSec $thresholdSec `
        -EffectiveIdleSec $EffectiveIdleSec `
        -Detection $detection

    if ($decision -eq 'ForceNoGameSignal') {
        $reason = "游戏空闲静音: 无有效游戏信号且输入空闲 ${ActivityIdleSec}s, 阈值 ${thresholdSec}s; 最近检测: $($detection.Reason)"
        Invoke-Worker -Mode 'Idle' -Reason $reason
        $mins = [Math]::Round($ActivityIdleSec / 60.0, 0)
        Show-ModeToast -Mode 'Idle' -SubText "无游戏信号且无输入 ${mins} 分钟 -> 静音"
        return 'ForcedNoGameSignal'
    }

    return $decision
}

# === Auto 开关状态持久化 ======================================================
function Get-AutoEnabled {
    if (Test-Path $AutoEnabledPath) {
        return ((Get-Content $AutoEnabledPath -Raw -ErrorAction SilentlyContinue).Trim() -eq 'true')
    }
    return $true
}
function Set-AutoEnabled {
    param([bool]$Enabled)
    ($Enabled.ToString().ToLower()) | Out-File -FilePath $AutoEnabledPath -Encoding ASCII -NoNewline
}

# === 颜色 + 字体 ==============================================================
$ModeColors = @{
    Idle = [System.Drawing.Color]::FromArgb(36, 124, 112)
    Balanced = [System.Drawing.Color]::FromArgb(39, 106, 159)
    Game = [System.Drawing.Color]::FromArgb(151, 75, 83)
    Unknown = [System.Drawing.Color]::Gray
}
$ModeLabels = @{
    Idle = '静音模式'
    Balanced = '均衡模式'
    Game = '游戏模式'
}
$ModeLetters = @{
    Idle = 'I'; Balanced = 'B'; Game = 'G'
}

$NormalFont = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9, ([System.Drawing.FontStyle]::Regular)
$BoldFont = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9, ([System.Drawing.FontStyle]::Bold)

# === 16x16 彩色圆点 (菜单图标) ================================================
function New-ColorDot {
    param([System.Drawing.Color]$Color, [bool]$Filled = $true)
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    if ($Filled) {
        $brush = New-Object System.Drawing.SolidBrush $Color
        $g.FillEllipse($brush, 2, 2, 12, 12)
        $brush.Dispose()
    } else {
        $pen = New-Object System.Drawing.Pen $Color, 1.5
        $g.DrawEllipse($pen, 2, 2, 12, 12)
        $pen.Dispose()
    }
    $g.Dispose()
    return $bmp
}

# === 32x32 字母图标 (托盘) ====================================================
function New-LetterIcon {
    param([string]$Letter, [System.Drawing.Color]$BgColor)
    $bitmap = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAlias'
    $brush = New-Object System.Drawing.SolidBrush $BgColor
    $g.FillEllipse($brush, 1, 1, 30, 30)
    $brush.Dispose()
    $font = New-Object System.Drawing.Font 'Segoe UI', 16, ([System.Drawing.FontStyle]::Bold)
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $g.DrawString($Letter, $font, [System.Drawing.Brushes]::White,
        (New-Object System.Drawing.RectangleF 0, 0, 32, 32), $fmt)
    $g.Dispose(); $font.Dispose()
    $hIcon = $bitmap.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hIcon)
    $bitmap.Dispose()
    return $icon
}

# === 屏幕角落 Toast (轻量提示, 替代系统气泡) ==================================
# 自绘的小卡片在屏幕右上角浮 ~1.8 秒, 圆角半透明, 淡入淡出, 不抢焦点
$Script:ToastForm = $null
$Script:ToastTimer = $null
$Script:ToastPhase = 'done'   # fadein | stay | fadeout | done
$Script:ToastStayTicks = 0
$Script:ToastTargetOpacity = 0.94

function Close-Toast {
    if ($Script:ToastTimer) {
        try { $Script:ToastTimer.Stop(); $Script:ToastTimer.Dispose() } catch {}
        $Script:ToastTimer = $null
    }
    if ($Script:ToastForm -and -not $Script:ToastForm.IsDisposed) {
        try { $Script:ToastForm.Close(); $Script:ToastForm.Dispose() } catch {}
    }
    $Script:ToastForm = $null
    $Script:ToastPhase = 'done'
    $Script:ToastStayTicks = 0
}

function Show-ModeToast {
    param([string]$Mode, [string]$SubText = '')

    if ($Mode -eq 'Game' -or -not (Get-ModernUIOptions).toastEnabled) { Close-Toast; return }

    $letter = if ($ModeLetters.ContainsKey($Mode)) { $ModeLetters[$Mode] } else { '?' }
    $color = if ($ModeColors.ContainsKey($Mode)) { $ModeColors[$Mode] } else { $ModeColors['Unknown'] }
    $label = if ($ModeLabels.ContainsKey($Mode)) { $ModeLabels[$Mode] } else { $Mode }

    # 调试日志: 记录每次 toast 调用 + 调用栈
    try {
        $logPath = Join-Path $ScriptDir 'toast_debug.log'
        $msg = "{0}  Show-ModeToast Mode={1} Sub='{2}'" -f `
            (Get-Date -Format 'HH:mm:ss.fff'), $Mode, $SubText
        Add-Content -Path $logPath -Value $msg -Encoding UTF8
    } catch {}

    Close-Toast

    $hasSub = -not [string]::IsNullOrEmpty($SubText)
    $W = 220; $H = if ($hasSub) { 60 } else { 48 }

    $form = New-Object ProfileToastForm
    $form.FormBorderStyle = 'None'
    $form.StartPosition = 'Manual'
    $form.ShowInTaskbar = $false
    $form.TopMost = $true
    $form.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
    $form.Opacity = 0          # 从 0 开始, 由动画 Timer 淡入
    $form.Size = New-Object System.Drawing.Size $W, $H
    $form.Region = [System.Drawing.Region]::FromHrgn(
        [GdiUtil]::CreateRoundRectRgn(0, 0, $W + 1, $H + 1, 12, 12))

    # 左侧色块 + 字母
    $dotSize = 28
    $dotY = [int](($H - $dotSize) / 2)
    $dot = New-Object System.Windows.Forms.Label
    $dot.Size = New-Object System.Drawing.Size $dotSize, $dotSize
    $dot.Location = New-Object System.Drawing.Point 12, $dotY
    $dot.BackColor = $color
    $dot.ForeColor = [System.Drawing.Color]::White
    $dot.Font = New-Object System.Drawing.Font 'Segoe UI', 12, ([System.Drawing.FontStyle]::Bold)
    $dot.TextAlign = 'MiddleCenter'
    $dot.Text = $letter
    $dot.Region = [System.Drawing.Region]::FromHrgn(
        [GdiUtil]::CreateRoundRectRgn(0, 0, $dotSize + 1, $dotSize + 1, $dotSize, $dotSize))
    $form.Controls.Add($dot)

    # 主标签
    $textLabel = New-Object System.Windows.Forms.Label
    $textLabel.Text = $label
    $textLabel.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 10, ([System.Drawing.FontStyle]::Regular)
    $textLabel.ForeColor = [System.Drawing.Color]::FromArgb(34,34,34)
    $textLabel.AutoSize = $false
    $textLabel.BackColor = [System.Drawing.Color]::Transparent

    if ($hasSub) {
        $textLabel.TextAlign = 'BottomLeft'
        $textLabel.Size = New-Object System.Drawing.Size 160, 28
        $textLabel.Location = New-Object System.Drawing.Point 50, 4

        $subLabel = New-Object System.Windows.Forms.Label
        $subLabel.Text = $SubText
        $subLabel.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 8, ([System.Drawing.FontStyle]::Regular)
        $subLabel.ForeColor = [System.Drawing.Color]::FromArgb(96, 96, 96)
        $subLabel.AutoSize = $false
        $subLabel.BackColor = [System.Drawing.Color]::Transparent
        $subLabel.TextAlign = 'TopLeft'
        $subLabel.Size = New-Object System.Drawing.Size 160, 20
        $subLabel.Location = New-Object System.Drawing.Point 50, 32
        $form.Controls.Add($subLabel)
    } else {
        $textLabel.TextAlign = 'MiddleLeft'
        $textLabel.Size = New-Object System.Drawing.Size 160, ($H - 8)
        $textLabel.Location = New-Object System.Drawing.Point 50, 4
    }
    $form.Controls.Add($textLabel)

    # 右上角 (顶部留 24px 避开标题栏区域)
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Location = New-Object System.Drawing.Point ($screen.Right - $W - 16), ($screen.Top + 24)

    # 点击立刻关
    $form.Add_Click({ Close-Toast })
    foreach ($c in $form.Controls) { $c.Add_Click({ Close-Toast }) }

    $Script:ToastForm = $form
    # 状态挂在 form.Tag 上 (PS WinForms Timer 闭包对 $Script: 变量赋值不可靠)
    $form.Tag = @{ Phase = 'fadein'; StayTicks = 0; Target = 0.94 }
    $form.Show()

    # 动画状态机: fadein -> stay (~1.2s) -> fadeout, Tick 30ms
    #   fadein: Opacity +0.10 / tick, 约 280ms 达到 0.94
    #   stay:   维持 40 tick = 1200ms
    #   fadeout: Opacity -0.07 / tick, 约 400ms 归零
    $debugPath = Join-Path $ScriptDir 'toast_debug.log'
    $Script:ToastTimer = New-Object System.Windows.Forms.Timer
    $Script:ToastTimer.Interval = 30
    $Script:ToastTimer.Tag = @{ DebugPath = $debugPath; TickCount = 0 }
    $Script:ToastTimer.Add_Tick({
        param($sender, $e)
        $timer = $sender
        $tdata = $timer.Tag
        $tdata.TickCount++
        $f = $Script:ToastForm
        if (-not $f -or $f.IsDisposed) {
            try { $timer.Stop(); $timer.Dispose() } catch {}
            return
        }
        $state = $f.Tag
        # 每 10 tick 写一次 debug
        if (($tdata.TickCount % 10) -eq 0) {
            try {
                $msg = "{0}  tick #{1}  phase={2}  opacity={3:F2}  stayTicks={4}" -f `
                    (Get-Date -Format 'HH:mm:ss.fff'), $tdata.TickCount,
                    $state.Phase, $f.Opacity, $state.StayTicks
                Add-Content -Path $tdata.DebugPath -Value $msg -Encoding UTF8
            } catch {}
        }
        switch ($state.Phase) {
            'fadein' {
                $newOp = [Math]::Min($state.Target, $f.Opacity + 0.10)
                $f.Opacity = $newOp
                if ($newOp -ge $state.Target) {
                    $state.Phase = 'stay'
                    $state.StayTicks = 0
                }
            }
            'stay' {
                $state.StayTicks = $state.StayTicks + 1
                # 停留 ticks = toastStaySec * 1000 / 30ms; 至少 10 防设置极小
                $stayLimit = [Math]::Max(10, [int](($Script:Settings.toastStaySec * 1000) / 30))
                if ($state.StayTicks -ge $stayLimit) {
                    $state.Phase = 'fadeout'
                }
            }
            'fadeout' {
                $newOp = [Math]::Max(0.0, $f.Opacity - 0.07)
                $f.Opacity = $newOp
                if ($newOp -le 0.02) {
                    try { $timer.Stop(); $timer.Dispose() } catch {}
                    if (-not $f.IsDisposed) {
                        try { $f.Close(); $f.Dispose() } catch {}
                    }
                    $Script:ToastForm = $null
                }
            }
        }
    })
    $Script:ToastTimer.Start()
}

# === 设置 (settings.json) =====================================================
$SettingsPath = Join-Path $ScriptDir 'settings.json'

$DefaultSettings = @{
    modes = @{
        Idle     = @{ name = '静音'; freqMax = 1800; boost = 0; min = 50; max = 100 }
        Balanced = @{ name = '均衡'; freqMax = 3500; boost = 1; min = 60; max = 99 }
        Game     = @{ name = '游戏'; freqMax = 0; boost = 2; min = 90; max = 100 }
    }
    autoIntervalSec = 20
    userIdleSec = 90
    toastStaySec = 1.2
    manualUnlockMinutes = 10   # 手动锁定后 idle 这么久 -> 自动恢复 Auto
    gameIdleQuietMinutes = 10   # Game 模式中鼠标/键盘/手柄无输入这么久 -> 临时强制静音
    gameExitMissCount = 6      # 连续 N 次无游戏才退出 Game 模式 (防过场/Alt-Tab 误切)
}

function Read-Settings {
    $s = @{
        modes = @{}
        autoIntervalSec = $DefaultSettings.autoIntervalSec
        userIdleSec = $DefaultSettings.userIdleSec
        toastStaySec = $DefaultSettings.toastStaySec
        manualUnlockMinutes = $DefaultSettings.manualUnlockMinutes
        gameIdleQuietMinutes = $DefaultSettings.gameIdleQuietMinutes
        gameExitMissCount = $DefaultSettings.gameExitMissCount
    }
    foreach ($k in 'Idle','Balanced','Game') {
        $s.modes[$k] = @{}
        foreach ($f in $DefaultSettings.modes[$k].Keys) {
            $s.modes[$k][$f] = $DefaultSettings.modes[$k][$f]
        }
    }
    if (Test-Path $SettingsPath) {
        try {
            $j = Read-AtomicJson $SettingsPath
            if ($j.modes) {
                foreach ($k in 'Idle','Balanced','Game') {
                    $m = $j.modes.$k
                    if ($m) {
                        if ($m.name)              { $s.modes[$k].name    = [string]$m.name }
                        if ($null -ne $m.freqMax) { $s.modes[$k].freqMax = [int]$m.freqMax }
                        if ($null -ne $m.boost)   { $s.modes[$k].boost   = [int]$m.boost }
                        if ($null -ne $m.min)     { $s.modes[$k].min     = [int]$m.min }
                        if ($null -ne $m.max)     { $s.modes[$k].max     = [int]$m.max }
                    }
                }
            }
            if ($null -ne $j.autoIntervalSec)     { $s.autoIntervalSec     = [int]$j.autoIntervalSec }
            if ($null -ne $j.userIdleSec)         { $s.userIdleSec         = [int]$j.userIdleSec }
            if ($null -ne $j.toastStaySec)        { $s.toastStaySec        = [double]$j.toastStaySec }
            if ($null -ne $j.manualUnlockMinutes) { $s.manualUnlockMinutes = [int]$j.manualUnlockMinutes }
            if ($null -ne $j.gameIdleQuietMinutes) { $s.gameIdleQuietMinutes = [int]$j.gameIdleQuietMinutes }
            if ($null -ne $j.gameExitMissCount)   { $s.gameExitMissCount   = [int]$j.gameExitMissCount }
        } catch {}
    }
    return $s
}

function Save-Settings {
    param([hashtable]$Settings)
    $obj = [PSCustomObject]@{
        modes = [PSCustomObject]@{
            Idle     = [PSCustomObject]$Settings.modes.Idle
            Balanced = [PSCustomObject]$Settings.modes.Balanced
            Game     = [PSCustomObject]$Settings.modes.Game
        }
        autoIntervalSec = $Settings.autoIntervalSec
        userIdleSec = $Settings.userIdleSec
        toastStaySec = $Settings.toastStaySec
        manualUnlockMinutes = $Settings.manualUnlockMinutes
        gameIdleQuietMinutes = $Settings.gameIdleQuietMinutes
        gameExitMissCount = $Settings.gameExitMissCount
    }
    # Preserve advanced/local rules when the GUI edits only its own fields.
    if (Test-Path -LiteralPath $SettingsPath) {
        try {
            $existing = Read-AtomicJson $SettingsPath
            foreach ($property in $existing.PSObject.Properties) {
                if ($property.Name -notin @($obj.PSObject.Properties.Name)) {
                    $obj | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value
                }
            }
        } catch { throw '现有设置无法读取，请先修复 settings.json，避免覆盖本机规则。' }
    }
    Write-AtomicJson $SettingsPath $obj -Pretty
}

$Script:Settings = Read-Settings

function Refresh-ModeLabels {
    $ModeLabels['Idle']     = $Script:Settings.modes.Idle.name
    $ModeLabels['Balanced'] = $Script:Settings.modes.Balanced.name
    $ModeLabels['Game']     = $Script:Settings.modes.Game.name
}
Refresh-ModeLabels

function Format-Freq {
    param([int]$Mhz)
    if ($Mhz -eq 0) { return '无上限' }
    return "{0:F1}GHz" -f ($Mhz / 1000.0)
}

function New-Preset {
    param([string]$Text, [double]$Value)
    return [PSCustomObject]@{ Text = $Text; Value = $Value }
}

function New-PresetCombo {
    param(
        [object[]]$Options,
        [double]$CurrentValue,
        [int]$Width = 300
    )
    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = 'DropDownList'
    $combo.DisplayMember = 'Text'
    $combo.ValueMember = 'Value'
    $combo.Size = New-Object System.Drawing.Size $Width, 28
    $combo.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9

    $selectedIndex = -1
    foreach ($opt in $Options) {
        [void]$combo.Items.Add($opt)
        if ([Math]::Abs(([double]$opt.Value) - $CurrentValue) -lt 0.001) {
            $selectedIndex = $combo.Items.Count - 1
        }
    }

    if ($selectedIndex -lt 0) {
        $customText = "当前自定义: $CurrentValue"
        if ($CurrentValue -eq 0) {
            $customText = '当前自定义: 无上限'
        }
        [void]$combo.Items.Add((New-Preset $customText $CurrentValue))
        $selectedIndex = $combo.Items.Count - 1
    }
    $combo.SelectedIndex = $selectedIndex
    return $combo
}

function Get-PresetValue {
    param([System.Windows.Forms.ComboBox]$Combo)
    if ($Combo.SelectedItem -and ($Combo.SelectedItem.PSObject.Properties.Name -contains 'Value')) {
        return [double]$Combo.SelectedItem.Value
    }
    return 0
}

function Get-FrequencyPresets {
    param([string]$ModeKey)
    switch ($ModeKey) {
        'Idle' {
            return @(
                (New-Preset '极静音: 1.6GHz' 1600),
                (New-Preset '安静推荐: 2.0GHz' 2000),
                (New-Preset '轻办公: 2.2GHz' 2200),
                (New-Preset '更稳压: 1.8GHz' 1800)
            )
        }
        'Balanced' {
            return @(
                (New-Preset '日常推荐: 3.0GHz' 3000),
                (New-Preset '省电办公: 2.6GHz' 2600),
                (New-Preset '积极响应: 3.5GHz' 3500),
                (New-Preset '不限频率' 0)
            )
        }
        'Game' {
            return @(
                (New-Preset '满血无上限' 0),
                (New-Preset '稳定高性能: 4.5GHz' 4500),
                (New-Preset '温控优先: 4.0GHz' 4000),
                (New-Preset '保守游戏: 3.6GHz' 3600)
            )
        }
    }
}

# === 状态读取 + Worker 调用 ===================================================
function Get-CurrentMode {
    if (Test-Path $StatePath) {
        return (Get-Content $StatePath -Raw -ErrorAction SilentlyContinue).Trim()
    }
    return 'Unknown'
}

function Start-HiddenPowerShell {
    param([string[]]$Arguments)

    # Start-Process -WindowStyle Hidden can still briefly create a console window
    # on Windows. CREATE_NO_WINDOW is the reliable option for this periodic worker.
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $startInfo.Arguments = $Arguments -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    return [System.Diagnostics.Process]::Start($startInfo)
}

# 非阻塞调用 worker. 之前 -Wait 会卡 UI 2 秒采样时间; 现在 fire-and-forget,
# 状态变化由文件监视 timer 检测.
function Invoke-Worker {
    param(
        [string]$Mode,
        [string]$Reason = '',
        [int]$ActivityIdleSec = -1
    )
    if ($Mode -eq 'Auto' -and $Script:WorkerProcess -and -not $Script:WorkerProcess.HasExited) { return }
    $operation=[Guid]::NewGuid().ToString()
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $WorkerScript), '-Mode', $Mode,'-OperationId',$operation)
    if ($Reason) { $args += @('-Reason', ('"{0} "' -f ($Reason -replace '["\r\n]', ' '))) }
    if ($Mode -eq 'Auto' -and $ActivityIdleSec -ge 0) { $args += @('-ActivityIdleSec', $ActivityIdleSec) }
    $Script:WorkerProcess = Start-HiddenPowerShell -Arguments $args
    Write-ProfileEvent 'worker.request' '已派发电源检测或档位操作' -Data @{operationId=$operation;mode=$Mode;reason=$Reason;workerPid=$Script:WorkerProcess.Id}
}

function Invoke-WorkstationWorker {
    param([switch]$Restore,[string]$RestoreReason='用户关闭、暂停或保存省电配置')
    if($Script:WorkstationProcess -and -not $Script:WorkstationProcess.HasExited){return}
    if(-not $Restore -and $Script:WorkerProcess -and -not $Script:WorkerProcess.HasExited){return}
    $operation=[Guid]::NewGuid().ToString()
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $WorkerScript),'-Mode','Auto','-OperationId',$operation)
    $arguments+=if($Restore){'-RestoreWorkstation'}else{'-WorkstationOnly'}
    if($Restore){$arguments+=@('-Reason',('"{0}"' -f ($RestoreReason -replace '["\r\n]',' ')))}
    $Script:WorkstationProcess=Start-HiddenPowerShell $arguments
    if($Restore){Write-ProfileEvent 'workstation.restore.request' $RestoreReason -Data @{operationId=$operation;workerPid=$Script:WorkstationProcess.Id}}
}

function Open-ProfileLog {
    Show-ModernLogViewer
}

# === Show-Settings: 拖滑块 + 改模式名 + 其他设置 ==============================
function Show-Settings {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'PowerProfile 设置'
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ClientSize = New-Object System.Drawing.Size 560, 728
    $form.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9
    $form.TopMost = $true
    $form.BackColor = [System.Drawing.Color]::FromArgb(247, 248, 250)

    $work = Read-Settings
    $controls = @{}
    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.AutoPopDelay = 7000
    $tip.InitialDelay = 350
    $tip.ReshowDelay = 120

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'PowerProfile 设置'
    $title.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 16, ([System.Drawing.FontStyle]::Bold)
    $title.Location = New-Object System.Drawing.Point 18, 14
    $title.Size = New-Object System.Drawing.Size 260, 32
    $form.Controls.Add($title)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = '模式频率与自动策略'
    $subtitle.ForeColor = [System.Drawing.Color]::FromArgb(96, 103, 112)
    $subtitle.Location = New-Object System.Drawing.Point 20, 48
    $subtitle.Size = New-Object System.Drawing.Size 260, 22
    $form.Controls.Add($subtitle)

    $y = 82
    foreach ($modeKey in 'Idle','Balanced','Game') {
        $color = $ModeColors[$modeKey]
        $modeData = $work.modes[$modeKey]

        $grp = New-Object System.Windows.Forms.GroupBox
        $grp.Text = "  $modeKey  "
        $grp.ForeColor = $color
        $grp.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 10, ([System.Drawing.FontStyle]::Bold)
        $grp.Location = New-Object System.Drawing.Point 18, $y
        $grp.Size = New-Object System.Drawing.Size 524, 96
        $grp.BackColor = [System.Drawing.Color]::White
        $form.Controls.Add($grp)

        $lblName = New-Object System.Windows.Forms.Label
        $lblName.Text = '模式名称:'
        $lblName.Location = New-Object System.Drawing.Point 18, 28
        $lblName.Size = New-Object System.Drawing.Size 72, 22
        $lblName.ForeColor = [System.Drawing.SystemColors]::ControlText
        $lblName.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9
        $grp.Controls.Add($lblName)

        $tbName = New-Object System.Windows.Forms.TextBox
        $tbName.Text = $modeData.name
        $tbName.Location = New-Object System.Drawing.Point 92, 25
        $tbName.Size = New-Object System.Drawing.Size 150, 26
        $tbName.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9
        $grp.Controls.Add($tbName)

        $lblFreq = New-Object System.Windows.Forms.Label
        $lblFreq.Text = '频率挡位:'
        $lblFreq.Location = New-Object System.Drawing.Point 18, 62
        $lblFreq.Size = New-Object System.Drawing.Size 72, 22
        $lblFreq.ForeColor = [System.Drawing.SystemColors]::ControlText
        $lblFreq.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9
        $grp.Controls.Add($lblFreq)

        $freqCombo = New-PresetCombo -Options (Get-FrequencyPresets $modeKey) -CurrentValue ([double]$modeData.freqMax) -Width 250
        $freqCombo.Location = New-Object System.Drawing.Point 92, 58
        $grp.Controls.Add($freqCombo)
        $tip.SetToolTip($freqCombo, '选择一个预设频率上限。无上限会交给 Windows/HWP 满血调度。')

        $lblCurrent = New-Object System.Windows.Forms.Label
        $lblCurrent.Text = "当前: $(Format-Freq $modeData.freqMax)"
        $lblCurrent.Location = New-Object System.Drawing.Point 360, 59
        $lblCurrent.Size = New-Object System.Drawing.Size 140, 24
        $lblCurrent.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9
        $lblCurrent.ForeColor = [System.Drawing.Color]::FromArgb(96, 103, 112)
        $grp.Controls.Add($lblCurrent)
        $freqCombo.Add_SelectedIndexChanged({
            param($sender, $e)
            $value = [int](Get-PresetValue $sender)
            foreach ($c in $sender.Parent.Controls) {
                if ($c -is [System.Windows.Forms.Label] -and $c.Text.StartsWith('当前:')) {
                    $c.Text = "当前: $(Format-Freq $value)"
                }
            }
        })

        $controls[$modeKey] = @{
            NameBox = $tbName
            FreqCombo = $freqCombo
        }
        $y += 106
    }

    $grpOther = New-Object System.Windows.Forms.GroupBox
    $grpOther.Text = '  其他设置  '
    $grpOther.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 10, ([System.Drawing.FontStyle]::Bold)
    $grpOther.Location = New-Object System.Drawing.Point 18, $y
    $grpOther.Size = New-Object System.Drawing.Size 524, 252
    $grpOther.BackColor = [System.Drawing.Color]::White
    $form.Controls.Add($grpOther)

    $autoOptions = @(
        (New-Preset '灵敏: 每 5 秒检测' 5),
        (New-Preset '推荐: 每 15 秒检测' 15),
        (New-Preset '省电: 每 30 秒检测' 30),
        (New-Preset '保守: 每 60 秒检测' 60)
    )
    $idleOptions = @(
        (New-Preset '灵敏: 60 秒无人操作' 60),
        (New-Preset '推荐: 90 秒无人操作' 90),
        (New-Preset '稳定: 3 分钟无人操作' 180),
        (New-Preset '保守: 5 分钟无人操作' 300)
    )
    $toastOptions = @(
        (New-Preset '短提示: 1.0 秒' 1.0),
        (New-Preset '推荐: 1.2 秒' 1.2),
        (New-Preset '清楚: 2.0 秒' 2.0),
        (New-Preset '慢速: 3.0 秒' 3.0)
    )
    $unlockOptions = @(
        (New-Preset '快速恢复: 5 分钟' 5),
        (New-Preset '推荐: 10 分钟' 10),
        (New-Preset '稳定: 20 分钟' 20),
        (New-Preset '保守: 45 分钟' 45)
    )
    $quietOptions = @(
        (New-Preset '关闭' 0),
        (New-Preset '推荐: 10 分钟无输入' 10),
        (New-Preset '稳定: 15 分钟无输入' 15),
        (New-Preset '保守: 20 分钟无输入' 20),
        (New-Preset '很长: 30 分钟无输入' 30)
    )
    $exitOptions = @(
        (New-Preset '灵敏: 3 次无游戏' 3),
        (New-Preset '推荐: 6 次无游戏' 6),
        (New-Preset '稳定: 10 次无游戏' 10),
        (New-Preset '保守: 15 次无游戏' 15)
    )

    function Add-SettingRow {
        param(
            [System.Windows.Forms.Control]$Parent,
            [string]$Label,
            [object[]]$Options,
            [double]$CurrentValue,
            [int]$X,
            [int]$Y,
            [string]$Tooltip
        )
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $Label
        $lbl.Location = New-Object System.Drawing.Point $X, $Y
        $lbl.Size = New-Object System.Drawing.Size 120, 22
        $lbl.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9
        $Parent.Controls.Add($lbl)

        $combo = New-PresetCombo -Options $Options -CurrentValue $CurrentValue -Width 350
        $combo.Location = New-Object System.Drawing.Point ($X + 128), ($Y - 3)
        $Parent.Controls.Add($combo)
        $tip.SetToolTip($combo, $Tooltip)
        return $combo
    }

    $cmbAuto = Add-SettingRow $grpOther '检测频率' $autoOptions ([double]$work.autoIntervalSec) 20 36 '越灵敏越快响应, 也会更频繁采样。'
    $cmbIdle = Add-SettingRow $grpOther '人离开判定' $idleOptions ([double]$work.userIdleSec) 20 70 '空闲超过这个挡位且低负载时保持静音。'
    $cmbToast = Add-SettingRow $grpOther '提示停留' $toastOptions ([double]$work.toastStaySec) 20 104 '托盘提示停留时间。'
    $cmbUnlock = Add-SettingRow $grpOther '恢复 Auto' $unlockOptions ([double]$work.manualUnlockMinutes) 20 138 '手动锁定后空闲多久自动恢复 Auto。'
    $cmbQuiet = Add-SettingRow $grpOther '游戏空闲静音' $quietOptions ([double]$work.gameIdleQuietMinutes) 20 172 '仅在没有有效游戏进程或负载信号时，无输入多久后切到静音。'
    $cmbExit = Add-SettingRow $grpOther '退出防抖' $exitOptions ([double]$work.gameExitMissCount) 20 206 '游戏结束后连续多少次无游戏才切回静音。'

    $y += 264

    $btnReset = New-Object System.Windows.Forms.Button
    $btnReset.Text = '恢复默认'
    $btnReset.Location = New-Object System.Drawing.Point 18, $y
    $btnReset.Size = New-Object System.Drawing.Size 100, 32
    $form.Controls.Add($btnReset)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = '保存'
    $btnSave.Location = New-Object System.Drawing.Point 326, $y
    $btnSave.Size = New-Object System.Drawing.Size 100, 32
    $btnSave.BackColor = [System.Drawing.Color]::FromArgb(33, 150, 243)
    $btnSave.ForeColor = [System.Drawing.Color]::White
    $btnSave.FlatStyle = 'Flat'
    $form.Controls.Add($btnSave)
    $form.AcceptButton = $btnSave

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.Location = New-Object System.Drawing.Point 438, $y
    $btnCancel.Size = New-Object System.Drawing.Size 100, 32
    $form.Controls.Add($btnCancel)
    $form.CancelButton = $btnCancel

    $btnSave.Add_Click({
        $diag = 'E:\PowerProfile\save_debug.log'
        try {
            Add-Content -Path $diag -Value ("{0}  Click triggered" -f (Get-Date -Format 'HH:mm:ss.fff')) -Encoding UTF8
            Add-Content -Path $diag -Value ("  work is null? {0}; controls count: {1}" -f ($null -eq $work), $controls.Count) -Encoding UTF8
        } catch {}

        try {
            foreach ($k in 'Idle','Balanced','Game') {
                $name = $controls[$k].NameBox.Text.Trim()
                if (-not $name) { $name = $k }
                $work.modes[$k].name = $name
                $work.modes[$k].freqMax = [int](Get-PresetValue $controls[$k].FreqCombo)
                Add-Content -Path $diag -Value ("  $k => name=$name freq=$($work.modes[$k].freqMax)") -Encoding UTF8
            }
            $work.autoIntervalSec = [int](Get-PresetValue $cmbAuto)
            $work.userIdleSec = [int](Get-PresetValue $cmbIdle)
            $work.toastStaySec = [double](Get-PresetValue $cmbToast)
            $work.manualUnlockMinutes = [int](Get-PresetValue $cmbUnlock)
            $work.gameIdleQuietMinutes = [int](Get-PresetValue $cmbQuiet)
            $work.gameExitMissCount = [int](Get-PresetValue $cmbExit)
            Save-Settings -Settings $work
            Add-Content -Path $diag -Value "  Save-Settings 已调用 -> $SettingsPath" -Encoding UTF8
            Add-Content -Path $diag -Value ("  文件存在? " + (Test-Path $SettingsPath)) -Encoding UTF8
            $Script:Settings = Read-Settings
            Refresh-ModeLabels
            if (Get-Command Refresh-MenuLabels -ErrorAction SilentlyContinue) { Refresh-MenuLabels }
            if ($Script:AutoTimer) { $Script:AutoTimer.Interval = $Script:Settings.autoIntervalSec * 1000 }
            # 立刻让 worker 应用一次新设置 (用当前模式)
            $current = Get-CurrentMode
            if ($current -in 'Idle','Balanced','Game') {
                Invoke-Worker -Mode $current
                Add-Content -Path $diag -Value "  Invoke-Worker -Mode $current (应用新频率)" -Encoding UTF8
            }
            $form.DialogResult = 'OK'
            $form.Close()
        } catch {
            try { Add-Content -Path $diag -Value ("  [异常] " + $_.ToString()) -Encoding UTF8 } catch {}
        }
    }.GetNewClosure())

    $btnCancel.Add_Click({
        $form.DialogResult = 'Cancel'
        $form.Close()
    }.GetNewClosure())

    $btnReset.Add_Click({
        $r = [System.Windows.Forms.MessageBox]::Show(
            "确定恢复所有设置为默认?`n`n会重置三个模式名称、频率上限和其他参数。",
            '确认', [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($r -eq 'Yes') {
            Remove-Item $SettingsPath -ErrorAction SilentlyContinue
            $Script:Settings = Read-Settings
            Refresh-ModeLabels
            if (Get-Command Refresh-MenuLabels -ErrorAction SilentlyContinue) { Refresh-MenuLabels }
            $form.DialogResult = 'OK'
            $form.Close()
        }
    }.GetNewClosure())

    [void]$form.ShowDialog()
}

. (Join-Path $ScriptDir 'PowerProfileModernUI.ps1')

# === 托盘图标 =================================================================
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Visible = $true

# === 右键菜单 =================================================================
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.ShowImageMargin = $true
$menu.Font=$Script:ModernFont
$menu.ImageScalingSize=New-Object Drawing.Size 16,16

$menuAuto = $menu.Items.Add('自动检测')
$menuAuto.Image = New-ColorDot ([System.Drawing.Color]::FromArgb(158, 158, 158))

[void]$menu.Items.Add('-')

$menuIdle = $menu.Items.Add('Idle')
$menuIdle.Image = New-ColorDot $ModeColors['Idle']

$menuBalanced = $menu.Items.Add('Balanced')
$menuBalanced.Image = New-ColorDot $ModeColors['Balanced']

$menuGame = $menu.Items.Add('Game')
$menuGame.Image = New-ColorDot $ModeColors['Game']

[void]$menu.Items.Add('-')

$menuStatus = $menu.Items.Add('当前: ...')
$menuStatus.Enabled = $false

$menuSettings = $menu.Items.Add('设置...')
$menuSettings.Image = New-ColorDot ([System.Drawing.Color]::FromArgb(96, 125, 139))

$menuMonitor=New-Object Windows.Forms.ToolStripMenuItem('运行状态...')
$menu.Items.Insert(0,$menuMonitor)
$menuWorkstation=$menu.Items.Add('工作时段附加省电')
$menuPauseWorkstation=$menu.Items.Add('暂停附加省电到今天结束')
$menuWorkstation.Add_Click({
    $options=Get-WorkstationOptions (Read-AtomicJson $SettingsPath)
    Save-WorkstationOptions (-not $options.enabled) $options.freqMax ''
    Invoke-WorkstationWorker -Restore
})
$menuPauseWorkstation.Add_Click({
    $options=Get-WorkstationOptions (Read-AtomicJson $SettingsPath)
    Save-WorkstationOptions $options.enabled $options.freqMax (Get-BeijingTime).Date.AddDays(1).ToString('s')
    Invoke-WorkstationWorker -Restore
})
$menu.Add_Opening({
    try{$options=Get-WorkstationOptions (Read-AtomicJson $SettingsPath);$menuWorkstation.Checked=$options.enabled}catch{}
})

$menuLog = $menu.Items.Add('打开日志')
$menuLog.Image = New-ColorDot ([System.Drawing.Color]::FromArgb(120, 144, 156))

$menuLegacy=$menu.Items.Add('切换为旧版')

[void]$menu.Items.Add('-')

$menuExit = $menu.Items.Add('退出')

$notify.ContextMenuStrip = $menu

# === 菜单文本动态刷新 (设置保存后调一次, 启动时调一次) ========================
function Refresh-MenuLabels {
    $idleFreq     = Format-Freq $Script:Settings.modes.Idle.freqMax
    $balancedFreq = Format-Freq $Script:Settings.modes.Balanced.freqMax
    $gameFreq     = Format-Freq $Script:Settings.modes.Game.freqMax
    $Script:MenuBaseLabels = @{
        Idle     = ("{0}    {1} 上限" -f $Script:Settings.modes.Idle.name, $idleFreq)
        Balanced = ("{0}    {1} 上限" -f $Script:Settings.modes.Balanced.name, $balancedFreq)
        Game     = ("{0}    {1}" -f $Script:Settings.modes.Game.name, $gameFreq)
    }
    # 不直接改菜单文本; Update-TrayIcon 会拼上 "● [当前]" 装饰
    if (Get-Command Update-TrayIcon -ErrorAction SilentlyContinue) { Update-TrayIcon }
}
Refresh-MenuLabels

# === 同步图标 + 菜单状态 ======================================================
function Update-TrayIcon {
    $mode = Get-CurrentMode
    $autoOn = Get-AutoEnabled
    $letter = if ($ModeLetters.ContainsKey($mode)) { $ModeLetters[$mode] } else { '?' }
    $color = if ($ModeColors.ContainsKey($mode)) { $ModeColors[$mode] } else { $ModeColors['Unknown'] }

    if ($Script:IconMode -ne $mode -or -not $notify.Icon) {
    if ($notify.Icon) {
        $oldIcon = $notify.Icon
        $notify.Icon = $null
        $oldIcon.Dispose()
    }
    $notify.Icon = [ProfileVisual]::CreateIcon($mode)
    $Script:IconMode=$mode
    }
    $autoLabel = if ($autoOn) { 'Auto' } else { '手动锁定' }
    $notify.Text = "PowerProfile: $mode ($autoLabel)"

    if ($autoOn) {
        $menuAuto.Font = $BoldFont
        $menuAuto.Text = '自动切换'
        $menuAuto.ForeColor = [System.Drawing.Color]::FromArgb(76, 175, 80)
    } else {
        $menuAuto.Font = $NormalFont
        $menuAuto.Text = '自动切换（关闭）'
        $menuAuto.ForeColor = [System.Drawing.SystemColors]::ControlText
    }
    $menuAuto.Checked=$autoOn

    $items = @{
        'Idle' = $menuIdle
        'Balanced' = $menuBalanced
        'Game' = $menuGame
    }
    $labels = $Script:MenuBaseLabels
    foreach ($k in $items.Keys) {
        if ($k -eq $mode) {
            $items[$k].Font = $BoldFont
            $items[$k].Text = $labels[$k]
            $items[$k].Checked=$true
            $items[$k].ForeColor = $ModeColors[$k]
        } else {
            $items[$k].Font = $NormalFont
            $items[$k].Text = $labels[$k]
            $items[$k].Checked=$false
            $items[$k].ForeColor = [System.Drawing.SystemColors]::ControlText
        }
    }

    $statusSuffix = if ($autoOn) { '(Auto)' } else { '(手动锁定)' }
    $menuStatus.Text = "当前: $mode $statusSuffix"
    $menuStatus.ForeColor = $color
}

# === 菜单点击 (全部 fire-and-forget, 不卡) ====================================
$menuAuto.Add_Click({
    $enable=-not (Get-AutoEnabled)
    Set-AutoEnabled $enable
    if($enable){Invoke-Worker -Mode 'Auto'}
    Update-TrayIcon
})
$menuIdle.Add_Click({
    Set-AutoEnabled $false
    Invoke-Worker -Mode 'Idle'
})
$menuBalanced.Add_Click({
    Set-AutoEnabled $false
    Invoke-Worker -Mode 'Balanced'
})
$menuGame.Add_Click({
    Set-AutoEnabled $false
    Invoke-Worker -Mode 'Game'
})
$menuSettings.Add_Click({ Show-ModernSettings })
$menuMonitor.Add_Click({ Open-ModernDashboard })
$menuLegacy.Add_Click({ Start-TrayVersionSwitch $ScriptDir 'Legacy' })
$menuLog.Add_Click({
    Open-ProfileLog
})
$menuExit.Add_Click({
    Invoke-WorkstationWorker -Restore -RestoreReason '用户退出托盘'
    if($Script:Dashboard -and -not $Script:Dashboard.IsDisposed){$Script:Dashboard.Close()}
    if($Script:LogViewer -and -not $Script:LogViewer.IsDisposed){$Script:LogViewer.Close()}
    Close-Toast
    $notify.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

# 左键单击: 打开并激活运行状态窗口
$notify.Add_MouseClick({
    param($s, $e)
    if ($e.Button -eq 'Left') {
        Open-ModernDashboard
    }
})

# 双击: 打开日志
$notify.Add_MouseDoubleClick({
    param($s, $e)
    if ($e.Button -eq 'Left') {
        Open-ProfileLog
    }
})

# === 状态文件监视 (UI 线程, 不卡) ============================================
# worker 异步跑完会写 current_mode.txt; 这个 timer 每 1.2s 看一眼,
# LastWriteTime 变化就刷新托盘 + 弹 toast.
$Script:LastSeenMode = Get-CurrentMode
$Script:LastSeenWriteTime = if (Test-Path $StatePath) {
    (Get-Item $StatePath).LastWriteTime
} else {
    [DateTime]::MinValue
}

$watchTimer = New-Object System.Windows.Forms.Timer
$watchTimer.Interval = 500
$watchTimer.Add_Tick({
    $request=Join-Path $ScriptDir 'tray_ui_request.txt'
    if(Test-Path $request){
        try{$action=(Get-Content $request -Raw -Encoding UTF8).Trim();Remove-Item -LiteralPath $request;if($action -eq 'Dashboard'){Open-ModernDashboard}elseif($action -eq 'Logs'){Show-ModernLogViewer}}catch{Write-ProfileEvent 'ui.request.failed' $_.Exception.Message 'ERROR'}
    }
    if (-not (Test-Path $StatePath)) { return }
    $writeTime = (Get-Item $StatePath).LastWriteTime
    if ($writeTime -le $Script:LastSeenWriteTime) { return }
    $oldMode = $Script:LastSeenMode
    $Script:LastSeenWriteTime = $writeTime
    $newMode = (Get-Content $StatePath -Raw -ErrorAction SilentlyContinue).Trim()
    try {
        $msg = "{0}  watch: file changed, old={1} new={2}" -f `
            (Get-Date -Format 'HH:mm:ss.fff'), $oldMode, $newMode
        Add-Content -Path (Join-Path $ScriptDir 'toast_debug.log') -Value $msg -Encoding UTF8
    } catch {}
    if ($newMode -and $newMode -ne $Script:LastSeenMode) {
        $Script:LastSeenMode = $newMode
        Update-TrayIcon
        Show-ModeToast -Mode $newMode
    } else {
        Update-TrayIcon
    }
})
$watchTimer.Start()

# Lightweight input watcher; expensive process/GPU sampling runs in a hidden worker every 10s.
$Script:WorkstationTimer=New-Object Windows.Forms.Timer
$Script:WorkstationTimer.Interval=1000
$Script:LastWorkstationCheck=[DateTime]::MinValue
$Script:WorkstationTimer.Add_Tick({
    try {
        $active=$false
        $wsPath=Join-Path $ScriptDir 'workstation_state.json'
        if(Test-Path $wsPath){$active=[bool](Read-AtomicJson $wsPath).active}
        $options=Get-WorkstationOptions (Read-AtomicJson $SettingsPath)
        $blocked=(-not $options.enabled -or -not $options.scheduleValid -or (Get-UserActivityIdleSeconds) -lt $options.awayMinutes*60 -or -not (Get-AutoEnabled) -or (Get-CurrentMode) -ne 'Idle')
        if($active -and $blocked){Invoke-WorkstationWorker -Restore -RestoreReason '输入或用户配置变化，退出附加省电';return}
        if(-not $active -and $blocked){return}
        if(([DateTime]::UtcNow-$Script:LastWorkstationCheck).TotalSeconds -ge 10){
            $Script:LastWorkstationCheck=[DateTime]::UtcNow
            Invoke-WorkstationWorker
        }
    } catch {Write-ProfileEvent 'workstation.timer.failed' $_.Exception.Message 'ERROR' @{path=$wsPath;stack=$_.ScriptStackTrace;position=$_.InvocationInfo.PositionMessage}}
})
$Script:WorkstationTimer.Start()

# === 自动检测定时器 (Auto 开启时, 间隔由 settings 控制) ======================
$Script:AutoTimer = New-Object System.Windows.Forms.Timer
$Script:AutoTimer.Interval = $Script:Settings.autoIntervalSec * 1000
$Script:AutoTimer.Add_Tick({
    $dbg = Join-Path $ScriptDir 'unlock_debug.log'
    $auto = Get-AutoEnabled
    $idleSec = Get-EffectiveIdle   # 全屏游戏时返回 0, 避免手柄玩游戏被误判 idle
    $activityIdleSec = Get-UserActivityIdleSeconds
    $quietGuard = Invoke-GameIdleQuietGuard -ActivityIdleSec $activityIdleSec -EffectiveIdleSec $idleSec
    $unlockSec = [int]$Script:Settings.manualUnlockMinutes * 60
    try {
        if ((Test-Path $dbg) -and (Get-Item $dbg).Length -gt 2MB) {
            Move-Item -LiteralPath $dbg -Destination "$dbg.1" -Force
        }
        $line = "{0}  auto={1}  idle={2}s  inputIdle={3}s  threshold={4}s  quietGuard={5}  willUnlock={6}" -f `
            (Get-Date -Format 'HH:mm:ss'), $auto, $idleSec, $activityIdleSec, $unlockSec, $quietGuard, `
            ((-not $auto) -and ($idleSec -ge $unlockSec))
        Add-Content -Path $dbg -Value $line -Encoding UTF8
    } catch {}

    # 抑制/延迟静音只代表“本轮不能由 idle 降档”，Auto 检测仍要继续刷新，
    # 否则游戏退出后检测状态会过期并让模式卡在 Game。只有已经发出 Idle 切换才结束本轮。
    if (-not (Test-ShouldContinueAutoDetection $quietGuard)) { return }

    if ($auto) {
        Invoke-Worker -Mode 'Auto' -ActivityIdleSec $activityIdleSec
    } else {
        # 手动锁定状态
        $currentMode = Get-CurrentMode

        # 关键: 手动锁定 Game 时仍跑 worker 自动检测.
        # 这样玩完游戏后 worker 会检测不到游戏 -> miss 累计 -> 自动切回 Idle.
        # 不恢复 Auto 开关 - 用户仍处于"手动锁定"语义, 但 Game→Idle 单向转换是用户期望.
        # 手动锁定 Idle/Balanced 不跑 worker - 那是用户明确"我现在就要低功耗"
        if ($currentMode -eq 'Game') {
            Invoke-Worker -Mode 'Auto' -ActivityIdleSec $activityIdleSec
        }

        # idle 逃生阀: 不管什么模式, idle 太久都恢复 Auto
        if ($idleSec -ge $unlockSec) {
            Set-AutoEnabled $true
            Invoke-Worker -Mode 'Auto' -ActivityIdleSec $activityIdleSec
            Update-TrayIcon
            $mins = [Math]::Round($idleSec / 60.0, 0)
            Show-ModeToast -Mode (Get-CurrentMode) -SubText "空闲 ${mins} 分钟 -> 自动恢复"
        }
    }
})
$Script:AutoTimer.Start()

# === 启动 =====================================================================
Remove-Item $LegacyIdleQuietStatePath -ErrorAction SilentlyContinue
if (Get-AutoEnabled) { Invoke-Worker -Mode 'Auto' -ActivityIdleSec (Get-UserActivityIdleSeconds) }
Update-TrayIcon

Write-AtomicJson (Join-Path $ScriptDir 'tray_ready.json') @{processId=$PID;version='Modern';observedAt=[DateTime]::UtcNow.ToString('o')}
Write-LifecycleLog '[READY] Modern tray UI initialized'

[System.Windows.Forms.Application]::Run()
