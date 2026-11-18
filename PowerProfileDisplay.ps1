# Independent screen policy. Native calls only occur through explicit entry points.
function Initialize-DisplayNative {
    if(-not ('PowerProfileDisplay' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'PowerProfileDisplay.cs')}
}
function Get-DisplayOptions {
    param([string]$Root)
    $result=@{enabled=$true;idleMinutes=15}
    $path=Join-Path $Root 'display.settings.json'
    if(Test-Path -LiteralPath $path){
        $json=Read-AtomicJson $path
        if($json.enabled -is [bool]){$result.enabled=$json.enabled}
        if($null -ne $json.idleMinutes){
            $n=$json.idleMinutes -as [double]
            if($json.idleMinutes -is [bool] -or $null -eq $n -or $n -lt 1 -or $n -gt 240 -or $n -ne [Math]::Floor($n)){throw 'idleMinutes must be an integer from 1 to 240'}
            $result.idleMinutes=[int]$n
        }
    }
    return $result
}
function Get-DisplayAction {
    param([bool]$Enabled,[int]$IdleSeconds,[int]$Minutes,[bool]$Off)
    if(-not $Enabled -or $IdleSeconds -lt $Minutes*60){if($Off){return 'Wake'};return 'None'}
    if(-not $Off){return 'Off'};return 'Maintain'
}
function Invoke-DisplayPowerLock {
    param([scriptblock]$Action)
    $mutex=New-Object Threading.Mutex($false,'Global\PowerProfile_Worker');$locked=$false
    try {
        try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(-not $locked){return $false}
        & $Action
        return $true
    }finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
function Restore-DisplayPower {
    param([string]$Root,[switch]$OverlayOnly)
    $path=Join-Path $Root 'display_power_state.json'
    if(-not(Test-Path -LiteralPath $path)){return}
    Initialize-DisplayNative
    $state=Read-AtomicJson $path
    if(-not @($state.entries | Where-Object {-not $OverlayOnly -or $_.kind -eq 'Epp'}).Count){return}
    $remaining=@();$changed=@{}
    foreach($entry in @($state.entries)){
        if($OverlayOnly -and $entry.kind -ne 'Epp'){$remaining+=$entry;continue}
        # Do not overwrite a newer manual change from Windows or another tool.
        $actual=[PowerProfileDisplay]::Read($entry.scheme,$entry.group,$entry.key,$entry.dc)
        if($actual -eq $entry.applied){
            [PowerProfileDisplay]::Write($entry.scheme,$entry.group,$entry.key,$entry.dc,$entry.original)
            if([PowerProfileDisplay]::Read($entry.scheme,$entry.group,$entry.key,$entry.dc) -ne $entry.original){throw 'Restored display power value did not pass readback'}
            $changed[$entry.scheme]=$true
        }
    }
    $active=[PowerProfileDisplay]::Scheme()
    if($changed.ContainsKey($active)){[PowerProfileDisplay]::Activate($active)}
    Write-AtomicJson $path @{entries=@($remaining)}
}
function Set-DisplayPower {
    param([string]$Root,[ValidateSet('Awake','Epp')][string]$Kind)
    Initialize-DisplayNative
    $path=Join-Path $Root 'display_power_state.json'
    $state=if(Test-Path -LiteralPath $path){Read-AtomicJson $path}else{$null}
    $entries=@($state.entries | Where-Object {$null -ne $_})
    $scheme=[PowerProfileDisplay]::Scheme()
    # Only the two EPP preferences are changed for CPU savings. No hard CPU/GPU caps.
    $targets=if($Kind -eq 'Epp'){
        @(@('54533251-82be-4824-96c1-47b60b740d00','36687f9e-e3a5-4dbf-b1dc-15eb381c6863'),@('54533251-82be-4824-96c1-47b60b740d00','36687f9e-e3a5-4dbf-b1dc-15eb381c6864'))
    }else{
        @(@('238c9fa8-0aad-41ed-83f4-97be242c8f20','29f6c1db-86da-48c5-9fdb-f2b67b1f44da'),@('238c9fa8-0aad-41ed-83f4-97be242c8f20','9d7815a6-7ee4-497e-8888-515a05f02364'),@('7516b95f-f776-4464-8c53-06167f40cc99','3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'))
    }
    $changed=$false
    foreach($target in $targets){foreach($dc in @($false,$true)){
        if(@($entries | Where-Object {$_.scheme -eq $scheme -and $_.key -eq $target[1] -and $_.dc -eq $dc}).Count){continue}
        try{$original=[PowerProfileDisplay]::Read($scheme,$target[0],$target[1],$dc)}catch{if($Kind -eq 'Epp'){continue};throw}
        $applied=if($Kind -eq 'Epp'){[Math]::Min(100,$original+10)}else{0}
        if($applied -eq $original){continue}
        $entries+=@{scheme=$scheme;group=$target[0];key=$target[1];dc=$dc;original=$original;applied=$applied;kind=$Kind}
        # Durable recovery journal precedes every mutation.
        Write-AtomicJson $path @{entries=@($entries)}
        [PowerProfileDisplay]::Write($scheme,$target[0],$target[1],$dc,$applied)
        if([PowerProfileDisplay]::Read($scheme,$target[0],$target[1],$dc) -ne $applied){throw 'Display power readback failed'}
        $changed=$true
    }}
    if($changed){[PowerProfileDisplay]::Activate($scheme)}
}
