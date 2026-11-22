param([Parameter(Mandatory=$true)][int]$OwnerId,[Parameter(Mandatory=$true)][long]$OwnerStartedTicks)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'PowerProfileDetection.ps1')
. (Join-Path $PSScriptRoot 'PowerProfileMedia.ps1')
Add-Type -Path (Join-Path $PSScriptRoot 'PowerProfileMedia.cs')
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$manager=$null
while($true){
    try{$owner=Get-Process -Id $OwnerId -ErrorAction Stop;if($owner.StartTime.ToUniversalTime().Ticks -ne $OwnerStartedTicks){break}}catch{break}
    $playing=$false;$available=$false;$statuses=@()
    try{
        if(-not $manager){
            $type=[Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager,Windows.Media.Control,ContentType=WindowsRuntime]
            $method=[System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {$_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetGenericArguments().Count -eq 1 -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name.StartsWith('IAsyncOperation')} | Select-Object -First 1
            $task=$method.MakeGenericMethod($type).Invoke($null,@($type::RequestAsync()))
            if(-not $task.Wait(3000)){throw 'Media session request timed out'}
            $manager=$task.Result
        }
        foreach($session in $manager.GetSessions()){$statuses+=([int]$session.GetPlaybackInfo().PlaybackStatus)}
        $available=$true
    }catch{$manager=$null}
    $peak=[ProfileMediaAudio]::Peak()
    if($peak -ge 0){$available=$true}
    $playing=Test-DisplayMediaPlaying $statuses $peak
    # No titles, artist names, browser URLs or media contents are collected.
    Write-AtomicJson (Join-Path $PSScriptRoot 'media.playback_state.json') @{ownerId=$OwnerId;workerId=$PID;observedAt=[DateTime]::UtcNow.ToString('o');playing=$playing;available=$available}
    Start-Sleep -Seconds 2
}
