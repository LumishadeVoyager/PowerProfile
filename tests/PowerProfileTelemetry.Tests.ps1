$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'PowerProfileTelemetry.ps1')
function Assert-Equal($Name,$Actual,$Expected){if($Actual -ne $Expected){throw "$Name expected $Expected got $Actual"};Write-Host "PASS $Name"}
$now=[DateTime]'2026-10-09T06:00:00Z'
$previous=[PSCustomObject]@{observedAt=$now.AddSeconds(-5).ToString('o');gpu3d=33;cpu=10;memoryPercent=52;videoEncode=12;compute=$null}
$current=@{cpu=20;memoryPercent=53;gpu3d=$null;videoEncode=0;compute=$null}
$merged=Merge-TelemetryMetrics $current $previous @{gpu3d='counter failed';compute='unsupported'} $now
Assert-Equal 'GPU failure does not erase CPU' $merged.cpu 20
Assert-Equal 'GPU failure does not erase memory' $merged.memoryPercent 53
Assert-Equal 'last GPU value retained with stale label' $merged.gpu3d 33
Assert-Equal 'retained GPU marked stale' $merged.fieldStates.gpu3d.state 'stale'
Assert-Equal 'real zero is a fresh value' $merged.fieldStates.videoEncode.state 'fresh'
Assert-Equal 'unsupported compute is explained' $merged.fieldStates.compute.reason 'unsupported'
$next=Merge-TelemetryMetrics $current ($merged | ConvertTo-Json -Depth 8 | ConvertFrom-Json) @{gpu3d='counter failed'} $now.AddSeconds(20)
Assert-Equal 'repeated failures do not refresh last-good timestamp' $next.fieldStates.gpu3d.observedAt $previous.observedAt
$expired=Merge-TelemetryMetrics $current ($next | ConvertTo-Json -Depth 8 | ConvertFrom-Json) @{} $now.AddSeconds(61)
Assert-Equal 'old values expire instead of masquerading as live' ($null -eq $expired.gpu3d) $true
$samples=@(
 [PSCustomObject]@{InstanceName='pid_1_luid_A_eng_0_engtype_3D';CookedValue=12;Status=0},
 [PSCustomObject]@{InstanceName='pid_2_luid_A_eng_0_engtype_3D';CookedValue=8;Status=0},
 [PSCustomObject]@{InstanceName='pid_3_luid_A_eng_1_engtype_VideoEncode';CookedValue=4;Status=0}
)
$gpu=Get-GpuMetricValues $samples
Assert-Equal 'physical engine sums process activity' $gpu.values.gpu3d 20
$samples[2].CookedValue=9e13
$gpu=Get-GpuMetricValues $samples
Assert-Equal 'bad encode does not clear valid 3D' $gpu.values.gpu3d 20
Assert-Equal 'invalid counter reports its reason' ($gpu.errors.videoEncode.Length -gt 0) $true
Write-Host 'All telemetry tests passed.'
