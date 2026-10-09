$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'PowerProfileLogic.ps1')
function Assert-Equal($Name,$Actual,$Expected){if($Actual -ne $Expected){throw "$Name expected $Expected got $Actual"};Write-Host "PASS $Name"}
$options=Read-AutoLoadOptions $null
$now=[DateTime]::UtcNow
function Sample($Cpu,$Core=30,$Gpu=0){return @{Valid=$true;AvgCpu=$Cpu;AvgCoreMax=$Core;WorkloadGpu=$Gpu;WorkloadGpuValid=$true}}
$medium=Sample 35
$low=Sample 8
$high=Sample 85
$first=Get-AutoLoadTransition Idle $medium $null $options $now
Assert-Equal 'ordinary medium work automatically selects balanced' $first.Mode Balanced
Assert-Equal 'brief load dip holds balanced' (Get-AutoLoadTransition Balanced $low $first.State $options $now.AddSeconds(30)).Mode Balanced
$down1=Get-AutoLoadTransition Balanced $low $first.State $options $now.AddSeconds(30)
$down2=Get-AutoLoadTransition Balanced $low $down1.State $options $now.AddSeconds(60)
$down3=Get-AutoLoadTransition Balanced $low $down2.State $options $now.AddSeconds(90)
Assert-Equal 'three low rounds return to quiet' $down3.Mode Idle
$high1=Get-AutoLoadTransition Idle $high $null $options $now
Assert-Equal 'one high spike uses balanced rather than unlimited' $high1.Mode Balanced
$high2=Get-AutoLoadTransition Balanced $high $high1.State $options $now.AddSeconds(30)
Assert-Equal 'sustained CPU job enters game performance profile' $high2.Mode Game
Assert-Equal 'high workload outranks keyboard absence' (Get-AutoModeTransition Idle @{IsGame=$false} 0 3 $high2.Mode).Mode Game
Assert-Equal 'real game goes straight to performance without confirmation' (Get-AutoModeTransition Idle @{IsGame=$true} 0 3 Balanced).Mode Game
Assert-Equal 'game exit retains original grace count' (Get-AutoModeTransition Game @{IsGame=$false} 0 3 Balanced).Mode Game
Assert-Equal 'game exit lands in balanced while work continues' (Get-AutoModeTransition Game @{IsGame=$false} 2 3 Balanced).Mode Balanced
Assert-Equal 'single-core pressure selects balanced' (Get-AutoLoadTransition Idle (Sample 12 90) $null $options $now).Mode Balanced
$ownWork=Sample 8 99;$ownWork.WorkloadSingleCore=20
Assert-Equal 'observer core spike is not application pressure' (Get-AutoLoadTransition Idle $ownWork $null $options $now).Mode Idle
Assert-Equal 'moderate GPU work selects balanced' (Get-AutoLoadTransition Idle (Sample 8 30 40) $null $options $now).Mode Balanced
$gpu1=Get-AutoLoadTransition Idle (Sample 8 30 85) $null $options $now
Assert-Equal 'sustained GPU encoding enters performance' (Get-AutoLoadTransition Balanced (Sample 8 30 85) $gpu1.State $options $now.AddSeconds(30)).Mode Game
Assert-Equal 'CPU load in hysteresis band holds balanced' (Get-AutoLoadTransition Balanced (Sample 20) $down2.State $options $now.AddSeconds(90)).Mode Balanced
Assert-Equal 'short medium period holds performance' (Get-AutoLoadTransition Game $medium $high2.State $options $now.AddSeconds(60)).Mode Game
Assert-Equal 'missing CPU sample cannot downgrade performance' (Get-AutoLoadTransition Game @{Valid=$false} $null $options $now).Mode Game
$missingGpu=Sample 8;$missingGpu.WorkloadGpuValid=$false
Assert-Equal 'missing GPU cannot masquerade as idle work' (Get-AutoLoadTransition Game $missingGpu $down2.State $options $now).Mode Game
Assert-Equal 'expired confirmation cannot upgrade' (Get-AutoLoadTransition Balanced $high $high1.State $options $now.AddMinutes(5)).Mode Balanced
$changed=Read-AutoLoadOptions @{highConfirmCount=3}
Assert-Equal 'policy change restarts confirmation' (Get-AutoLoadTransition Balanced $high $high1.State $changed $now.AddSeconds(30)).State.highCount 1
Assert-Equal 'manual mode change restarts confirmation' (Get-AutoLoadTransition Idle $high $high1.State $options $now.AddSeconds(30)).State.highCount 1
Assert-Equal 'idle quiet guard delegates managed work to load policy' (Get-GameIdleQuietDecision Game 900 600 900 @{Fresh=$true;IsGame=$false;SmartLoadManaged=$true}) DeferredWorkloadPolicy
$names=@{1='wallpaper64';2='dwm';3='ffmpeg';4='code'}
$samples=@(
    @{Path='pid_1_luid_0_phys_0_eng_0_engtype_3D';CookedValue=95},
    @{Path='pid_2_luid_0_phys_0_eng_0_engtype_3D';CookedValue=40},
    @{Path='pid_3_luid_0_phys_0_eng_1_engtype_VideoEncode';CookedValue=85},
    @{Path='pid_4_luid_0_phys_0_eng_0_engtype_3D';CookedValue=5}
)
Assert-Equal 'encoding is counted independently of wallpaper and desktop' (Get-WorkloadGpu $samples $names) 85
Assert-Equal 'wallpaper and desktop alone never trigger performance' (Get-WorkloadGpu $samples[0..1] $names) 0
Assert-Equal 'invalid threshold pair falls back safely' (Read-AutoLoadOptions @{balancedCpu=80;highCpu=70}).balancedCpu 25
Write-Host 'All smart workload policy tests passed.'

# Exercise the production collector with deterministic counter data, never applying power.
$project=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'PowerProfile.ps1'),[ref]$null,[ref]$null)
$collector=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-LoadSamples'},$true)
. ([scriptblock]::Create($collector.Extent.Text))
function Get-TopCpuProcess{return @{Pid=$PID;Cpu=40;Label='fixture'}}
function Get-ProcessLabel {param($ProcessId) return 'fixture'}
$Script:invalidCpu=$false
function Get-Counter {
    param($Path,$ErrorAction)
    if($Path -like '*GPU*'){
        return @{CounterSamples=@(
            [PSCustomObject]@{Path="pid_${PID}_luid_0_phys_0_eng_0_engtype_3D";CookedValue=5;Status=0},
            [PSCustomObject]@{Path="pid_${PID}_luid_0_phys_0_eng_1_engtype_VideoEncode";CookedValue=85;Status=0}
        )}
    }
    return @{CounterSamples=@(
        [PSCustomObject]@{InstanceName='_total';CookedValue=40;Status=$(if($Script:invalidCpu){1}else{0})},
        [PSCustomObject]@{InstanceName='0';CookedValue=85;Status=0}
    )}
}
$collected=Get-LoadSamples -Count 2 -IntervalMs 1
Assert-Equal 'production collector marks complete CPU data valid' $collected.Valid $true
Assert-Equal 'production collector keeps game detection 3D only' $collected.AvgGpu 5
Assert-Equal 'production collector includes video engine in workload pressure' $collected.WorkloadGpu 85
$Script:invalidCpu=$true
Assert-Equal 'bad counter status cannot become low-load evidence' (Get-LoadSamples -Count 2 -IntervalMs 1).Valid $false
