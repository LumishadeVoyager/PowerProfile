function Get-GameIdleQuietDecision {
    param(
        [string]$CurrentMode,
        [int]$ActivityIdleSec,
        [int]$ThresholdSec,
        [int]$EffectiveIdleSec,
        $Detection
    )

    if ($CurrentMode -ne 'Game' -or $ThresholdSec -le 0 -or $ActivityIdleSec -lt $ThresholdSec) {
        return 'None'
    }

    # Full-screen 3D is an immediate process signal, including native-HID DualSense games.
    if ($EffectiveIdleSec -eq 0) { return 'SuppressedForeground3D' }

    if (-not $Detection -or -not $Detection.Fresh) { return 'DeferredStaleDetection' }
    if ($Detection.IsGame) { return "SuppressedGame:$($Detection.Source)" }

    return 'ForceNoGameSignal'
}

function Test-ShouldContinueAutoDetection {
    param([string]$IdleQuietDecision)
    return ($IdleQuietDecision -ne 'ForcedNoGameSignal')
}

# These decisions are independent of Windows APIs so recorded scenarios can be replayed.
function Test-PathUnderRoot {
    param([string]$Path, [string]$Root)
    if (-not $Path -or -not $Root) { return $false }
    try {
        $full = [IO.Path]::GetFullPath($Path)
        $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        return $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Get-GameSignalDecision {
    param($Candidate, [int]$BackgroundGraceSec = 120)
    if ($Candidate.Excluded) { return 'Excluded' }
    # A session must match PID + creation time; a recycled PID is never confirmation.
    if ($Candidate.SameSession) {
        if ($Candidate.Foreground) { return 'ConfirmedForeground' }
        if ($Candidate.SecondsSinceForeground -ge 0 -and $Candidate.SecondsSinceForeground -le $BackgroundGraceSec) {
            return 'BackgroundGrace'
        }
        if ($Candidate.Gpu -ge 3 -or $Candidate.Cpu -ge 20) { return 'BackgroundGameLoad' }
        return 'BackgroundInactive'
    }
    if (-not $Candidate.Foreground) { return 'NoForegroundEvidence' }
    if ($Candidate.ExplicitGame) { return 'ConfiguredGame' }
    # Library path + the app's own activity supports windowed/2D/protected games.
    # Never borrow the wallpaper's GPU load or another process's CPU load.
    if ($Candidate.InLibrary -and ($Candidate.IsD3D -or $Candidate.Gpu -ge 1 -or $Candidate.Cpu -ge 20)) {
        return 'LibraryGame'
    }
    if ($Candidate.IsFullscreen -and $Candidate.IsD3D -and ($Candidate.Gpu -ge 5 -or $Candidate.Cpu -ge 40)) {
        return 'Foreground3DLoad'
    }
    return 'NoGameEvidence'
}

function Test-PositiveGameSignal {
    param([string]$Signal)
    return $Signal -in @('ConfiguredGame', 'LibraryGame', 'Foreground3DLoad', 'ConfirmedForeground', 'BackgroundGrace', 'BackgroundGameLoad')
}

function Get-AutoModeTransition {
    param([string]$CurrentMode, $Detection, [int]$MissCount, [int]$ExitMissCount)
    if ($Detection.ForceIdle) { return @{ Mode = 'Idle'; MissCount = 0 } }
    if ($Detection.IsGame) { return @{ Mode = 'Game'; MissCount = 0 } }
    if ($Detection.Defer) { return @{ Mode = $CurrentMode; MissCount = $MissCount } }
    if ($CurrentMode -eq 'Game') {
        $nextMiss = [Math]::Max(0, $MissCount) + 1
        if ($nextMiss -lt [Math]::Max(1, $ExitMissCount)) { return @{ Mode = 'Game'; MissCount = $nextMiss } }
        return @{ Mode = 'Idle'; MissCount = 0 }
    }
    return @{ Mode = $CurrentMode; MissCount = 0 }
}



function Get-WorkloadGpu {
    param($Samples,$ProcessNames)
    $engines=@{}
    foreach($sample in $Samples){
        if($sample.Path -notmatch 'pid_(\d+)'){continue};$processId=[int]$matches[1]
        if(-not $ProcessNames.ContainsKey($processId)){continue}
        if($ProcessNames[$processId] -in @('wallpaper32','wallpaper64','wallpaperui','wallpaperui32','wallpaperui64','dwm','explorer','shellexperiencehost','startmenuexperiencehost','lockapp','logonui')){continue}
        $value=[double]$sample.CookedValue
        if($null -ne $sample.Status -and $sample.Status -ne 0){continue}
        if([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -le 0){continue}
        if($sample.Path -match '(luid_.+?engtype_[^)\\]+)'){$engine=$matches[1]}else{$engine='other'}
        if(-not $engines.ContainsKey($engine)){$engines[$engine]=0.0};$engines[$engine]+=$value
    }
    if(-not $engines.Count){return 0.0}
    return [Math]::Min(100.0,($engines.Values | Measure-Object -Maximum).Maximum)
}
