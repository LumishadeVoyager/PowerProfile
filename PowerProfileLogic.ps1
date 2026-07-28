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
