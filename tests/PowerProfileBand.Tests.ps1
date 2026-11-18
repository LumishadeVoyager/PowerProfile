$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
$temporary=Join-Path $env:TEMP ('PowerProfile-Band-'+[Guid]::NewGuid())
$originalLocal=$env:LOCALAPPDATA
[void][IO.Directory]::CreateDirectory($temporary)
try {
    # Exercise real process ownership/supervision without credentials or networking.
    $env:LOCALAPPDATA=$temporary
    $runtime=Join-Path $temporary 'PowerProfile\band'
    [void][IO.Directory]::CreateDirectory($runtime)
    '{}'|Set-Content (Join-Path $runtime 'config.json') -Encoding UTF8
    Copy-Item (Join-Path $project 'PowerProfileBand.py') $temporary
    . (Join-Path $project 'PowerProfileBand.ps1')
    Initialize-ProfileBandSync $temporary
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    while(-not(Test-Path (Join-Path $runtime 'status.json')) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
    if(-not(Test-Path (Join-Path $runtime 'status.json'))){throw 'Worker did not start'}
    $status=Get-Content (Join-Path $runtime 'status.json') -Raw|ConvertFrom-Json
    if($status.parentPid -ne $PID -or $status.online){throw 'Worker ownership or safe offline state failed'}
    Write-Output 'PASS built-in worker starts with current parent and safe offline status'
    $before=$Script:BandWorker.Id
    $Script:BandWorker.Kill();[void]$Script:BandWorker.WaitForExit(5000)
    $Script:BandTimer.Interval=200
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    while($Script:BandWorker.Id -eq $before -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
    if($Script:BandWorker.Id -eq $before -or $Script:BandWorker.HasExited){throw 'Worker was not recovered'}
    Write-Output 'PASS supervisor recovers an unexpectedly exited worker'
    $worker=$Script:BandWorker
    Stop-ProfileBandSync
    if(-not $worker.WaitForExit(5000)){throw 'Worker survived normal shutdown'}
    Write-Output 'PASS normal shutdown stops owned worker'
} finally {
    if(Get-Command Stop-ProfileBandSync -ErrorAction SilentlyContinue){Stop-ProfileBandSync}
    $env:LOCALAPPDATA=$originalLocal
    $resolved=[IO.Path]::GetFullPath($temporary)
    if($resolved.StartsWith([IO.Path]::GetFullPath($env:TEMP),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
