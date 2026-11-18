param([ValidateSet('Modern','Legacy','Selected')][string]$Version='Selected')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'PowerProfileVersion.ps1')
. (Join-Path $PSScriptRoot 'PowerProfileDetection.ps1')
# An already-authorized highest-privilege login task can service a one-shot version switch.
# The request accepts only the two fixed versions, never a command or arbitrary path.
$requestPath=Join-Path $PSScriptRoot 'tray_switch_request.txt'
if(Test-Path $requestPath){
    $requested=(Get-Content $requestPath -Raw -ErrorAction Stop).Trim()
    Remove-Item -LiteralPath $requestPath
    if($requested -in @('Modern','Legacy')){Start-TrayVersionSwitch $PSScriptRoot $requested;return}
}
$startupMutex=New-Object Threading.Mutex($false,'Global\PowerProfile_Startup')
$startupLocked=$false
try {
try{$startupLocked=$startupMutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$startupLocked=$true}
if(-not $startupLocked){return}
if ($Version -eq 'Selected') { $Version=Get-SelectedTrayVersion $PSScriptRoot }
if(Test-Path (Join-Path $PSScriptRoot 'PowerProfileUpdate.ps1')){
    . (Join-Path $PSScriptRoot 'PowerProfileUpdate.ps1')
    try {if($Version -eq 'Modern'){Install-ProfilePendingUpdate $PSScriptRoot}}
    catch {Add-Content (Join-Path $PSScriptRoot 'tray_lifecycle.log') -Value "[UPDATE ERROR] $_" -Encoding UTF8}
}
if ($Version -eq 'Legacy') {
    $statePath=Join-Path $PSScriptRoot 'workstation_state.json'
    if((Test-Path $statePath) -and (Read-AtomicJson $statePath).active){Start-TrayVersionSwitch $PSScriptRoot 'Legacy';return}
    Initialize-LegacyConfiguration $PSScriptRoot
}
$tray=Get-TrayVersionPath $PSScriptRoot $Version
if (-not (Test-Path $tray)) { throw "Missing tray: $tray" }
. (Join-Path $PSScriptRoot 'PowerProfileBand.ps1')
Initialize-ProfileBandSync $PSScriptRoot
try { & $tray }
catch {
    Add-Content (Join-Path $PSScriptRoot 'tray_lifecycle.log') -Value "[START ERROR] $Version $_" -Encoding UTF8
    if($Version -eq 'Modern'){Start-TrayVersionSwitch $PSScriptRoot 'Legacy'}
    throw
}
} finally {if(Get-Command Stop-ProfileBandSync -ErrorAction SilentlyContinue){Stop-ProfileBandSync};if($startupLocked){$startupMutex.ReleaseMutex()};$startupMutex.Dispose()}
