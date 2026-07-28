$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'PowerProfileLogic.ps1')

function Assert-Equal {
    param([string]$Name, $Actual, $Expected)
    if ($Actual -ne $Expected) {
        throw "$Name failed: expected [$Expected], got [$Actual]"
    }
    Write-Host "PASS $Name"
}

$gameDetection = @{ Fresh = $true; IsGame = $true; Source = 'ConfirmedGameProcess' }
$noGameDetection = @{ Fresh = $true; IsGame = $false; Source = 'NoGameSignal' }
$staleDetection = @{ Fresh = $false; IsGame = $false; Source = 'NoGameSignal' }

Assert-Equal 'below threshold does nothing' `
    (Get-GameIdleQuietDecision 'Game' 599 600 599 $noGameDetection) 'None'
Assert-Equal 'non-Game mode does nothing' `
    (Get-GameIdleQuietDecision 'Idle' 900 600 900 $noGameDetection) 'None'
Assert-Equal 'fullscreen 3D outranks idle timeout' `
    (Get-GameIdleQuietDecision 'Game' 900 600 0 $noGameDetection) 'SuppressedForeground3D'
Assert-Equal 'confirmed game detection outranks idle timeout' `
    (Get-GameIdleQuietDecision 'Game' 900 600 900 $gameDetection) 'SuppressedGame:ConfirmedGameProcess'
Assert-Equal 'stale detection cannot force quiet' `
    (Get-GameIdleQuietDecision 'Game' 900 600 900 $staleDetection) 'DeferredStaleDetection'
Assert-Equal 'fresh no-game signal permits quiet' `
    (Get-GameIdleQuietDecision 'Game' 900 600 900 $noGameDetection) 'ForceNoGameSignal'
Assert-Equal 'suppressed quiet keeps Auto detection running' `
    (Test-ShouldContinueAutoDetection 'SuppressedForeground3D') $true
Assert-Equal 'stale detection keeps Auto refresh running' `
    (Test-ShouldContinueAutoDetection 'DeferredStaleDetection') $true
Assert-Equal 'issued Idle switch ends current Auto tick' `
    (Test-ShouldContinueAutoDetection 'ForcedNoGameSignal') $false

Write-Host 'All PowerProfile logic tests passed.'
