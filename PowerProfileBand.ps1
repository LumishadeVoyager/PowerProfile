# Built-in band publisher, owned and supervised by the PowerProfile launcher.
function Start-ProfileBandSync {
    param([string]$Root)
    $runtime=Join-Path $env:LOCALAPPDATA 'PowerProfile\band'
    if(-not(Test-Path (Join-Path $runtime 'config.json'))){return}
    if($Script:BandWorker -and -not $Script:BandWorker.HasExited){return}
    $python=Join-Path $Root '.codex\energy-cloud\Scripts\python.exe'
    if(-not(Test-Path $python)){$command=Get-Command python.exe -ErrorAction SilentlyContinue;if(-not $command -or $command.Source -match 'WindowsApps'){Add-Content (Join-Path $Root 'tray_lifecycle.log') '[BAND] Python unavailable; sync not started';return};$python=$command.Source}
    $Script:BandWorker=Start-Process -FilePath $python -WindowStyle Hidden -PassThru -ArgumentList @(('"'+(Join-Path $Root 'PowerProfileBand.py')+'"'),'--root',('"'+$Root+'"'),'--parent-pid',"$PID")
    Add-Content (Join-Path $Root 'tray_lifecycle.log') -Value ("[BAND] parent={0} worker={1} started" -f $PID,$Script:BandWorker.Id)
}
function Stop-ProfileBandSync {
    if($Script:BandTimer){$Script:BandTimer.Stop();$Script:BandTimer.Dispose();$Script:BandTimer=$null}
    if($Script:BandWorker -and -not $Script:BandWorker.HasExited){try{$Script:BandWorker.Kill()}catch{}}
    $Script:BandWorker=$null
}
function Initialize-ProfileBandSync {
    param([string]$Root)
    $Script:BandRoot=$Root
    try{Start-ProfileBandSync $Root}catch{Add-Content (Join-Path $Root 'tray_lifecycle.log') '[BAND] Start failed; retry on next timer'}
    Add-Type -AssemblyName System.Windows.Forms
    $Script:BandTimer=New-Object Windows.Forms.Timer
    $Script:BandTimer.Interval=20000
    $Script:BandTimer.Add_Tick({try{Start-ProfileBandSync $Script:BandRoot}catch{}})
    $Script:BandTimer.Start()
}
