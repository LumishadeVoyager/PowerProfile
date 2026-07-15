# PowerProfileTray.ps1 — 托盘图标 + 自动检测 + 手动切换
# 后台常驻, 状态栏小图标显示当前模式, 右键切换/退出

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkerScript = Join-Path $ScriptDir 'PowerProfile.ps1'
$StatePath = Join-Path $ScriptDir 'current_mode.txt'
$AutoEnabledPath = Join-Path $ScriptDir 'auto_enabled.txt'
$LifecycleLog = Join-Path $ScriptDir 'tray_lifecycle.log'

function Write-LifecycleLog {
    param([string]$Msg)
    try {
        $line = "{0}  PID={1}  {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $PID, $Msg
        Add-Content -Path $LifecycleLog -Value $line -Encoding UTF8
    } catch {}
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

# === Win32 idle 检测 (手动锁定后 idle 超时自动恢复 Auto 用) ===================
# 注意: LASTINPUTINFO 不追踪 XInput/DInput 手柄. 用前台全屏 D3D 作为补充信号:
# 手柄玩游戏时 LASTINPUTINFO 会持续累加, 但前台窗口是全屏游戏 -> 视为活跃
if (-not ('Win32Idle' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Win32Idle {
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

# 返回"有效 idle 秒数": 如果前台是全屏游戏 (D3D 应用), 直接返回 0 (用户在用手柄玩)
function Get-EffectiveIdle {
    $rawIdle = [Win32Idle]::GetIdleSeconds()
    if ($rawIdle -le 30) { return $rawIdle }   # 短时间内不必判, 鼠标键盘最近用过

    # idle 较长才检查是不是全屏游戏 (避免每次 tick 都做模块枚举)
    $hwnd = [Win32Idle]::GetForegroundWindow()
    if ($hwnd -eq [IntPtr]::Zero) { return $rawIdle }
    $rect = New-Object Win32Idle+RECT
    [void][Win32Idle]::GetWindowRect($hwnd, [ref]$rect)
    $w = $rect.Right - $rect.Left
    $h = $rect.Bottom - $rect.Top
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $isFs = ($w -ge ($screen.Width - 2)) -and ($h -ge ($screen.Height - 2))
    if (-not $isFs) { return $rawIdle }

    $procId = 0
    [void][Win32Idle]::GetWindowThreadProcessId($hwnd, [ref]$procId)
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if (-not $proc) { return $rawIdle }
    try {
        $hasD3D = ($proc.Modules | Where-Object {
            $_.ModuleName -match '^(d3d9|d3d10|d3d11|d3d12|dxgi|vulkan-1|opengl32)\.dll$'
        } | Measure-Object).Count -gt 0
        if ($hasD3D) { return 0 }   # 全屏 + 3D = 玩游戏, 不算 idle
    } catch {}
    return $rawIdle
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
    Idle = [System.Drawing.Color]::FromArgb(76, 175, 80)      # 绿
    Balanced = [System.Drawing.Color]::FromArgb(33, 150, 243) # 蓝
    Game = [System.Drawing.Color]::FromArgb(244, 67, 54)      # 红
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

$NormalFont = New-Object System.Drawing.Font 'Segoe UI', 9, ([System.Drawing.FontStyle]::Regular)
$BoldFont = New-Object System.Drawing.Font 'Segoe UI', 9, ([System.Drawing.FontStyle]::Bold)

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

    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = 'None'
    $form.StartPosition = 'Manual'
    $form.ShowInTaskbar = $false
    $form.TopMost = $true
    $form.BackColor = [System.Drawing.Color]::FromArgb(28, 28, 30)
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
    $textLabel.Font = New-Object System.Drawing.Font 'Segoe UI', 11, ([System.Drawing.FontStyle]::Regular)
    $textLabel.ForeColor = [System.Drawing.Color]::White
    $textLabel.AutoSize = $false
    $textLabel.BackColor = [System.Drawing.Color]::Transparent

    if ($hasSub) {
        $textLabel.TextAlign = 'BottomLeft'
        $textLabel.Size = New-Object System.Drawing.Size 160, 28
        $textLabel.Location = New-Object System.Drawing.Point 50, 4

        $subLabel = New-Object System.Windows.Forms.Label
        $subLabel.Text = $SubText
        $subLabel.Font = New-Object System.Drawing.Font 'Segoe UI', 8, ([System.Drawing.FontStyle]::Regular)
        $subLabel.ForeColor = [System.Drawing.Color]::FromArgb(170, 170, 175)
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
        Game     = @{ name = '游戏'; freqMax = 4500; boost = 2; min = 90; max = 100 }
    }
    autoIntervalSec = 20
    userIdleSec = 90
    toastStaySec = 1.2
    manualUnlockMinutes = 10   # 手动锁定后 idle 这么久 -> 自动恢复 Auto
    gameExitMissCount = 6      # 连续 N 次无游戏才退出 Game 模式 (防过场/Alt-Tab 误切)
}

function Read-Settings {
    $s = @{
        modes = @{}
        autoIntervalSec = $DefaultSettings.autoIntervalSec
        userIdleSec = $DefaultSettings.userIdleSec
        toastStaySec = $DefaultSettings.toastStaySec
        manualUnlockMinutes = $DefaultSettings.manualUnlockMinutes
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
            $j = Get-Content $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
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
        gameExitMissCount = $Settings.gameExitMissCount
    }
    $json = $obj | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($SettingsPath, $json, (New-Object System.Text.UTF8Encoding $true))
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

# === 状态读取 + Worker 调用 ===================================================
function Get-CurrentMode {
    if (Test-Path $StatePath) {
        return (Get-Content $StatePath -Raw -ErrorAction SilentlyContinue).Trim()
    }
    return 'Unknown'
}

# 非阻塞调用 worker. 之前 -Wait 会卡 UI 2 秒采样时间; 现在 fire-and-forget,
# 状态变化由文件监视 timer 检测.
function Invoke-Worker {
    param([string]$Mode)
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $WorkerScript, '-Mode', $Mode) `
        -WindowStyle Hidden
}

# === Show-Settings: 拖滑块 + 改模式名 + 其他设置 ==============================
function Show-Settings {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'PowerProfile 设置'
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ClientSize = New-Object System.Drawing.Size 510, 768
    $form.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9
    $form.TopMost = $true

    $work = Read-Settings
    $controls = @{}

    $y = 12
    foreach ($modeKey in 'Idle','Balanced','Game') {
        $color = $ModeColors[$modeKey]
        $modeData = $work.modes[$modeKey]

        $grp = New-Object System.Windows.Forms.GroupBox
        $grp.Text = "  $modeKey 模式  "
        $grp.ForeColor = $color
        $grp.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 10, ([System.Drawing.FontStyle]::Bold)
        $grp.Location = New-Object System.Drawing.Point 12, $y
        $grp.Size = New-Object System.Drawing.Size 480, 150
        $form.Controls.Add($grp)

        $lblName = New-Object System.Windows.Forms.Label
        $lblName.Text = '模式名称:'
        $lblName.Location = New-Object System.Drawing.Point 14, 28
        $lblName.Size = New-Object System.Drawing.Size 72, 22
        $lblName.ForeColor = [System.Drawing.SystemColors]::ControlText
        $lblName.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9
        $grp.Controls.Add($lblName)

        $tbName = New-Object System.Windows.Forms.TextBox
        $tbName.Text = $modeData.name
        $tbName.Location = New-Object System.Drawing.Point 90, 26
        $tbName.Size = New-Object System.Drawing.Size 160, 22
        $tbName.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9
        $grp.Controls.Add($tbName)

        $lblFreq = New-Object System.Windows.Forms.Label
        $lblFreq.Text = '频率上限:'
        $lblFreq.Location = New-Object System.Drawing.Point 14, 66
        $lblFreq.Size = New-Object System.Drawing.Size 72, 22
        $lblFreq.ForeColor = [System.Drawing.SystemColors]::ControlText
        $lblFreq.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9
        $grp.Controls.Add($lblFreq)

        $lblFreqVal = New-Object System.Windows.Forms.Label
        $lblFreqVal.Text = Format-Freq $modeData.freqMax
        $lblFreqVal.Location = New-Object System.Drawing.Point 90, 62
        $lblFreqVal.Size = New-Object System.Drawing.Size 130, 28
        $lblFreqVal.Font = New-Object System.Drawing.Font 'Consolas', 13, ([System.Drawing.FontStyle]::Bold)
        $lblFreqVal.ForeColor = $color
        $grp.Controls.Add($lblFreqVal)

        $chkNoLimit = New-Object System.Windows.Forms.CheckBox
        $chkNoLimit.Text = '无上限 (满 Turbo)'
        $chkNoLimit.Location = New-Object System.Drawing.Point 235, 64
        $chkNoLimit.Size = New-Object System.Drawing.Size 145, 22
        $chkNoLimit.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9
        $chkNoLimit.Checked = ($modeData.freqMax -eq 0)
        $grp.Controls.Add($chkNoLimit)

        $slider = New-Object System.Windows.Forms.TrackBar
        $slider.Minimum = 8
        $slider.Maximum = 50
        $slider.TickFrequency = 2
        $slider.SmallChange = 1
        $slider.LargeChange = 5
        $slider.Location = New-Object System.Drawing.Point 14, 95
        $slider.Size = New-Object System.Drawing.Size 450, 45
        if ($modeData.freqMax -eq 0) {
            $slider.Value = 49
            $slider.Enabled = $false
        } else {
            $slider.Value = [Math]::Max(8, [Math]::Min(50, [int]($modeData.freqMax / 100)))
        }
        $grp.Controls.Add($slider)

        $slider.Add_ValueChanged({
            $val = $this.Value * 100
            foreach ($c in $this.Parent.Controls) {
                if ($c -is [System.Windows.Forms.Label] -and $c.Font.Name -eq 'Consolas') {
                    $c.Text = "{0:F1}GHz" -f ($val / 1000.0)
                }
            }
        })
        $chkNoLimit.Add_CheckedChanged({
            $isChk = $this.Checked
            $tb = $null; $lbl = $null
            foreach ($c in $this.Parent.Controls) {
                if ($c -is [System.Windows.Forms.TrackBar]) { $tb = $c }
                if ($c -is [System.Windows.Forms.Label] -and $c.Font.Name -eq 'Consolas') { $lbl = $c }
            }
            if ($tb) { $tb.Enabled = -not $isChk }
            if ($lbl) {
                if ($isChk) { $lbl.Text = '无上限' }
                else { $lbl.Text = "{0:F1}GHz" -f (($tb.Value * 100) / 1000.0) }
            }
        })

        $controls[$modeKey] = @{
            NameBox = $tbName
            Slider = $slider
            NoLimit = $chkNoLimit
        }
        $y += 160
    }

    $grpOther = New-Object System.Windows.Forms.GroupBox
    $grpOther.Text = '  其他设置  '
    $grpOther.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 10, ([System.Drawing.FontStyle]::Bold)
    $grpOther.Location = New-Object System.Drawing.Point 12, $y
    $grpOther.Size = New-Object System.Drawing.Size 480, 180
    $form.Controls.Add($grpOther)

    $lblAuto = New-Object System.Windows.Forms.Label
    $lblAuto.Text = '自动检测间隔 (秒):'
    $lblAuto.Location = New-Object System.Drawing.Point 14, 28
    $lblAuto.Size = New-Object System.Drawing.Size 170, 22
    $grpOther.Controls.Add($lblAuto)
    $numAuto = New-Object System.Windows.Forms.NumericUpDown
    $numAuto.Minimum = 5; $numAuto.Maximum = 120; $numAuto.Value = $work.autoIntervalSec
    $numAuto.Location = New-Object System.Drawing.Point 190, 26
    $numAuto.Size = New-Object System.Drawing.Size 80, 22
    $grpOther.Controls.Add($numAuto)

    $lblIdle = New-Object System.Windows.Forms.Label
    $lblIdle.Text = '人离开判定 (秒):'
    $lblIdle.Location = New-Object System.Drawing.Point 14, 58
    $lblIdle.Size = New-Object System.Drawing.Size 170, 22
    $grpOther.Controls.Add($lblIdle)
    $numIdle = New-Object System.Windows.Forms.NumericUpDown
    $numIdle.Minimum = 30; $numIdle.Maximum = 600; $numIdle.Value = $work.userIdleSec
    $numIdle.Location = New-Object System.Drawing.Point 190, 56
    $numIdle.Size = New-Object System.Drawing.Size 80, 22
    $grpOther.Controls.Add($numIdle)

    $lblToast = New-Object System.Windows.Forms.Label
    $lblToast.Text = 'Toast 停留时长 (秒):'
    $lblToast.Location = New-Object System.Drawing.Point 14, 88
    $lblToast.Size = New-Object System.Drawing.Size 170, 22
    $grpOther.Controls.Add($lblToast)
    $numToast = New-Object System.Windows.Forms.NumericUpDown
    $numToast.Minimum = [decimal]0.5; $numToast.Maximum = [decimal]5.0
    $numToast.DecimalPlaces = 1; $numToast.Increment = [decimal]0.1
    $numToast.Value = [decimal]$work.toastStaySec
    $numToast.Location = New-Object System.Drawing.Point 190, 86
    $numToast.Size = New-Object System.Drawing.Size 80, 22
    $grpOther.Controls.Add($numToast)

    # 手动锁定后多少分钟无操作 -> 恢复 Auto
    $lblUnlock = New-Object System.Windows.Forms.Label
    $lblUnlock.Text = '手动锁定空闲超时 (分):'
    $lblUnlock.Location = New-Object System.Drawing.Point 14, 118
    $lblUnlock.Size = New-Object System.Drawing.Size 170, 22
    $grpOther.Controls.Add($lblUnlock)
    $numUnlock = New-Object System.Windows.Forms.NumericUpDown
    $numUnlock.Minimum = 1; $numUnlock.Maximum = 120
    $numUnlock.Value = $work.manualUnlockMinutes
    $numUnlock.Location = New-Object System.Drawing.Point 190, 116
    $numUnlock.Size = New-Object System.Drawing.Size 80, 22
    $grpOther.Controls.Add($numUnlock)
    $lblUnlockHint = New-Object System.Windows.Forms.Label
    $lblUnlockHint.Text = '(手动模式 X 分钟无操作即自动恢复 Auto)'
    $lblUnlockHint.Location = New-Object System.Drawing.Point 280, 118
    $lblUnlockHint.Size = New-Object System.Drawing.Size 200, 22
    $lblUnlockHint.ForeColor = [System.Drawing.Color]::Gray
    $grpOther.Controls.Add($lblUnlockHint)

    # 游戏退出防抖: 连续 N 次无游戏才切回 Idle (防过场动画/Alt-Tab 反复横跳)
    $lblExit = New-Object System.Windows.Forms.Label
    $lblExit.Text = '游戏退出防抖 (次):'
    $lblExit.Location = New-Object System.Drawing.Point 14, 148
    $lblExit.Size = New-Object System.Drawing.Size 170, 22
    $grpOther.Controls.Add($lblExit)
    $numExit = New-Object System.Windows.Forms.NumericUpDown
    $numExit.Minimum = 2; $numExit.Maximum = 30
    $numExit.Value = $work.gameExitMissCount
    $numExit.Location = New-Object System.Drawing.Point 190, 146
    $numExit.Size = New-Object System.Drawing.Size 80, 22
    $grpOther.Controls.Add($numExit)
    $lblExitHint = New-Object System.Windows.Forms.Label
    $lblExitHint.Text = '(连续 N 次检测无游戏才切 Idle, 高=更稳定)'
    $lblExitHint.Location = New-Object System.Drawing.Point 280, 148
    $lblExitHint.Size = New-Object System.Drawing.Size 215, 22
    $lblExitHint.ForeColor = [System.Drawing.Color]::Gray
    $grpOther.Controls.Add($lblExitHint)

    $y += 190

    $btnReset = New-Object System.Windows.Forms.Button
    $btnReset.Text = '恢复默认'
    $btnReset.Location = New-Object System.Drawing.Point 12, $y
    $btnReset.Size = New-Object System.Drawing.Size 100, 32
    $form.Controls.Add($btnReset)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = '保存'
    $btnSave.Location = New-Object System.Drawing.Point 280, $y
    $btnSave.Size = New-Object System.Drawing.Size 100, 32
    $btnSave.BackColor = [System.Drawing.Color]::FromArgb(33, 150, 243)
    $btnSave.ForeColor = [System.Drawing.Color]::White
    $btnSave.FlatStyle = 'Flat'
    $form.Controls.Add($btnSave)
    $form.AcceptButton = $btnSave

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.Location = New-Object System.Drawing.Point 392, $y
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
                if ($controls[$k].NoLimit.Checked) {
                    $work.modes[$k].freqMax = 0
                } else {
                    $work.modes[$k].freqMax = $controls[$k].Slider.Value * 100
                }
                Add-Content -Path $diag -Value ("  $k => name=$name freq=$($work.modes[$k].freqMax)") -Encoding UTF8
            }
            $work.autoIntervalSec = [int]$numAuto.Value
            $work.userIdleSec = [int]$numIdle.Value
            $work.toastStaySec = [double]$numToast.Value
            $work.manualUnlockMinutes = [int]$numUnlock.Value
            $work.gameExitMissCount = [int]$numExit.Value
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

# === 托盘图标 =================================================================
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Visible = $true

# === 右键菜单 =================================================================
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.ShowImageMargin = $true

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

$menuLog = $menu.Items.Add('打开日志')
$menuLog.Image = New-ColorDot ([System.Drawing.Color]::FromArgb(120, 144, 156))

[void]$menu.Items.Add('-')

$menuExit = $menu.Items.Add('退出')

$notify.ContextMenuStrip = $menu

# === 菜单文本动态刷新 (设置保存后调一次, 启动时调一次) ========================
function Refresh-MenuLabels {
    $idleFreq     = Format-Freq $Script:Settings.modes.Idle.freqMax
    $balancedFreq = Format-Freq $Script:Settings.modes.Balanced.freqMax
    $gameFreq     = Format-Freq $Script:Settings.modes.Game.freqMax
    $Script:MenuBaseLabels = @{
        Idle     = ("{0} 模式 ({1})" -f $Script:Settings.modes.Idle.name, $idleFreq)
        Balanced = ("{0} 模式 ({1})" -f $Script:Settings.modes.Balanced.name, $balancedFreq)
        Game     = ("{0} 模式 ({1})" -f $Script:Settings.modes.Game.name, $gameFreq)
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

    if ($notify.Icon) {
        $oldIcon = $notify.Icon
        $notify.Icon = $null
        $oldIcon.Dispose()
    }
    $notify.Icon = New-LetterIcon -Letter $letter -BgColor $color
    $autoLabel = if ($autoOn) { 'Auto' } else { '手动锁定' }
    $notify.Text = "PowerProfile: $mode ($autoLabel)"

    if ($autoOn) {
        $menuAuto.Font = $BoldFont
        $menuAuto.Text = '√ 自动检测 (开启中)'
        $menuAuto.ForeColor = [System.Drawing.Color]::FromArgb(76, 175, 80)
    } else {
        $menuAuto.Font = $NormalFont
        $menuAuto.Text = '   自动检测 (关闭, 手动锁定)'
        $menuAuto.ForeColor = [System.Drawing.SystemColors]::ControlText
    }

    $items = @{
        'Idle' = $menuIdle
        'Balanced' = $menuBalanced
        'Game' = $menuGame
    }
    $labels = $Script:MenuBaseLabels
    foreach ($k in $items.Keys) {
        if ($k -eq $mode) {
            $items[$k].Font = $BoldFont
            $items[$k].Text = "● $($labels[$k])  [当前]"
            $items[$k].ForeColor = $ModeColors[$k]
        } else {
            $items[$k].Font = $NormalFont
            $items[$k].Text = "    $($labels[$k])"
            $items[$k].ForeColor = [System.Drawing.SystemColors]::ControlText
        }
    }

    $statusSuffix = if ($autoOn) { '(Auto)' } else { '(手动锁定)' }
    $menuStatus.Text = "当前: $mode $statusSuffix"
    $menuStatus.ForeColor = $color
}

# === 菜单点击 (全部 fire-and-forget, 不卡) ====================================
$menuAuto.Add_Click({
    Set-AutoEnabled $true
    Invoke-Worker -Mode 'Auto'
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
$menuSettings.Add_Click({ Show-Settings })
$menuLog.Add_Click({
    $logPath = Join-Path $ScriptDir 'profile.log'
    if (Test-Path $logPath) { Start-Process notepad.exe $logPath }
})
$menuExit.Add_Click({
    Close-Toast
    $notify.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

# 左键单击: 切换 Auto 开/关
$notify.Add_MouseClick({
    param($s, $e)
    if ($e.Button -eq 'Left') {
        $newState = -not (Get-AutoEnabled)
        Set-AutoEnabled $newState
        if ($newState) {
            Invoke-Worker -Mode 'Auto'
            Show-ModeToast -Mode (Get-CurrentMode) -SubText '自动检测 开启'
        } else {
            Show-ModeToast -Mode (Get-CurrentMode) -SubText '自动检测 关闭 (手动锁定)'
        }
        Update-TrayIcon
    }
})

# 双击: 打开日志
$notify.Add_MouseDoubleClick({
    param($s, $e)
    if ($e.Button -eq 'Left') {
        $logPath = Join-Path $ScriptDir 'profile.log'
        if (Test-Path $logPath) { Start-Process notepad.exe $logPath }
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

# === 自动检测定时器 (Auto 开启时, 间隔由 settings 控制) ======================
$Script:AutoTimer = New-Object System.Windows.Forms.Timer
$Script:AutoTimer.Interval = $Script:Settings.autoIntervalSec * 1000
$Script:AutoTimer.Add_Tick({
    $dbg = Join-Path $ScriptDir 'unlock_debug.log'
    $auto = Get-AutoEnabled
    $idleSec = Get-EffectiveIdle   # 全屏游戏时返回 0, 避免手柄玩游戏被误判 idle
    $unlockSec = [int]$Script:Settings.manualUnlockMinutes * 60
    try {
        $line = "{0}  auto={1}  idle={2}s  threshold={3}s  willUnlock={4}" -f `
            (Get-Date -Format 'HH:mm:ss'), $auto, $idleSec, $unlockSec, `
            ((-not $auto) -and ($idleSec -ge $unlockSec))
        Add-Content -Path $dbg -Value $line -Encoding UTF8
    } catch {}

    if ($auto) {
        Invoke-Worker -Mode 'Auto'
    } else {
        # 手动锁定状态
        $currentMode = Get-CurrentMode

        # 关键: 手动锁定 Game 时仍跑 worker 自动检测.
        # 这样玩完游戏后 worker 会检测不到游戏 -> miss 累计 -> 自动切回 Idle.
        # 不恢复 Auto 开关 - 用户仍处于"手动锁定"语义, 但 Game→Idle 单向转换是用户期望.
        # 手动锁定 Idle/Balanced 不跑 worker - 那是用户明确"我现在就要低功耗"
        if ($currentMode -eq 'Game') {
            Invoke-Worker -Mode 'Auto'
        }

        # idle 逃生阀: 不管什么模式, idle 太久都恢复 Auto
        if ($idleSec -ge $unlockSec) {
            Set-AutoEnabled $true
            Invoke-Worker -Mode 'Auto'
            Update-TrayIcon
            $mins = [Math]::Round($idleSec / 60.0, 0)
            Show-ModeToast -Mode (Get-CurrentMode) -SubText "空闲 ${mins} 分钟 -> 自动恢复"
        }
    }
})
$Script:AutoTimer.Start()

# === 启动 =====================================================================
if (Get-AutoEnabled) { Invoke-Worker -Mode 'Auto' }
Update-TrayIcon

[System.Windows.Forms.Application]::Run()
