$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'PowerProfileLogic.ps1')
function Assert-Equal($Name,$Actual,$Expected){if($Actual -ne $Expected){throw "$Name expected $Expected got $Actual"};Write-Host "PASS $Name"}
$legacyAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'legacy\PowerProfileLogic.ps1'),[ref]$null,[ref]$null)
$legacy=$legacyAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-AutoModeTransition'},$true)
. ([scriptblock]::Create($legacy.Extent.Text.Replace('function Get-AutoModeTransition','function Get-LegacyAutoModeTransition')))
foreach($mode in @('Idle','Balanced','Game')){
    foreach($signal in @(@{IsGame=$false},@{IsGame=$true},@{Defer=$true},@{ForceIdle=$true},@{ForceIdle=$true;IsGame=$true})){
        foreach($miss in @(0,1,2,3)){
            $expected=Get-LegacyAutoModeTransition $mode $signal $miss 3
            $actual=Get-AutoModeTransition $mode $signal $miss 3
            if($actual.Mode -ne $expected.Mode -or $actual.MissCount -ne $expected.MissCount){throw 'Original switching behavior changed'}
        }
    }
}
Write-Host 'PASS 60 recorded mode / signal / exit-grace combinations match legacy'
foreach($load in @(@{Valid=$true;AvgCpu=35;WorkloadSingleCore=90;WorkloadGpu=40},@{Valid=$true;AvgCpu=95;WorkloadGpu=90},@{Valid=$false})){
    Assert-Equal 'non-game workload never promotes quiet' (Get-AutoModeTransition Idle @{IsGame=$false;Load=$load} 0 3).Mode Idle
    Assert-Equal 'game exit returns quiet regardless of ordinary workload' (Get-AutoModeTransition Game @{IsGame=$false;Load=$load} 2 3).Mode Idle
}
Assert-Equal 'confirmed game immediately enters game profile' (Get-AutoModeTransition Idle @{IsGame=$true} 0 3).Mode Game
Assert-Equal 'game exit retains original grace count' (Get-AutoModeTransition Game @{IsGame=$false} 0 3).Mode Game
Assert-Equal 'failed detection retains current mode' (Get-AutoModeTransition Game @{Defer=$true} 2 3).Mode Game
Assert-Equal 'original idle guard restored' (Get-GameIdleQuietDecision Game 900 600 900 @{Fresh=$true;IsGame=$false;SmartLoadManaged=$true}) ForceNoGameSignal

$names=@{1='wallpaper64';2='dwm';3='ffmpeg';4='code'}
$samples=@(
    @{Path='pid_1_luid_0_phys_0_eng_0_engtype_3D';CookedValue=95},
    @{Path='pid_2_luid_0_phys_0_eng_0_engtype_3D';CookedValue=40},
    @{Path='pid_3_luid_0_phys_0_eng_1_engtype_VideoEncode';CookedValue=85},
    @{Path='pid_4_luid_0_phys_0_eng_0_engtype_3D';CookedValue=5}
)
Assert-Equal 'encoding is counted independently of wallpaper and desktop' (Get-WorkloadGpu $samples $names) 85
Assert-Equal 'wallpaper and desktop alone never trigger performance' (Get-WorkloadGpu $samples[0..1] $names) 0
Write-Host 'Original switching policy and workload collector tests passed.'

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
