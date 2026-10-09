# On-demand read-only telemetry. Never changes power settings or game detection state.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'PowerProfileDetection.ps1')
. (Join-Path $PSScriptRoot 'PowerProfileTelemetry.ps1')
. (Join-Path $PSScriptRoot 'PowerProfileLog.ps1')
Initialize-ProfileLogging $PSScriptRoot 'telemetry'
$previous=$null
try{$previous=Get-Content (Join-Path $PSScriptRoot 'system_status.json') -Raw -Encoding UTF8 | ConvertFrom-Json}catch{}
$current=@{};$errors=@{}
try{
    Add-Type -Path (Join-Path $PSScriptRoot 'PowerProfileUI.cs') -ReferencedAssemblies System.Drawing,System.Windows.Forms
    $memory=[ProfileSystemStatus]::Memory()
    $cpu=[ProfileSystemStatus]::CpuSample(300)
    $current.cpu=if($cpu -ge 0){[Math]::Round($cpu,1)}else{$null}
    $current.memoryPercent=if($memory){$memory.load}else{$null}
    $current.memoryUsedGB=if($memory){[Math]::Round(($memory.totalPhysical-$memory.availablePhysical)/1GB,1)}else{$null}
    $current.memoryTotalGB=if($memory){[Math]::Round($memory.totalPhysical/1GB,1)}else{$null}
}catch{
    foreach($key in @('cpu','memoryPercent','memoryUsedGB','memoryTotalGB')){$errors[$key]=$_.Exception.Message}
    Write-ProfileEvent 'telemetry.native.failed' $_.Exception.Message 'WARN'
}
$partial=Merge-TelemetryMetrics $current $previous @{gpu3d='GPU 正在采样';videoEncode='GPU 正在采样';compute='GPU 正在采样'}
foreach($key in @('gpu3d','videoEncode','compute')){if($previous.fieldStates.$key -and ($null -ne $partial[$key] -or $null -eq $previous.$key)){$partial.fieldStates[$key]=$previous.fieldStates.$key}}
$partial.stage='gpu-loading'
Write-AtomicJson (Join-Path $PSScriptRoot 'system_status.json') $partial
try{
    # PDH may report an invalid initial sample. Keep the query alive and evaluate the second observation per metric.
    $last=Get-Counter '\GPU Engine(*)\Utilization Percentage' -SampleInterval 1 -MaxSamples 2 -ErrorAction SilentlyContinue | Select-Object -Last 1
    if(-not $last -or -not $last.CounterSamples){throw '驱动未返回 GPU 样本'}
    $gpu=Get-GpuMetricValues $last.CounterSamples
    foreach($key in @('gpu3d','videoEncode','compute')){$current[$key]=$gpu.values[$key];$errors[$key]=$gpu.errors[$key]}
}catch{foreach($key in @('gpu3d','videoEncode','compute')){$errors[$key]='GPU 计数器读取失败：'+$_.Exception.Message}}
$result=Merge-TelemetryMetrics $current $previous $errors
Write-AtomicJson (Join-Path $PSScriptRoot 'system_status.json') $result
$changed=@()
foreach($key in @('cpu','memoryPercent','gpu3d','videoEncode','compute')){
    $state=$result.fieldStates[$key].state
    if($state -ne $previous.fieldStates.$key.state -and ($previous.fieldStates.$key -or $state -ne 'fresh')){$changed+=@{metric=$key;state=$state;reason=$result.fieldStates[$key].reason}}
}
if($changed.Count){$level=if(@($changed|Where-Object {$_.state -ne 'fresh' -and $_.reason -notmatch '驱动未提供'}).Count){'WARN'}else{'INFO'};Write-ProfileEvent 'telemetry.availability' '指标可用性变化，其他指标继续刷新' $level @{metrics=$changed}}
