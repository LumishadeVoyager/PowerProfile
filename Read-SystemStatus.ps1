# On-demand read-only telemetry. Never changes power settings or game detection state.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'PowerProfileDetection.ps1')
Add-Type -Path (Join-Path $PSScriptRoot 'PowerProfileUI.cs') -ReferencedAssemblies System.Drawing,System.Windows.Forms
$memory=[ProfileSystemStatus]::Memory()
$cpu=[ProfileSystemStatus]::CpuSample(300)
$gpu3d=$null;$video=$null;$compute=$null
try {
    $samples=(Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction Stop).CounterSamples
    foreach($group in @(@('engtype_3D','gpu3d'),@('engtype_VideoEncode','video'),@('engtype_Compute','compute'))) {
        $matching=@($samples | Where-Object { $_.Path -like "*$($group[0])*" })
        if($matching.Count) {
            # Sum users of each physical engine, then take the busiest engine (not the sum of all engines).
            $engines=@{}
            foreach($s in $matching) {
                if([double]::IsNaN($s.CookedValue) -or [double]::IsInfinity($s.CookedValue) -or $s.CookedValue -gt 101 -or $s.CookedValue -lt -1){throw 'GPU counter invalid'}
                $key=$s.InstanceName -replace 'pid_\d+_',''
                if(-not $engines.ContainsKey($key)){$engines[$key]=0.0}
                $engines[$key]+=[Math]::Max(0,[double]$s.CookedValue)
            }
            $value=[Math]::Min(100,($engines.Values | Measure-Object -Maximum).Maximum)
            Set-Variable -Name $group[1] -Value ([Math]::Round($value,1))
        }
    }
} catch {$gpu3d=$null;$video=$null;$compute=$null}
Write-AtomicJson (Join-Path $PSScriptRoot 'system_status.json') ([PSCustomObject]@{
    observedAt=[DateTime]::UtcNow.ToString('o');cpu=$(if($cpu -ge 0){[Math]::Round($cpu,1)}else{$null})
    memoryPercent=$(if($memory){$memory.load}else{$null})
    memoryUsedGB=$(if($memory){[Math]::Round(($memory.totalPhysical-$memory.availablePhysical)/1GB,1)}else{$null})
    memoryTotalGB=$(if($memory){[Math]::Round($memory.totalPhysical/1GB,1)}else{$null})
    gpu3d=$gpu3d;videoEncode=$video;compute=$compute
})
