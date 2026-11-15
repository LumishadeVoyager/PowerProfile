$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'PowerProfileDetection.ps1')
function Assert-True($Name,$Value){if(-not $Value){throw $Name};Write-Host "PASS $Name"}
$root=Join-Path ([IO.Path]::GetTempPath()) ('PowerProfileIOTests-'+[Guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($root)
$jobs=@()
try {
    $path=Join-Path $root 'state.json'
    Write-AtomicJson $path @{sequence=0;message='完整快照'}
    Assert-True 'initial publication is readable' ((Read-AtomicJson $path).message -eq '完整快照')
    $reader=New-Object IO.FileStream($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        Write-AtomicJson $path @{sequence=1}
        Assert-True 'shared reader does not block publication' ((Read-AtomicJson $path).sequence -eq 1)
        $text=New-Object IO.StreamReader($reader)
        Assert-True 'open reader retains its complete original snapshot' (($text.ReadToEnd() | ConvertFrom-Json).sequence -eq 0)
        $text.Dispose()
    } finally {$reader.Dispose()}
    $locked=New-Object IO.FileStream($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $failed=$false
    try {Write-AtomicJson $path @{sequence=2}}catch{$failed=$_.Exception.ToString() -match 'Win32'}finally{$locked.Dispose()}
    Assert-True 'persistent lock reports a useful error' $failed
    Assert-True 'failed publication preserves last committed snapshot' ((Read-AtomicJson $path).sequence -eq 1)
    Assert-True 'failed publication cleans only its temporary file' (@(Get-ChildItem $root -Filter '*.tmp').Count -eq 0)
    Add-Type @'
using System;
using System.IO;
using System.Threading;
public static class SnapshotTestLock {
    public static void HoldExclusive(string path) {
        var ready = new ManualResetEvent(false);
        var thread = new Thread(() => {
            using (var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None)) {
                ready.Set(); Thread.Sleep(700);
            }
        });
        thread.Start(); ready.WaitOne(); ready.Dispose();
    }
    public static void Hold(string path) {
        var ready = new ManualResetEvent(false);
        var thread = new Thread(() => {
            using (var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                ready.Set(); Thread.Sleep(250);
            }
        });
        thread.Start(); ready.WaitOne(); ready.Dispose();
    }
}
'@
    [SnapshotTestLock]::Hold($path)
    $watch=[Diagnostics.Stopwatch]::StartNew()
    Write-AtomicJson $path @{sequence=3}
    Assert-True 'transient incompatible reader is retried' ($watch.ElapsedMilliseconds -ge 180 -and (Read-AtomicJson $path).sequence -eq 3)
    [SnapshotTestLock]::HoldExclusive($path)
    $watch.Restart()
    $afterContention=Read-AtomicJson $path
    Assert-True 'reader survives a replacement lock beyond the fast retry window' ($watch.ElapsedMilliseconds -ge 600 -and $afterContention.sequence -eq 3)
    foreach($role in @('writer1','writer2','reader')) {
        $jobs+=Start-Job -ArgumentList $project,$path,$role -ScriptBlock {
            param($project,$path,$role)
            $ErrorActionPreference='Stop'
            . (Join-Path $project 'PowerProfileDetection.ps1')
            Initialize-SnapshotIO
            for($i=0;$i -lt 150;$i++){
                if($role -eq 'reader') {
                    $value=Read-AtomicJson $path
                    if($null -eq $value.sequence){throw 'Missing or partial snapshot'}
                } else {Write-AtomicJson $path @{sequence=$i;writer=$role;payload=('中文' * 1000)}}
                Start-Sleep -Milliseconds 5
            }
        }
    }
    $completed=@($jobs | Wait-Job -Timeout 45)
    Assert-True 'concurrent writers and reader finish within deadline' ($completed.Count -eq 3)
    foreach($job in $jobs){Receive-Job $job -ErrorAction Stop;Assert-True "concurrent $($job.Id) completed" ($job.State -eq 'Completed')}
    Assert-True 'concurrent publication leaves valid final JSON' ($null -ne (Read-AtomicJson $path).sequence)
    Assert-True 'concurrent publication leaves no temporary files' (@(Get-ChildItem $root -Filter '*.tmp').Count -eq 0)
    # Exercise the real sampler failure boundary against an isolated installation.
    $fixture=Join-Path $root 'sampler'
    [void][IO.Directory]::CreateDirectory($fixture)
    foreach($name in @('Read-SystemStatus.ps1','PowerProfileDetection.ps1','PowerProfileLogic.ps1','PowerProfileTelemetry.ps1','PowerProfileLog.ps1','PowerProfileUI.cs','PowerProfileFileIO.cs')){Copy-Item (Join-Path $project $name) (Join-Path $fixture $name)}
    $status=Join-Path $fixture 'system_status.json'
    Write-AtomicJson $status @{cpu=1;fieldStates=@{}}
    $locked=[IO.File]::Open($status,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $sampler=$null
    try {
        $sampler=Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f (Join-Path $fixture 'Read-SystemStatus.ps1')),'-OperationId','fixture-sampler-error') -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $fixture 'stderr.txt')
        if(-not $sampler.WaitForExit(15000)){throw 'Fixture sampler did not finish within deadline'}
        Assert-True 'real sampler surfaces persistent publication failure' ($sampler.ExitCode -ne 0)
    } finally { $locked.Dispose();if($sampler){if(-not $sampler.HasExited){$sampler.Kill()};$sampler.Dispose()} }
    $records=@(Get-Content (Join-Path $fixture ('logs\PowerProfile-'+(Get-Date).ToString('yyyy-MM-dd')+'.jsonl')) | ForEach-Object {$_ | ConvertFrom-Json})
    $errorEvent=@($records | Where-Object {$_.event -eq 'telemetry.exception'})[0]
    Assert-True 'sampler failure records exact stage and child correlation' ($errorEvent.data.stage -eq 'publish-native' -and $errorEvent.operationId -eq 'fixture-sampler-error')
    Assert-True 'sampler failure records file path and stack' ($errorEvent.data.path -eq $status -and $errorEvent.data.stack -match 'Write-AtomicJson' -and $errorEvent.message -match 'Win32')
} finally {
    foreach($job in $jobs){Stop-Job $job;Remove-Job $job}
    if([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $root -Leaf) -like 'PowerProfileIOTests-*'){Remove-Item -LiteralPath $root -Recurse -Force}
}
