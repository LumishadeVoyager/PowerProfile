# Independent overlay policy; dot-sourcing does not read sensors or apply power settings.
function Get-WorkstationOptions {
    param($Json)
    $options=@{enabled=$false;freqMax=1800;awayMinutes=20;cpuThreshold=25.0;processCpuThreshold=10.0;singleCoreThreshold=70.0;gpuThreshold=15.0;protectedProcesses=@();pausedUntil=''}
    if($Json.workstation){
        $w=$Json.workstation
        if($w.enabled -is [bool]){$options.enabled=$w.enabled}
        foreach($k in @('freqMax','awayMinutes','cpuThreshold','processCpuThreshold','singleCoreThreshold','gpuThreshold')){
            $n=$w.$k -as [double]
            if($null -ne $n -and $n -gt 0){$options[$k]=$n}
        }
        $options.protectedProcesses=@($w.protectedProcesses | Where-Object {$_ -is [string] -and $_.Trim()} | ForEach-Object {$_.Trim() -replace '\.exe$',''})
        $options.pausedUntil=[string]$w.pausedUntil
    }
    return $options
}
function Get-BeijingTime {return [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow,[TimeZoneInfo]::FindSystemTimeZoneById('China Standard Time'))}
function Test-ChineseWorkingDate {
    param([DateTime]$Date,$Calendar)
    if(-not $Calendar -or $Calendar.year -ne $Date.Year){return $false}
    $key=$Date.ToString('yyyy-MM-dd')
    if(@($Calendar.holidays) -contains $key){return $false}
    if(@($Calendar.workingWeekends) -contains $key){return $true}
    return $Date.DayOfWeek -notin @([DayOfWeek]::Saturday,[DayOfWeek]::Sunday)
}
function Get-WorkstationDecision {
    param($Options,[DateTime]$Now,$Calendar,[bool]$OnAC,[bool]$AutoEnabled,[string]$Mode,[int]$IdleSeconds,$Safety,[bool]$StableSettings,[bool]$QuietConfirmed=$false)
    if(-not $Options.enabled){return 'Disabled'}
    if($Options.pausedUntil){try{if($Now -lt [DateTime]::Parse($Options.pausedUntil)){return 'Paused'}}catch{return 'InvalidPause'}}
    if(-not $OnAC){return 'Battery'}
    if(-not $AutoEnabled -or $Mode -ne 'Idle'){return 'ModeProtected'}
    if(-not $Calendar -or $Calendar.year -ne $Now.Year){return 'CalendarUnavailable'}
    if(-not (Test-ChineseWorkingDate $Now $Calendar)){return 'Holiday'}
    if($Now.TimeOfDay -lt [TimeSpan]::FromHours(10) -or $Now.TimeOfDay -ge [TimeSpan]::FromHours(18)){return 'OutsideHours'}
    if($IdleSeconds -lt $Options.awayMinutes*60){return 'RecentInput'}
    if(-not $StableSettings){return 'StabilityGuard'}
    if(-not $Safety -or -not $Safety.Known){return 'SafetyUnavailable'}
    if($Safety.Game){return 'GamePresent'}
    if($Safety.Protected){return 'ProtectedProcess'}
    if($Safety.Cpu -ge $Options.cpuThreshold -or $Safety.ProcessCpu -ge $Options.processCpuThreshold -or $Safety.SingleCore -ge $Options.singleCoreThreshold -or $Safety.Gpu -ge $Options.gpuThreshold){return 'HighLoad'}
    if(-not $QuietConfirmed){return 'ConfirmingQuiet'}
    return 'Eligible'
}
function Get-WorkstationReason {
    param([string]$Code)
    $reasons=@{Disabled='已关闭';Paused='今天已暂停';InvalidPause='暂停时间无效';Battery='未接交流电';ModeProtected='游戏、均衡或手动档位优先';CalendarUnavailable='本年度日历不可用';Holiday='节假日或休息日';OutsideHours='不在 10:00–18:00';RecentInput='本机或远程输入后未满 20 分钟';StabilityGuard='稳定参数校验不通过';SafetyUnavailable='安全检测数据不可用';GamePresent='游戏进程存在';ProtectedProcess='保护进程存在';HighLoad='检测到高负载';ConfirmingQuiet='正在确认持续低负载';Eligible='工作日离开且持续低负载'}
    if($reasons.ContainsKey($Code)){return $reasons[$Code]};return $Code
}
function Get-StrictProcessProtection {
    param($Processes,$Options,$DetectionOptions,$Roots)
    $result=@{Game=$false;Protected=$false;Process='';Known=$true;UnknownProcesses=@()}
    foreach($p in $Processes){
        if($p.Id -eq $PID){continue}
        try{if($p.HasExited){continue}}catch{}
        $name=$p.ProcessName
        if(@($Options.protectedProcesses) -contains $name){$result.Protected=$true;$result.Process=$name;return $result}
        $explicit=@($DetectionOptions.gameProcesses | ForEach-Object {$_ -replace '\.exe$',''}) -contains $name
        if($explicit){$result.Game=$true;$result.Process=$name;return $result}
        if(Test-ExcludedGameProcess $name $DetectionOptions @('idle','powershell','pwsh','wscript','dwm','explorer')){continue}
        try{$path=$p.Path}catch{$path=$null}
        if(-not $path -and $p.SessionId -gt 0){$identity=Get-ProcessIdentity $p.Id;if($identity){$path=$identity.Path}}
        foreach($root in $Roots){if(Test-PathUnderRoot $path $root.Path){$result.Game=$true;$result.Process=$name;return $result}}
        # A user application we cannot inspect must not be treated as proven safe.
        if(-not $path -and $p.SessionId -gt 0){
            # Short-lived Git/compiler processes can exit between enumeration and identity lookup.
            # Only an application that still exists is an unknown safety signal.
            if($p.Id -and -not (Get-Process -Id $p.Id -ErrorAction SilentlyContinue)){continue}
            $result.Known=$false;$result.UnknownProcesses+=($name+'#'+$p.Id)
        }
    }
    return $result
}
function Get-WorkstationSafety {
    param($Options,$DetectionOptions)
    $processes=@(Get-Process)
    $roots=@(Get-InstalledGameRoots $DetectionOptions)
    $guard=Get-StrictProcessProtection $processes $Options $DetectionOptions $roots
    $snapshot=@{};$times=[WorkstationNative]::Times();$clock=[Diagnostics.Stopwatch]::StartNew()
    foreach($p in $processes){try{$snapshot[$p.Id]=@($p.TotalProcessorTime.TotalSeconds,$p.StartTime.Ticks)}catch{}}
    $gpu=$null
    try {
        $samples=(Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction Stop).CounterSamples
        $engines=@{}
        foreach($s in $samples){
            $v=[double]$s.CookedValue
            if([double]::IsNaN($v) -or [double]::IsInfinity($v) -or $v -gt 101 -or $v -lt -1){throw 'Invalid GPU counter'}
            $key=$s.InstanceName -replace 'pid_\d+_',''
            if(-not $engines.ContainsKey($key)){$engines[$key]=0.0}
            $engines[$key]+=[Math]::Max(0.0,$v)
        }
        if($engines.Count){$gpu=[Math]::Min(100.0,[double](($engines.Values | Measure-Object -Maximum).Maximum))}
    } catch {$guard.Known=$false}
    if($clock.ElapsedMilliseconds -lt 1000){Start-Sleep -Milliseconds (1000-[int]$clock.ElapsedMilliseconds)}
    $after=[WorkstationNative]::Times();$elapsed=$clock.Elapsed.TotalSeconds;$clock.Stop()
    $cpu=$null;$processMax=0.0;$coreMax=0.0;$top=''
    if($times -and $after){$total=($after[1]-$times[1])+($after[2]-$times[2]);if($total -gt 0){$cpu=[Math]::Max(0.0,[Math]::Min(100.0,100.0*($total-($after[0]-$times[0]))/$total))}}
    foreach($p in @(Get-Process)){
        if($p.Id -eq $PID){continue}
        try{if($snapshot.ContainsKey($p.Id) -and $snapshot[$p.Id][1] -eq $p.StartTime.Ticks){
            $oneCore=[Math]::Max(0.0,100.0*($p.TotalProcessorTime.TotalSeconds-$snapshot[$p.Id][0])/$elapsed)
            $normalized=$oneCore/[Environment]::ProcessorCount
            if($normalized -gt $processMax){$processMax=$normalized;$top=$p.ProcessName}
            $coreMax=[Math]::Max($coreMax,$oneCore)
        }}catch{}
    }
    # Recheck processes after the load sample, so newly launched games cannot use its initial snapshot.
    $endGuard=Get-StrictProcessProtection @(Get-Process) $Options $DetectionOptions $roots
    $guard.Game=$guard.Game -or $endGuard.Game;$guard.Protected=$guard.Protected -or $endGuard.Protected
    if($endGuard.Process){$guard.Process=$endGuard.Process}
    $guard.UnknownProcesses=@($guard.UnknownProcesses+$endGuard.UnknownProcesses | Select-Object -Unique)
    $guard.Known=$guard.Known -and $endGuard.Known -and $null -ne $cpu -and $null -ne $gpu
    $guard.Cpu=$cpu;$guard.ProcessCpu=$processMax;$guard.SingleCore=$coreMax;$guard.Gpu=$gpu;$guard.TopCpuProcess=$top
    return $guard
}

function Invoke-WorkstationPowerCfg {
    param([string[]]$Arguments)
    $output=& powercfg.exe @Arguments 2>&1
    if($LASTEXITCODE -ne 0){throw "powercfg failed: $($Arguments -join ' '): $output"}
}
function Read-WorkstationPowerValues {
    $values=@{}
    $dcIdle=$null
    foreach($guid in @('bc5038f7-23e0-4960-96da-33abaf5935ec','893dee8e-2bef-41e0-89c6-b55d0929964c','75b0ae3f-bce0-45a7-8c89-c9611c25e100','75b0ae3f-bce0-45a7-8c89-c9611c25e101','5d76a2ca-e8c0-402f-a133-2158492d58ad')){
        $text=(& powercfg.exe /Q SCHEME_CURRENT SUB_PROCESSOR $guid 2>&1 | Out-String)
        if($LASTEXITCODE -ne 0){throw "Power setting unavailable: $guid"}
        $matches=[regex]::Matches($text,'0x([0-9a-fA-F]{8})')
        if($matches.Count -lt 2){throw "Power setting cannot be verified: $guid"}
        $values[$guid]=[Convert]::ToInt32($matches[$matches.Count-2].Groups[1].Value,16)
        if($guid -eq '5d76a2ca-e8c0-402f-a133-2158492d58ad'){$dcIdle=[Convert]::ToInt32($matches[$matches.Count-1].Groups[1].Value,16)}
    }
    return @{scheme=(Get-WorkstationScheme);values=$values;dcIdleDisable=$dcIdle}
}
function Get-WorkstationScheme {
    $schemeText=(& powercfg.exe /GETACTIVESCHEME | Out-String)
    if($LASTEXITCODE -ne 0){throw 'Cannot read active scheme'}
    $scheme=[regex]::Match($schemeText,'[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}').Value
    if(-not $scheme){throw 'Cannot read active scheme'}
    return $scheme
}
function Restore-WorkstationOverlay {
    param([string]$Root,[string]$Reason='恢复原参数')
    $path=Join-Path $Root 'workstation_state.json'
    if(-not (Test-Path -LiteralPath $path)){return}
    $state=Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if(-not $state.active){return}
    if($state.baseline.scheme -notmatch '^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'){throw 'Invalid recovery scheme'}
    Write-ProfileEvent 'workstation.restore.start' $Reason -Data @{enteredBy=$state.operationId;baseline=$state.baseline}
    foreach($guid in @('bc5038f7-23e0-4960-96da-33abaf5935ec','75b0ae3f-bce0-45a7-8c89-c9611c25e100','75b0ae3f-bce0-45a7-8c89-c9611c25e101')){
        $value=$state.baseline.values.$guid
        if($null -eq $value -or $value -lt 0 -or $value -gt 10000){throw 'Invalid recovery value'}
        Invoke-WorkstationPowerCfg @('/SETACVALUEINDEX',$state.baseline.scheme,'SUB_PROCESSOR',$guid,[string]$value)
    }
    $currentScheme=Get-WorkstationScheme
    if($currentScheme -eq $state.baseline.scheme){
        Invoke-WorkstationPowerCfg @('/SETACTIVE',$currentScheme)
        $verified=Read-WorkstationPowerValues
        foreach($guid in @('bc5038f7-23e0-4960-96da-33abaf5935ec','75b0ae3f-bce0-45a7-8c89-c9611c25e100','75b0ae3f-bce0-45a7-8c89-c9611c25e101')){if($verified.values[$guid] -ne $state.baseline.values.$guid){throw 'Restored CPU limits did not match snapshot'}}
    }
    $state.active=$false;$state.reason=$Reason;$state.observedAt=[DateTime]::UtcNow.ToString('o')
    Write-AtomicJson $path $state
    Write-ProfileEvent 'workstation.restore.success' $Reason -Data @{enteredBy=$state.operationId}
}
function Invoke-WorkstationEvaluation {
    param([string]$Root,[string]$CurrentMode,$DetectionOptions)
    $path=Join-Path $Root 'workstation_state.json'
    $previous=$null
    if(Test-Path $path){$previous=Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json}
    $json=Get-Content (Join-Path $Root 'settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $options=Get-WorkstationOptions $json
    $now=Get-BeijingTime
    $calendar=$null
    try{$calendar=Get-Content (Join-Path $Root "workdays.$($now.Year).json") -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json}catch{}
    $autoPath=Join-Path $Root 'auto_enabled.txt'
    $auto=(-not (Test-Path $autoPath)) -or (Get-Content $autoPath -Raw).Trim() -eq 'true'
    if(-not ('WorkstationNative' -as [type])){Add-Type -Path (Join-Path $Root 'PowerProfileWorkstation.cs')}
    $inputState=Get-WorkstationInputState
    $idle=$inputState.IdleSeconds;$onAC=$inputState.OnAC
    $baseline=$null;$stable=$false
    $baseMHz=$json.processorBaseMHz -as [double]
    $freq=$options.freqMax
    $minimum=$json.modes.Idle.min -as [int]
    $cap=if($baseMHz -gt 0){[int][Math]::Floor(100*$freq/$baseMHz)}else{0}
    $valid=($freq -ge 500 -and $freq -lt $json.modes.Idle.freqMax -and $freq -le 10000 -and $minimum -ge 5 -and $cap -ge $minimum+5 -and $cap -le 100 -and $options.awayMinutes -ge 20)
    $preflight=Get-WorkstationDecision $options $now $calendar $onAC $auto $CurrentMode $idle $null $valid $false
    if($valid -and ($preflight -eq 'SafetyUnavailable' -or $previous.active)){
        try{$baseline=Read-WorkstationPowerValues;$stable=$baseline.values['5d76a2ca-e8c0-402f-a133-2158492d58ad'] -eq 1 -and $baseline.dcIdleDisable -eq 1 -and $cap -ge $baseline.values['893dee8e-2bef-41e0-89c6-b55d0929964c']+5}catch{}
    }else{$stable=$valid}
    $safety=$null
    $preDecision=Get-WorkstationDecision $options $now $calendar $onAC $auto $CurrentMode $idle $null $stable $false
    if($preDecision -eq 'SafetyUnavailable'){$safety=Get-WorkstationSafety $options $DetectionOptions}
    # Input and power source are refreshed after the expensive sample.
    $inputState=Get-WorkstationInputState
    $idle=$inputState.IdleSeconds;$onAC=$inputState.OnAC;$now=Get-BeijingTime
    $quietContinuous=($previous -and $previous.code -in @('ConfirmingQuiet','Eligible') -and $previous.lastQuietAt -and ([DateTime]::UtcNow-([DateTime]$previous.lastQuietAt).ToUniversalTime()).TotalSeconds -le 45)
    $quietConfirmed=($quietContinuous -and $previous.quietSince -and ([DateTime]::UtcNow-([DateTime]$previous.quietSince).ToUniversalTime()).TotalSeconds -ge 10)
    $code=Get-WorkstationDecision $options $now $calendar $onAC $auto $CurrentMode $idle $safety $stable $quietConfirmed
    $reason=Get-WorkstationReason $code
    if($code -in @('GamePresent','ProtectedProcess') -and $safety.Process){$reason+='：'+$safety.Process}
    if($code -eq 'SafetyUnavailable' -and $safety.UnknownProcesses){$reason+='：无法读取 '+($safety.UnknownProcesses -join ', ')}
    if($code -ne 'Eligible' -and $previous.active){Restore-WorkstationOverlay $Root $reason;$previous=Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json}
    $state=@{active=[bool]$previous.active;code=$code;reason=$reason;observedAt=[DateTime]::UtcNow.ToString('o');idleSeconds=$idle;freqMax=$freq;operationId=$Script:ProfileOperationId;safety=$safety;lastQuietAt=$null;quietSince=$null;baseline=$previous.baseline}
    if($code -in @('ConfirmingQuiet','Eligible')){
        $state.lastQuietAt=[DateTime]::UtcNow.ToString('o')
        $state.quietSince=if($quietContinuous -and $previous.quietSince){$previous.quietSince}else{[DateTime]::UtcNow.ToString('o')}
    }
    if($code -eq 'Eligible' -and -not $state.active){
        # Journal the exact AC values before writing. Recovery survives an interrupted apply or restart.
        $baseline=Read-WorkstationPowerValues
        if($baseline.values['5d76a2ca-e8c0-402f-a133-2158492d58ad'] -ne 1){throw 'C-state guard changed during validation'}
        $state.baseline=$baseline;$state.active=$true
        Write-AtomicJson $path $state
        Write-ProfileEvent 'workstation.apply.start' '开始应用工作时段附加省电' -Data @{freqMax=$freq;maxPercent=$cap;baseline=$baseline;safety=$safety;idleSeconds=$idle}
        try{
            Invoke-WorkstationPowerCfg @('/SETACVALUEINDEX',$baseline.scheme,'SUB_PROCESSOR','bc5038f7-23e0-4960-96da-33abaf5935ec',[string]$cap)
            foreach($guid in @('75b0ae3f-bce0-45a7-8c89-c9611c25e100','75b0ae3f-bce0-45a7-8c89-c9611c25e101')){Invoke-WorkstationPowerCfg @('/SETACVALUEINDEX',$baseline.scheme,'SUB_PROCESSOR',$guid,[string]$freq)}
            Invoke-WorkstationPowerCfg @('/SETACTIVE',$baseline.scheme)
            $verified=Read-WorkstationPowerValues
            if($verified.scheme -ne $baseline.scheme -or $verified.values['bc5038f7-23e0-4960-96da-33abaf5935ec'] -ne $cap -or $verified.values['75b0ae3f-bce0-45a7-8c89-c9611c25e100'] -ne $freq -or $verified.values['75b0ae3f-bce0-45a7-8c89-c9611c25e101'] -ne $freq -or $verified.values['893dee8e-2bef-41e0-89c6-b55d0929964c'] -ne $baseline.values['893dee8e-2bef-41e0-89c6-b55d0929964c'] -or $verified.values['5d76a2ca-e8c0-402f-a133-2158492d58ad'] -ne 1 -or $verified.dcIdleDisable -ne 1){throw 'Applied CPU limits or stability settings did not pass readback verification'}
            Write-ProfileEvent 'workstation.apply.success' '附加省电已生效，原静音档保持' -Data @{freqMax=$freq;maxPercent=$cap}
        }catch{
            Write-ProfileEvent 'workstation.apply.failed' $_.Exception.Message 'ERROR'
            Restore-WorkstationOverlay $Root '应用失败，恢复原参数'
            throw
        }
    }
    if($previous.active -and $state.active){$state.operationId=$previous.operationId}
    Write-AtomicJson $path $state
    if(-not $previous -or $previous.code -ne $code -or $previous.active -ne $state.active){Write-ProfileEvent 'workstation.decision' $reason -Data $state}
}
function Get-WorkstationInputState {return @{IdleSeconds=[WorkstationNative]::IdleSeconds();OnAC=[WorkstationNative]::OnAC()}}
