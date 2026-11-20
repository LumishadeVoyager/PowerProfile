# On-demand read-only telemetry. Never changes power settings or game detection state.
param([string]$OperationId='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'PowerProfileDetection.ps1')
. (Join-Path $PSScriptRoot 'PowerProfileTelemetry.ps1')
. (Join-Path $PSScriptRoot 'PowerProfileLog.ps1')
Initialize-ProfileLogging $PSScriptRoot 'telemetry' $OperationId
$stage='read-previous'
try {
$previous=$null
try{$previous=Read-AtomicJson (Join-Path $PSScriptRoot 'system_status.json')}catch{}
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
$stage='publish-native'
$early=Merge-TelemetryMetrics $current $previous @{cpuFrequencyMHz='频率正在采样';gpu3d='GPU 正在采样';videoEncode='GPU 正在采样';compute='GPU 正在采样'}
$early.stage='frequency-loading';$early.operationId=$Script:ProfileOperationId;$early.hardware=$previous.hardware
Write-AtomicJson (Join-Path $PSScriptRoot 'system_status.json') $early
$stage='sample-frequency'
try {
    $frequency=Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -OperationTimeoutSec 3 -ErrorAction Stop
    # ProcessorFrequency alone can be the nominal clock, not the operating clock.
    $current.cpuFrequencyMHz=Get-CpuFrequencyEstimate $frequency
} catch {$errors.cpuFrequencyMHz='CPU 频率读取失败：'+$_.Exception.Message}
$hardware=$previous.hardware
if(-not $hardware.cpuName){
    try {
        $processors=@(Get-CimInstance Win32_Processor -OperationTimeoutSec 3 -ErrorAction Stop)
        $hardware=@{cpuName=($processors.Name -join ' / ');cores=($processors | Measure-Object NumberOfCores -Sum).Sum;logicalProcessors=($processors | Measure-Object NumberOfLogicalProcessors -Sum).Sum}
    } catch {$hardware=@{cpuName='';cores=$null;logicalProcessors=$null}}
}
$partialErrors=@{gpu3d='GPU 正在采样';videoEncode='GPU 正在采样';compute='GPU 正在采样';cpuFrequencyMHz=$errors.cpuFrequencyMHz}
$partial=Merge-TelemetryMetrics $current $previous $partialErrors
$partial.hardware=$hardware;$partial.operationId=$Script:ProfileOperationId
foreach($key in @('gpu3d','videoEncode','compute')){if($previous.fieldStates.$key -and ($null -ne $partial[$key] -or $null -eq $previous.$key)){$partial.fieldStates[$key]=$previous.fieldStates.$key}}
$partial.stage='gpu-loading'
$stage='publish-partial'
Write-AtomicJson (Join-Path $PSScriptRoot 'system_status.json') $partial
try{
    # PDH may report an invalid initial sample. Keep the query alive and evaluate the second observation per metric.
    $gpu=Get-BoundedGpuSample $PSScriptRoot
    foreach($key in @('gpu3d','videoEncode','compute')){$current[$key]=$gpu.values[$key];$errors[$key]=$gpu.errors[$key]}
}catch{foreach($key in @('gpu3d','videoEncode','compute')){$errors[$key]='GPU 计数器读取失败：'+$_.Exception.Message}}
$stage='merge-final'
$result=Merge-TelemetryMetrics $current $previous $errors
$result.hardware=$hardware;$result.operationId=$Script:ProfileOperationId
$stage='publish-final'
Write-AtomicJson (Join-Path $PSScriptRoot 'system_status.json') $result
$changed=@()
foreach($key in @('cpu','cpuFrequencyMHz','memoryPercent','gpu3d','videoEncode','compute')){
    $state=$result.fieldStates[$key].state
    if($state -ne $previous.fieldStates.$key.state -and ($previous.fieldStates.$key -or $state -ne 'fresh')){$changed+=@{metric=$key;state=$state;reason=$result.fieldStates[$key].reason}}
}
if($changed.Count){$level=if(@($changed|Where-Object {$_.state -ne 'fresh' -and $_.reason -notmatch '驱动未提供'}).Count){'WARN'}else{'INFO'};Write-ProfileEvent 'telemetry.availability' '指标可用性变化，其他指标继续刷新' $level @{metrics=$changed}}
} catch {
    Write-ProfileEvent 'telemetry.exception' $_.Exception.Message 'ERROR' @{stage=$stage;path=(Join-Path $PSScriptRoot 'system_status.json');exceptionType=$_.Exception.GetType().FullName;stack=$_.ScriptStackTrace;position=$_.InvocationInfo.PositionMessage}
    throw
}
