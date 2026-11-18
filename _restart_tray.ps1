param([ValidateSet('Modern','Legacy','Selected')][string]$Version='Selected')
$ErrorActionPreference='Stop'
$isAdmin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    [void](Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath),'-Version',$Version))
    return
}
. (Join-Path $PSScriptRoot 'PowerProfileVersion.ps1')
. (Join-Path $PSScriptRoot 'PowerProfileDetection.ps1')
. (Join-Path $PSScriptRoot 'PowerProfileLog.ps1')
. (Join-Path $PSScriptRoot 'PowerProfileWorkstation.ps1')
. (Join-Path $PSScriptRoot 'PowerProfileDisplay.ps1')
Initialize-ProfileLogging $PSScriptRoot 'version-switch'
$oldVersion=Get-SelectedTrayVersion $PSScriptRoot
if ($Version -eq 'Selected') { $Version=$oldVersion }
$targets=@('PowerProfileTray.ps1','Start-PowerProfile.ps1','Start-Tray.vbs','legacy\PowerProfileTray.ps1') | ForEach-Object { Join-Path $PSScriptRoot $_ }
function Test-InstallationProcess {
    param($Process)
    if ($Process.ProcessId -eq $PID -or -not $Process.CommandLine) { return $false }
    foreach ($target in $targets) {
        $pattern='(?i)(?:-File\s+"?'+[regex]::Escape($target)+'"?(?:\s|$))'
        if ($Process.Name -eq 'wscript.exe') { $pattern='(?i)\s+"?'+[regex]::Escape($target)+'"?(?:\s|$)' }
        if ($Process.CommandLine -match $pattern) { return $true }
    }
    return $false
}
function Start-CheckedTray {
    param([string]$SelectedVersion)
    $ready=Join-Path $PSScriptRoot 'tray_ready.json'
    Remove-Item -LiteralPath $ready -ErrorAction SilentlyContinue
    $p=Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f (Join-Path $PSScriptRoot 'Start-PowerProfile.ps1')),'-Version',$SelectedVersion)
    $deadline=[DateTime]::UtcNow.AddSeconds(20)
    while ([DateTime]::UtcNow -lt $deadline -and -not $p.HasExited) {
        if (Test-Path $ready) {
            try { $j=Read-AtomicJson $ready; if ($j.processId -eq $p.Id -and $j.version -eq $SelectedVersion) { return $p } } catch {}
        }
        Start-Sleep -Milliseconds 250
    }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    throw "$SelectedVersion tray failed readiness check."
}
$switchMutex=New-Object Threading.Mutex($false,'Global\PowerProfile_TraySwitch')
$switchAcquired=$false
try {
    try { $switchAcquired=$switchMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $switchAcquired=$true }
    if (-not $switchAcquired) { return }
    $workerMutex=New-Object Threading.Mutex($false,'Global\PowerProfile_Worker')
    $workerAcquired=$false
    try {
        try { $workerAcquired=$workerMutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $workerAcquired=$true }
        if (-not $workerAcquired) { throw 'Power worker is busy.' }
        Restore-WorkstationOverlay $PSScriptRoot '托盘重启或版本切换，恢复原参数'
        Restore-DisplayPower $PSScriptRoot
        Write-ProfileEvent 'tray.switch' '开始切换托盘版本' -Data @{from=$oldVersion;to=$Version}
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='wscript.exe'" | Where-Object { Test-InstallationProcess $_ })) { Stop-Process -Id $p.ProcessId -Force }
        Start-Sleep -Milliseconds 500
    } finally {
        if ($workerAcquired) { $workerMutex.ReleaseMutex() }
        $workerMutex.Dispose()
    }
    try { $process=Start-CheckedTray $Version }
    catch {
        $failure=$_.Exception.Message
        $fallback=if ($Version -eq 'Modern') { 'Legacy' } else { $oldVersion }
        $process=Start-CheckedTray $fallback
        $Version=$fallback
        Write-AtomicJson (Join-Path $PSScriptRoot 'switch_result.json') @{version=$Version;error=$failure;fallback=$true}
    }
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'tray_version.txt'),$Version)
    Write-Host "Tray ready: $Version PID=$($process.Id)"
} catch {
    Add-Content (Join-Path $PSScriptRoot 'tray_lifecycle.log') -Value "[SWITCH ERROR] $_" -Encoding UTF8
    throw
} finally {
    if ($switchAcquired) { $switchMutex.ReleaseMutex() }
    $switchMutex.Dispose()
}
