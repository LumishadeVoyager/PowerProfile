param([ValidateSet('Modern','Legacy','Selected')][string]$Version='Selected')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'PowerProfileVersion.ps1')
# An already-authorized highest-privilege login task can service a one-shot version switch.
# The request accepts only the two fixed versions, never a command or arbitrary path.
$requestPath=Join-Path $PSScriptRoot 'tray_switch_request.txt'
if(Test-Path $requestPath){
    $requested=(Get-Content $requestPath -Raw -ErrorAction Stop).Trim()
    Remove-Item -LiteralPath $requestPath
    if($requested -in @('Modern','Legacy')){Start-TrayVersionSwitch $PSScriptRoot $requested;return}
}
if ($Version -eq 'Selected') { $Version=Get-SelectedTrayVersion $PSScriptRoot }
if ($Version -eq 'Legacy') {
    $statePath=Join-Path $PSScriptRoot 'workstation_state.json'
    if((Test-Path $statePath) -and (Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json).active){Start-TrayVersionSwitch $PSScriptRoot 'Legacy';return}
    Initialize-LegacyConfiguration $PSScriptRoot
}
$tray=Get-TrayVersionPath $PSScriptRoot $Version
if (-not (Test-Path $tray)) { throw "Missing tray: $tray" }
try { & $tray }
catch {
    Add-Content (Join-Path $PSScriptRoot 'tray_lifecycle.log') -Value "[START ERROR] $Version $_" -Encoding UTF8
    if($Version -eq 'Modern'){Start-TrayVersionSwitch $PSScriptRoot 'Legacy'}
    throw
}
