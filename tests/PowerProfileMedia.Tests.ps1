$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'PowerProfileDetection.ps1')
. (Join-Path $project 'PowerProfileDisplay.ps1')
. (Join-Path $project 'PowerProfileMedia.ps1')
function Assert($Name,$Value){if(-not $Value){throw $Name};Write-Host "PASS $Name"}
Assert 'playing muted video protects through media session' (Test-DisplayMediaPlaying @(4) 0)
Assert 'background music protects through audio fallback' (Test-DisplayMediaPlaying @() 0.01)
Assert 'any playing session protects even when another is paused' (Test-DisplayMediaPlaying @(5,4,3) 0)
foreach($status in @(0,1,2,3,5)) {Assert "non-playing status $status alone does not protect" (-not (Test-DisplayMediaPlaying @($status) 0))}
Assert 'unsupported audio is not interpreted as playing' (-not (Test-DisplayMediaPlaying @() -1))
$now=[DateTime]::UtcNow
foreach($minutes in @(15,20,30,60,90)){
    $idle=Get-MediaAwareDisplayIdle 86400 $true $now $now
    Assert "$minutes minute setting never blanks while playing" ((Get-DisplayAction $true $idle $minutes $false) -eq 'None')
    Assert 'playback starting during blackout wakes screen' ((Get-DisplayAction $true $idle $minutes $true) -eq 'Wake')
    $idle=Get-MediaAwareDisplayIdle 86400 $false $now $now.AddSeconds($minutes*60-1)
    Assert "$minutes minutes after pause cannot blank early" ((Get-DisplayAction $true $idle $minutes $false) -eq 'None')
    $idle=Get-MediaAwareDisplayIdle 86400 $false $now $now.AddSeconds($minutes*60)
    Assert "$minutes minutes after pause blanks normally" ((Get-DisplayAction $true $idle $minutes $false) -eq 'Off')
}
Assert 'keyboard input still resets the timer' ((Get-MediaAwareDisplayIdle 2 $false $now $now.AddHours(2)) -eq 2)
$root=Join-Path ([IO.Path]::GetTempPath()) ('ProfileMediaTests-'+[Guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($root)
try{
    $path=Join-Path $root 'media.playback_state.json'
    Assert 'missing monitor state defers blackout' (Read-DisplayMediaState $root 100 200 $now).Protected
    Write-AtomicJson $path @{ownerId=100;workerId=200;observedAt=$now.ToString('o');available=$true;playing=$false}
    Assert 'fresh paused state allows normal idle timer' (-not (Read-DisplayMediaState $root 100 200 $now).Protected)
    Assert 'stale state defers blackout for watchdog recovery' (Read-DisplayMediaState $root 100 200 $now.AddSeconds(11)).Protected
    Assert 'old tray state ignored after restart' (-not (Read-DisplayMediaState $root 101 200 $now).Fresh)
    Assert 'old worker state ignored after watchdog restart' (-not (Read-DisplayMediaState $root 100 201 $now).Fresh)
    Write-AtomicJson $path @{ownerId=100;workerId=200;observedAt=$now.ToString('o');available=$false;playing=$false}
    Assert 'failed playback probes defer blackout' (Read-DisplayMediaState $root 100 200 $now).Protected
}finally{
    $prefix=([IO.Path]::GetTempPath()).TrimEnd('\')+'\ProfileMediaTests-'
    if(-not ([IO.Path]::GetFullPath($root)).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe cleanup'}
    Remove-Item -LiteralPath $root -Recurse -Force
}
Add-Type -Path (Join-Path $project 'PowerProfileMedia.cs')
$peak=[ProfileMediaAudio]::Peak()
Assert 'native meter returns bounded peak or explicit unavailable' ($peak -eq -1 -or ($peak -ge 0 -and $peak -le 1))
