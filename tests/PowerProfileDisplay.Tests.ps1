$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'PowerProfileDetection.ps1')
. (Join-Path $project 'PowerProfileDisplay.ps1')
# Exercise the real journal/apply/restore functions against an in-memory power store.
Add-Type @'
using System;
using System.Collections.Generic;
public class PowerProfileDisplay {
    public static Dictionary<string,uint> Values=new Dictionary<string,uint>();
    public static string Plan="8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c";
    public static bool FailWrite=false;
    public static string Scheme(){return Plan;}
    static string Id(string p,string k,bool dc){return p+k+dc;}
    public static uint Read(string p,string g,string k,bool dc){string id=Id(p,k,dc);return Values.ContainsKey(id)?Values[id]:(k.StartsWith("36687")?20u:600u);}
    public static void Write(string p,string g,string k,bool dc,uint value){if(FailWrite)throw new Exception("fixture failure");Values[Id(p,k,dc)]=value;}
    public static void Activate(string p){if(p!=Plan)throw new Exception("Unexpected plan switch");}
}
'@
function Assert($Name,$Condition){if(-not $Condition){throw $Name};Write-Host "PASS $Name"}
$root=Join-Path ([IO.Path]::GetTempPath()) ('PowerProfileDisplayTest-'+[Guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($root)
try {
    Assert 'enabled by default with exact 15 minute threshold' ((Get-DisplayOptions $root).enabled -and (Get-DisplayOptions $root).idleMinutes -eq 15)
    Assert '899 seconds never blanks' ((Get-DisplayAction $true 899 15 $false) -eq 'None')
    Assert '900 seconds blanks' ((Get-DisplayAction $true 900 15 $false) -eq 'Off')
    foreach($minutes in @(15,20,30,60,90)){
        Write-AtomicJson (Join-Path $root 'display.settings.json') @{enabled=$true;idleMinutes=$minutes}
        Assert "$minutes minute setting round trips" ((Get-DisplayOptions $root).idleMinutes -eq $minutes)
        Assert "$minutes minutes cannot blank early" ((Get-DisplayAction $true ($minutes*60-1) $minutes $false) -eq 'None')
        Assert "$minutes minutes blanks at threshold" ((Get-DisplayAction $true ($minutes*60) $minutes $false) -eq 'Off')
    }
    Assert 'load/fullscreen is independent of inactivity' ((Get-DisplayAction $true 1500 15 $false) -eq 'Off')
    Assert 'input wakes' ((Get-DisplayAction $true 0 15 $true) -eq 'Wake')
    Assert 'disable wakes' ((Get-DisplayAction $false 1500 15 $true) -eq 'Wake')
    Assert 'off remains off' ((Get-DisplayAction $true 901 15 $true) -eq 'Maintain')
    Set-DisplayPower $root Awake
    $state=Read-AtomicJson (Join-Path $root 'display_power_state.json')
    Assert 'journals AC/DC display, sleep and hibernate timeouts' ($state.entries.Count -eq 6 -and @($state.entries | Where-Object {$_.applied -ne 0}).Count -eq 0)
    Set-DisplayPower $root Epp
    $state=Read-AtomicJson (Join-Path $root 'display_power_state.json')
    Assert 'both CPU classes AC/DC only get ten EPP points' (@($state.entries | Where-Object {$_.kind -eq 'Epp' -and $_.original -eq 20 -and $_.applied -eq 30}).Count -eq 4)
    Set-DisplayPower $root Epp
    Assert 'repeated tick cannot compound throttling' ((Read-AtomicJson (Join-Path $root 'display_power_state.json')).entries.Count -eq 10)
    Restore-DisplayPower $root -OverlayOnly
    Assert 'input restores EPP but keeps system awake' ((Read-AtomicJson (Join-Path $root 'display_power_state.json')).entries.Count -eq 6)
    Set-DisplayPower $root Epp
    $e=(Read-AtomicJson (Join-Path $root 'display_power_state.json')).entries | Where-Object {$_.kind -eq 'Epp'} | Select-Object -First 1
    [PowerProfileDisplay]::Write($e.scheme,$e.group,$e.key,$e.dc,7)
    Restore-DisplayPower $root
    Assert 'restore preserves newer external preference' ([PowerProfileDisplay]::Read($e.scheme,$e.group,$e.key,$e.dc) -eq 7)
    Assert 'exit clears recovery journal' ((Read-AtomicJson (Join-Path $root 'display_power_state.json')).entries.Count -eq 0)
    [PowerProfileDisplay]::FailWrite=$true
    try{Set-DisplayPower $root Awake;throw 'Expected write failure'}catch{Assert 'failed write retains recovery record' ((Read-AtomicJson (Join-Path $root 'display_power_state.json')).entries.Count -eq 1)}
    [PowerProfileDisplay]::FailWrite=$false
    Restore-DisplayPower $root
    Assert 'interrupted apply can recover' ((Read-AtomicJson (Join-Path $root 'display_power_state.json')).entries.Count -eq 0)
    Write-AtomicJson (Join-Path $root 'display.settings.json') @{enabled=$false;idleMinutes=15}
    Assert 'toggle persists independently from mode settings' (-not (Get-DisplayOptions $root).enabled)
    Write-AtomicJson (Join-Path $root 'display.settings.json') @{idleMinutes=1.5}
    $invalid=$false;try{Get-DisplayOptions $root}catch{$invalid=$true}
    Assert 'invalid timeout rejected' $invalid
}finally{
    if(-not ([IO.Path]::GetFullPath($root)).StartsWith(([IO.Path]::GetTempPath()).TrimEnd('\')+'\PowerProfileDisplayTest-',[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected test directory'}
    Remove-Item -LiteralPath $root -Recurse -Force
}
