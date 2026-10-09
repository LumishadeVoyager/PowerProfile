function Get-SelectedTrayVersion {
    param([string]$Root)
    $path=Join-Path $Root 'tray_version.txt'
    $value=if (Test-Path $path) { (Get-Content $path -Raw -ErrorAction SilentlyContinue).Trim() } else { 'Modern' }
    if ($value -notin @('Modern','Legacy')) { return 'Modern' }
    return $value
}
function Get-TrayVersionPath {
    param([string]$Root,[ValidateSet('Modern','Legacy')][string]$Version)
    if ($Version -eq 'Legacy') { return Join-Path $Root 'legacy\PowerProfileTray.ps1' }
    return Join-Path $Root 'PowerProfileTray.ps1'
}
function Initialize-LegacyConfiguration {
    param([string]$Root)
    # Populate once on a new installation. Never overwrite the rollback configuration.
    foreach($name in @('settings.json','current_mode.txt','auto_enabled.txt','game_session_state.json','game_miss_count.txt','boot_guard_idle_applied.txt','boot_guard_released.txt')) {
        $source=Join-Path $Root $name;$destination=Join-Path $Root ('legacy\'+$name)
        if((Test-Path $source) -and -not (Test-Path $destination)){Copy-Item -LiteralPath $source -Destination $destination}
    }
}
function Start-TrayVersionSwitch {
    param([string]$Root,[ValidateSet('Modern','Legacy')][string]$Version)
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $start.Arguments='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Version {1}' -f (Join-Path $Root '_restart_tray.ps1'),$Version
    $start.UseShellExecute=$true; $start.WindowStyle='Hidden'
    [void][Diagnostics.Process]::Start($start)
}
