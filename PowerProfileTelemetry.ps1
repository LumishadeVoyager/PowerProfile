# Merge metrics independently: failed GPU samples never clear working CPU/memory values.
function Merge-TelemetryMetrics {
    param($Current,$Previous,$Errors,[DateTime]$Now=[DateTime]::UtcNow)
    $Now=$Now.ToUniversalTime()
    $result=@{schemaVersion=2;observedAt=$Now.ToString('o');fieldStates=@{}}
    foreach($key in @('cpu','cpuFrequencyMHz','memoryPercent','memoryUsedGB','memoryTotalGB','gpu3d','videoEncode','compute')){
        $value=$Current[$key]
        if($null -ne $value){$result[$key]=$value;$result.fieldStates[$key]=@{state='fresh';observedAt=$Now.ToString('o');reason=''}}
        else{
            $last=$null;$stamp=$null
            if($Previous){$last=$Previous.$key;$stamp=if($Previous.fieldStates.$key){$Previous.fieldStates.$key.observedAt}else{$Previous.observedAt}}
            $age=999999
            if($stamp){try{$age=($Now-([DateTime]$stamp).ToUniversalTime()).TotalSeconds}catch{}}
            if($null -ne $last -and $age -ge 0 -and $age -le 60){$result[$key]=$last;$result.fieldStates[$key]=@{state='stale';observedAt=$stamp;reason=$Errors[$key]}}
            else{$result[$key]=$null;$result.fieldStates[$key]=@{state='unavailable';observedAt=$null;reason=$Errors[$key]}}
        }
    }
    return $result
}
function Get-CpuFrequencyEstimate {
    param($Sample)
    $nominal=[double]$Sample.ProcessorFrequency
    $performance=[double]$Sample.PercentProcessorPerformance
    $mhz=$nominal*$performance/100.0
    if($nominal -le 0 -or $performance -le 0 -or [double]::IsNaN($mhz) -or [double]::IsInfinity($mhz) -or $mhz -gt 15000){throw '系统没有返回有效的 CPU 频率与性能计数器'}
    return [Math]::Round($mhz)
}
function Get-GpuMetricValues {
    param($Samples)
    $values=@{};$errors=@{}
    foreach($group in @(@('engtype_3D','gpu3d'),@('engtype_VideoEncode','videoEncode'),@('engtype_Compute','compute'))){
        $key=$group[1];$values[$key]=$null
        try{
            $matching=@($Samples | Where-Object {$_.InstanceName -like "*$($group[0])*"})
            if(-not $matching.Count){$errors[$key]='驱动未提供该引擎计数器';continue}
            $engines=@{}
            foreach($sample in $matching){
                $v=[double]$sample.CookedValue
                if($null -ne $sample.Status -and $sample.Status -notin @(0,1)){throw '该引擎本次计数状态无效'}
                if([double]::IsNaN($v) -or [double]::IsInfinity($v) -or $v -gt 101 -or $v -lt -1){throw '该引擎本次计数异常'}
                $physical=$sample.InstanceName -replace 'pid_\d+_',''
                if(-not $engines.ContainsKey($physical)){$engines[$physical]=0.0}
                $engines[$physical]+=[Math]::Max(0.0,$v)
            }
            $values[$key]=[Math]::Round([Math]::Min(100.0,[double](($engines.Values|Measure-Object -Maximum).Maximum)),1)
        }catch{$errors[$key]=$_.Exception.Message}
    }
    return @{values=$values;errors=$errors}
}
