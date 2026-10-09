function Get-GameIdleQuietDecision {
    param(
        [string]$CurrentMode,
        [int]$ActivityIdleSec,
        [int]$ThresholdSec,
        [int]$EffectiveIdleSec,
        $Detection
    )

    if ($CurrentMode -ne 'Game' -or $ThresholdSec -le 0 -or $ActivityIdleSec -lt $ThresholdSec) {
        return 'None'
    }

    # Full-screen 3D is an immediate process signal, including native-HID DualSense games.
    if ($EffectiveIdleSec -eq 0) { return 'SuppressedForeground3D' }

    if (-not $Detection -or -not $Detection.Fresh) { return 'DeferredStaleDetection' }
    if ($Detection.IsGame) { return "SuppressedGame:$($Detection.Source)" }
    if ($Detection.SmartLoadManaged) { return 'DeferredWorkloadPolicy' }

    return 'ForceNoGameSignal'
}

function Test-ShouldContinueAutoDetection {
    param([string]$IdleQuietDecision)
    return ($IdleQuietDecision -ne 'ForcedNoGameSignal')
}

# These decisions are independent of Windows APIs so recorded scenarios can be replayed.
function Test-PathUnderRoot {
    param([string]$Path, [string]$Root)
    if (-not $Path -or -not $Root) { return $false }
    try {
        $full = [IO.Path]::GetFullPath($Path)
        $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        return $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Get-GameSignalDecision {
    param($Candidate, [int]$BackgroundGraceSec = 120)
    if ($Candidate.Excluded) { return 'Excluded' }
    # A session must match PID + creation time; a recycled PID is never confirmation.
    if ($Candidate.SameSession) {
        if ($Candidate.Foreground) { return 'ConfirmedForeground' }
        if ($Candidate.SecondsSinceForeground -ge 0 -and $Candidate.SecondsSinceForeground -le $BackgroundGraceSec) {
            return 'BackgroundGrace'
        }
        if ($Candidate.Gpu -ge 3 -or $Candidate.Cpu -ge 20) { return 'BackgroundGameLoad' }
        return 'BackgroundInactive'
    }
    if (-not $Candidate.Foreground) { return 'NoForegroundEvidence' }
    if ($Candidate.ExplicitGame) { return 'ConfiguredGame' }
    # Library path + the app's own activity supports windowed/2D/protected games.
    # Never borrow the wallpaper's GPU load or another process's CPU load.
    if ($Candidate.InLibrary -and ($Candidate.IsD3D -or $Candidate.Gpu -ge 1 -or $Candidate.Cpu -ge 20)) {
        return 'LibraryGame'
    }
    if ($Candidate.IsFullscreen -and $Candidate.IsD3D -and ($Candidate.Gpu -ge 5 -or $Candidate.Cpu -ge 40)) {
        return 'Foreground3DLoad'
    }
    return 'NoGameEvidence'
}

function Test-PositiveGameSignal {
    param([string]$Signal)
    return $Signal -in @('ConfiguredGame', 'LibraryGame', 'Foreground3DLoad', 'ConfirmedForeground', 'BackgroundGrace', 'BackgroundGameLoad')
}

function Get-AutoModeTransition {
    param([string]$CurrentMode, $Detection, [int]$MissCount, [int]$ExitMissCount,[string]$TargetMode='')
    if ($Detection.ForceIdle) { return @{ Mode = 'Idle'; MissCount = 0 } }
    if ($Detection.IsGame) { return @{ Mode = 'Game'; MissCount = 0 } }
    if ($Detection.Defer) { return @{ Mode = $CurrentMode; MissCount = $MissCount } }
    if ($CurrentMode -eq 'Game') {
        $nextMiss = [Math]::Max(0, $MissCount) + 1
        if ($nextMiss -lt [Math]::Max(1, $ExitMissCount)) { return @{ Mode = 'Game'; MissCount = $nextMiss } }
        return @{ Mode = $(if($TargetMode){$TargetMode}else{'Idle'}); MissCount = 0 }
    }
    if($TargetMode){return @{Mode=$TargetMode;MissCount=0}}
    return @{ Mode = $CurrentMode; MissCount = 0 }
}

function Read-AutoLoadOptions {
    param($Json)
    $options=@{balancedCpu=25;highCpu=70;highConfirmCount=2;downConfirmCount=3}
    foreach($key in @($options.Keys)){
        $raw=$Json.$key;$value=$raw -as [int]
        $max=if($key -like '*Count'){6}else{95};$min=if($key -like '*Count'){1}else{10}
        if($raw -isnot [bool] -and $null -ne $value -and [string]$raw -eq [string]$value -and $value -ge $min -and $value -le $max){$options[$key]=$value}
    }
    if($options.highCpu -lt $options.balancedCpu+10){$options.balancedCpu=25;$options.highCpu=70}
    return $options
}

function Get-WorkloadGpu {
    param($Samples,$ProcessNames)
    $engines=@{}
    foreach($sample in $Samples){
        if($sample.Path -notmatch 'pid_(\d+)'){continue};$processId=[int]$matches[1]
        if(-not $ProcessNames.ContainsKey($processId)){continue}
        if($ProcessNames[$processId] -in @('wallpaper32','wallpaper64','wallpaperui','wallpaperui32','wallpaperui64','dwm','explorer','shellexperiencehost','startmenuexperiencehost','lockapp','logonui')){continue}
        $value=[double]$sample.CookedValue
        if($null -ne $sample.Status -and $sample.Status -ne 0){continue}
        if([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -le 0){continue}
        if($sample.Path -match '(luid_.+?engtype_[^)\\]+)'){$engine=$matches[1]}else{$engine='other'}
        if(-not $engines.ContainsKey($engine)){$engines[$engine]=0.0};$engines[$engine]+=$value
    }
    if(-not $engines.Count){return 0.0}
    return [Math]::Min(100.0,($engines.Values | Measure-Object -Maximum).Maximum)
}

function Get-AutoLoadTransition {
    param([string]$CurrentMode,$Load,$Previous,$Options,[DateTime]$Now=[DateTime]::UtcNow,[int]$MaxAgeSeconds=120)
    $key=($Options.balancedCpu,$Options.highCpu,$Options.highConfirmCount,$Options.downConfirmCount) -join ':'
    $state=@{observedAt=$Now.ToString('o');policyKey=$key;mode=$CurrentMode;highCount=0;downCount=0}
    if($Load.Valid -ne $true){return @{Mode=$CurrentMode;State=$state;Reason='负载采样不完整，保持当前档位';Valid=$false}}
    try{$age=($Now-([DateTime]$Previous.observedAt).ToUniversalTime()).TotalSeconds}catch{$age=-1}
    if($Previous.policyKey -eq $key -and $Previous.mode -eq $CurrentMode -and $age -ge 0 -and $age -le $MaxAgeSeconds){$state.highCount=[int]$Previous.highCount;$state.downCount=[int]$Previous.downCount}
    $cpu=[double]$Load.AvgCpu;$core=if($null -ne $Load.WorkloadSingleCore){[double]$Load.WorkloadSingleCore}else{[double]$Load.AvgCoreMax};$gpu=[double]$Load.WorkloadGpu
    $high=$cpu -ge $Options.highCpu -or $gpu -ge 75
    $moderate=$cpu -ge $Options.balancedCpu -or $core -ge 80 -or $gpu -ge 30
    $gpuKnown=$Load.WorkloadGpuValid -ne $false
    $low=$gpuKnown -and $cpu -lt [Math]::Max(10,$Options.balancedCpu-5) -and $core -lt 70 -and $gpu -lt 10
    $state.highCount=if($high){$state.highCount+1}else{0}
    $target='Idle';$detail='低负载'
    if($high -and $state.highCount -ge $Options.highConfirmCount){$target='Game';$detail='持续重负载'}
    elseif($moderate){$target='Balanced';$detail=if($high){"重负载确认 $($state.highCount)/$($Options.highConfirmCount)，先进入均衡"}else{'中等负载或单核压力'}}
    if($target -eq 'Idle' -and -not $low -and $CurrentMode -ne 'Idle'){$target='Balanced';$detail='负载处于均衡保持区间'}
    $rank=@{Idle=0;Balanced=1;Game=2}
    if(-not $rank.ContainsKey($CurrentMode)){$CurrentMode='Idle'}
    if($rank[$target] -lt $rank[$CurrentMode]){
        $canDown=if($CurrentMode -eq 'Game'){$gpuKnown -and $cpu -lt $Options.highCpu-10 -and $gpu -lt 60}else{$low}
        $state.downCount=if($canDown){$state.downCount+1}else{0}
        if($state.downCount -lt $Options.downConfirmCount){$target=$CurrentMode;$detail="保持档位，降档确认 $($state.downCount)/$($Options.downConfirmCount)"}
    }else{$state.downCount=0}
    $state.mode=$target
    return @{Mode=$target;State=$state;Valid=$true;Reason=("{0}；CPU={1:N0}% 进程一核算力={2:N0}% 工作负载GPU={3:N0}%" -f $detail,$cpu,$core,$gpu)}
}
