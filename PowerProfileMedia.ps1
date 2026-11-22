function Get-MediaAwareDisplayIdle {
    param([int]$InputIdleSeconds,[bool]$Protected,[DateTime]$LastMediaActivity,[DateTime]$Now=[DateTime]::UtcNow)
    if($Protected){return 0}
    $since=[Math]::Max(0,[Math]::Floor(($Now.ToUniversalTime()-$LastMediaActivity.ToUniversalTime()).TotalSeconds))
    return [int][Math]::Min($InputIdleSeconds,$since)
}
function Read-DisplayMediaState {
    param([string]$Root,[int]$OwnerId,[int]$WorkerId,[DateTime]$Now=[DateTime]::UtcNow)
    try {
        $state=Read-AtomicJson (Join-Path $Root 'media.playback_state.json')
        $age=($Now.ToUniversalTime()-([DateTime]$state.observedAt).ToUniversalTime()).TotalSeconds
        if($state.ownerId -eq $OwnerId -and $state.workerId -eq $WorkerId -and $age -ge 0 -and $age -le 10){
            return @{Protected=([bool]$state.playing -or -not [bool]$state.available);Fresh=$true}
        }
    }catch{}
    return @{Protected=$true;Fresh=$false}
}
function Test-DisplayMediaPlaying {
    param([int[]]$SessionStatuses,[float]$AudioPeak)
    return ($SessionStatuses -contains 4 -or $AudioPeak -gt 0.00001)
}
function Stop-DisplayMediaMonitor {
    if($Script:DisplayMediaWorker){try{if(-not $Script:DisplayMediaWorker.HasExited){$Script:DisplayMediaWorker.Kill()}}finally{$Script:DisplayMediaWorker.Dispose();$Script:DisplayMediaWorker=$null}}
}
function Get-DisplayMediaProtection {
    param([string]$Root)
    $state=$null
    if($Script:DisplayMediaWorker -and -not $Script:DisplayMediaWorker.HasExited){
        $state=Read-DisplayMediaState $Root $PID $Script:DisplayMediaWorker.Id
        if($state.Fresh -or ([DateTime]::UtcNow-$Script:DisplayMediaStarted).TotalSeconds -lt 15){return $state}
    }
    Stop-DisplayMediaMonitor
    $Script:DisplayMediaStarted=[DateTime]::UtcNow
    $started=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
    $Script:DisplayMediaWorker=Start-HiddenPowerShell @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f (Join-Path $Root 'PowerProfileMediaWorker.ps1')),'-OwnerId',$PID,'-OwnerStartedTicks',$started)
    return @{Protected=$true;Fresh=$false}
}
