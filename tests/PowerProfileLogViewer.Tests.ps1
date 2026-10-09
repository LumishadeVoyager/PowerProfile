$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
Add-Type -Path (Join-Path $project 'PowerProfileLogViewer.cs') -ReferencedAssemblies System.Drawing,System.Windows.Forms,System.Web.Extensions
function Assert-Equal($Name,$Actual,$Expected){if($Actual -ne $Expected){throw "$Name expected $Expected got $Actual"};Write-Host "PASS $Name"}
$root=Join-Path ([IO.Path]::GetTempPath()) ('PowerProfileLogViewerTests-'+[Guid]::NewGuid())
[void][IO.Directory]::CreateDirectory((Join-Path $root 'logs'))
try{
 $date=(Get-Date).Date;$file=Join-Path $root ('logs\PowerProfile-'+$date.ToString('yyyy-MM-dd')+'.jsonl')
 $events=@(
 @{event='worker.request';operationId='tray-session';data=@{operationId='enter'};message='派发'},
 @{event='workstation.apply.success';operationId='enter';data=@{freqMax=1800};message='省电已生效'},
 @{event='workstation.restore.success';operationId='restore';data=@{enteredBy='enter'};message='原参数恢复'},
 @{event='worker.failed';operationId='other';data=@{};message='另一操作错误'}
 )
 $lines=@()
 for($i=0;$i -lt $events.Count;$i++){$r=$events[$i];$r.timestamp=$date.ToUniversalTime().AddSeconds($i).ToString('o');$r.localTime=$date.AddSeconds($i).ToString('yyyy-MM-dd HH:mm:ss.fff zzz');$r.level=if($i -eq 3){'ERROR'}else{'INFO'};$r.pid=123;$lines+=($r|ConvertTo-Json -Depth 5 -Compress)}
 $lines+='incomplete {'
 [IO.File]::WriteAllLines($file,$lines,(New-Object Text.UTF8Encoding $true))
 $skipped=0;$records=[ProfileLogViewer]::ReadRecords((Join-Path $root 'logs'),$date,[ref]$skipped)
 Assert-Equal 'malformed record skipped without losing valid events' $records.Count 4
 Assert-Equal 'parse error count disclosed' $skipped 1
 Assert-Equal 'tray request follows child operation' $records[0].Operation 'enter'
 $chain=[ProfileLogViewer]::ConnectedOperations($records,'enter')
 Assert-Equal 'entry is linked to restoration' ($chain.Contains('restore')) $true
 Assert-Equal 'unrelated operation excluded' ($chain.Contains('other')) $false
 Assert-Equal 'tray session does not merge every operation' ($chain.Contains('tray-session')) $false
 Assert-Equal 'detail contains source line' ($records[1].Details().Contains('.jsonl:2')) $true
 Assert-Equal 'detail contains frequency evidence' ($records[1].Details().Contains('1800')) $true
 $form=New-Object ProfileLogViewer $root
 $form.SelectSearch('恢复');$form.Show()
 $deadline=[DateTime]::UtcNow.AddSeconds(8)
 do{[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 30}while($form.VisibleRecordCount -eq 0 -and [DateTime]::UtcNow -lt $deadline)
 Assert-Equal 'native viewer asynchronously loads filtered records' $form.VisibleRecordCount 1
 $split=@($form.Controls|Where-Object {$_ -is [Windows.Forms.SplitContainer]})[0]
 $split.Panel1.Controls[0].Items[0].Selected=$true
 [Windows.Forms.Application]::DoEvents()
 Assert-Equal 'selected event displays readable restoration details' ($split.Panel2.Controls[0].Text.Contains('原参数恢复')) $true
 $form.SelectSearch('');[Windows.Forms.Application]::DoEvents()
 Assert-Equal 'clearing search restores complete timeline' $form.VisibleRecordCount 4
 $form.Close();$form.Dispose()
 $parent=@{timestamp=$date.ToUniversalTime().AddMinutes(1).ToString('o');event='telemetry.failed';operationId='tray-session';data=@{childOperationId='sample-1'};message='采样失败';level='WARN'}
 $child=@{timestamp=$date.ToUniversalTime().AddMinutes(1).AddSeconds(1).ToString('o');event='telemetry.exception';operationId='sample-1';data=@{stage='publish-final';stack='fixture stack'};message='文件被占用';level='ERROR'}
 [IO.File]::AppendAllText($file,(($parent|ConvertTo-Json -Depth 5 -Compress)+[Environment]::NewLine+($child|ConvertTo-Json -Depth 5 -Compress)+[Environment]::NewLine),(New-Object Text.UTF8Encoding $false))
 $records=[ProfileLogViewer]::ReadRecords((Join-Path $root 'logs'),$date,[ref]$skipped)
 $sampleChain=[ProfileLogViewer]::ConnectedOperations($records,'sample-1')
 Assert-Equal 'sampler failure follows its child operation' $records[4].Operation 'sample-1'
 Assert-Equal 'sampler correlation does not merge every tray operation' ($sampleChain.Contains('tray-session')) $false
}finally{
 $full=[IO.Path]::GetFullPath($root);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\PowerProfileLogViewerTests-'
 if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe cleanup path'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
Write-Host 'All log viewer tests passed.'
