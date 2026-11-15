# Pure presentation models. No device commands or power-plan changes.
function Get-WorkspaceRoot {if($SettingsPath){return Split-Path -Parent $SettingsPath};return $ScriptDir}
function Read-WorkspaceJson([string]$Path,$Default=$null){try{if(Test-Path -LiteralPath $Path){return Read-AtomicJson $Path}}catch{};return $Default}
function Get-WorkspacePreferences([string]$Root=(Get-WorkspaceRoot)){
    $value=Read-WorkspaceJson (Join-Path $Root 'workspace.settings.json')
    $theme=if($value.theme -in @('System','Light','Dark')){$value.theme}else{'System'}
    $metrics=if($null -ne $value.metrics){@($value.metrics | Where-Object {$_ -in @('mode','power','cost','usage','game','next')} | Select-Object -Unique)}else{@('mode','power','cost','usage','game','next')}
    $devices=if($value.devices){$value.devices}else{[PSCustomObject]@{}}
    $textScale=if($value.textScale -in @(100,125,150)){[int]$value.textScale}else{100}
    return [PSCustomObject]@{theme=$theme;textScale=$textScale;metrics=$metrics;devices=$devices}
}
function Save-WorkspacePreferences($Preferences,[string]$Root=(Get-WorkspaceRoot)){Write-AtomicJson (Join-Path $Root 'workspace.settings.json') $Preferences -Pretty}
function Get-WorkspaceEnergyData($State,[string]$Group='Day',[int]$Count=30,$From=$null,$To=$null,[int]$DayType=0){
    $today=[DateTime]::ParseExact($State.LocalDay,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
    $anchor=if($null -ne $To){([DateTime]$To).Date}else{$today}
    if($null -ne $From){$From=([DateTime]$From).Date;if($From -gt $anchor){throw '开始日期不能晚于结束日期。'};if(($anchor-$From).Days -ge 400){throw '最多查看 400 天。'};$Count=switch($Group){'Week'{[int][Math]::Floor((($anchor.AddDays(-(([int]$anchor.DayOfWeek+6)%7)))-$From.AddDays(-(([int]$From.DayOfWeek+6)%7))).TotalDays/7)+1};'Month'{($anchor.Year-$From.Year)*12+$anchor.Month-$From.Month+1};default{($anchor-$From).Days+1}}}
    $totals=@{};$usage=@{}
    foreach($item in $State.Days.GetEnumerator()){
        $day=[DateTime]::ParseExact($item.Key,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
        if(($null -ne $From -and $day -lt $From) -or $day -gt $anchor -or -not (Test-InsightsDay $day $DayType)){continue}
        $start=switch($Group){'Week'{$day.AddDays(-(([int]$day.DayOfWeek+6)%7))};'Month'{$day.AddDays(1-$day.Day)};default{$day}}
        $key=$start.ToString('yyyy-MM-dd');if(-not $totals.ContainsKey($key)){$totals[$key]=@{KWh=0.0;Seconds=0.0;Cloud=0;Local=0}}
        $totals[$key].KWh+=$item.Value.KWh;$totals[$key].Seconds+=$item.Value.Seconds
        if($item.Value.Source -eq 'MiHome'){$totals[$key].Cloud++}else{$totals[$key].Local++}
    }
    foreach($item in $State.UsageDays.GetEnumerator()){
        $day=[DateTime]::ParseExact($item.Key,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
        if(($null -ne $From -and $day -lt $From) -or $day -gt $anchor -or -not (Test-InsightsDay $day $DayType)){continue}
        $start=switch($Group){'Week'{$day.AddDays(-(([int]$day.DayOfWeek+6)%7))};'Month'{$day.AddDays(1-$day.Day)};default{$day}}
        $key=$start.ToString('yyyy-MM-dd');if(-not $usage.ContainsKey($key)){$usage[$key]=@{Seconds=0.0;High=$null;Coverage=0.0;Known=0.0;Game=$null;GameCoverage=0.0;Mode=$null;Effective=$null;Names=@();Logs=$false}}
        $u=$usage[$key];$d=$item.Value;$u.Seconds+=$d.Seconds
        if($null -ne $d.HighPowerSeconds){$u.High+=$d.HighPowerSeconds};$u.Coverage+=$d.HighPowerCoverageSeconds
        if($null -ne $d.GameSeconds){$u.Game+=$d.GameSeconds};$u.GameCoverage+=$d.GameCoverageSeconds
        if($null -ne $d.ModeGameSeconds){$u.Mode+=$d.ModeGameSeconds;$u.Effective+=[Math]::Max([double]$d.HighPowerSeconds,[double]$d.ModeGameSeconds)}elseif($null -ne $d.HighPowerSeconds){$u.Effective+=$d.HighPowerSeconds}
        $u.Known+=[Math]::Max($d.HighPowerCoverageSeconds,[double]$d.ModeGameSeconds)
        if($d.GameNames){$u.Names+=@($d.GameNames -split '、')};if($d.UsageSource){$u.Logs=$true}
    }
    $rows=New-Object 'Collections.Generic.List[ProfileLedgerView]';$periods=New-Object 'Collections.Generic.List[ProfileEnergyPeriod]';$details=@{};$known=0;$missing=0;$estimated=0
    for($i=0;$i -lt $Count;$i++){
        $start=switch($Group){'Week'{$anchor.AddDays(-(([int]$anchor.DayOfWeek+6)%7)-7*$i)};'Month'{$anchor.AddDays(1-$anchor.Day).AddMonths(-$i)};default{$anchor.AddDays(-$i)}}
        $key=$start.ToString('yyyy-MM-dd');$d=$totals[$key];$u=$usage[$key];$row=New-Object ProfileLedgerView;$row.Key=$key
        $row.PeriodStart=$start;$row.PeriodEnd=switch($Group){'Week'{$start.AddDays(6)};'Month'{$start.AddMonths(1).AddDays(-1)};default{$start}}
        $row.Date=if($Group -eq 'Day'){Format-EnergyCalendarDate $start}else{(Format-EnergyCalendarDate $start)+' — '+(Format-EnergyCalendarDate $row.PeriodEnd)}
        if($d){$row.KWhNumber=$d.KWh;if($null -ne $State.Price){$row.CostNumber=$d.KWh*[double]$State.Price}}
        if($u){$row.UsageSeconds=$u.Seconds;$row.HighSeconds=$u.Effective;$row.GameSeconds=$u.Game}
        $row.Energy=if($d){'{0:N3}' -f $d.KWh}else{'未采集'};$row.Cost=if($d){Format-EnergyCost $d.KWh $State.Price}else{'—'}
        $row.Source=if(-not $d){'无电量记录'}elseif($d.Cloud -gt 0 -and $d.Local -gt 0){'米家历史 + 本机积分'}elseif($d.Cloud -gt 0){'米家历史'}else{'本机功率积分'}
        $row.Usage=if($u){Format-EnergyDuration $u.Seconds}else{'未采集'}
        $row.High=if($u -and $null -ne $u.Effective){(Format-EnergyDuration $u.Effective)+$(if($null -ne $u.Mode){' 估'})+$(if($u.Known -lt $u.Seconds-0.5){' *'})}else{'未统计'}
        $row.Game=if($u -and $null -ne $u.Game){(Format-EnergyDuration $u.Game)+$(if($null -ne $u.Mode){' 估'})+$(if($u.GameCoverage -lt $u.Seconds-0.5){' *'})}else{'未统计'}
        $row.Names=if($u){(@($u.Names|Select-Object -Unique) -join '、')}else{''};$row.Estimated=$u -and $null -ne $u.Mode;$row.Missing=-not $d
        $timeSource=if($u.Logs){'运行日志 / 有效采样'}else{'有效监测采样'}
        $row.Explanation="$($row.Date)`r`n电量来源：$($row.Source)；本机功率覆盖 $(Format-EnergyDuration $(if($d){$d.Seconds}else{$null}))。`r`n使用时长依据：$timeSource，$(Format-EnergyDuration $(if($u){$u.Seconds}else{$null}))。`r`n实测 ≥150 W：$(Format-EnergyDuration $(if($u){$u.High}else{$null}))；实测覆盖：$(Format-EnergyDuration $(if($u){$u.Coverage}else{$null}))。`r`n游戏档会话推算：$(Format-EnergyDuration $(if($u){$u.Mode}else{$null}))；游戏识别覆盖：$(Format-EnergyDuration $(if($u){$u.GameCoverage}else{$null}))。`r`n同日高功耗取实测 / 会话推算较大值再汇总；推算不等于实测 ≥150 W，不补造电量或电费。缺失不代表零。"+$(if($row.Names){"`r`n游戏：$($row.Names)"})
        $details[$key]=$row.Explanation;$rows.Add($row);if($d){$known++}else{$missing++};if($row.Estimated){$estimated++}
        $period=New-Object ProfileEnergyPeriod;$period.Key=$key;$period.Label=if($Group -eq 'Month'){$start.ToString('yy-MM')}else{Format-EnergyCalendarDate $start 'MM-dd'}
        if($d -and $null -ne $State.Price){$period.Cost=$d.KWh*[double]$State.Price}
        if($u){$period.UsageHours=$u.Seconds/3600;if($null -ne $u.Effective){$period.HighHours=$u.Effective/3600};$period.HighCoverageHours=$u.Coverage/3600;if($null -ne $u.Game){$period.GameHours=$u.Game/3600};$period.GameCoverageHours=$u.GameCoverage/3600;if($null -ne $u.Mode){$period.ModeGameHours=$u.Mode/3600}}
        $periods.Insert(0,$period)
    }
    return @{Rows=$rows;Periods=$periods;Details=$details;Summary="电量记录 $known 个周期 · 无电量 $missing 个周期 · 含会话推算 $estimated 个周期。选择日期查看来源及覆盖；估＝会话推算，*＝部分覆盖。"}
}
function Get-WorkspaceSchedule($Config,$Runtime,[DateTime]$Start,[DateTime]$Now){
    $end=$Start.Date.AddDays(7);$slots=New-Object 'Collections.Generic.List[ProfileScheduleSlot]';$next=@{};$conflicts=@{}
    $rules=@($Config.rules)
    for($i=0;$i -lt $rules.Count;$i++){for($j=$i+1;$j -lt $rules.Count;$j++){if(Test-HubRulesConflict $rules[$i] $rules[$j]){$conflicts[$rules[$i].id]=$true;$conflicts[$rules[$j].id]=$true}}}
    foreach($r in $rules){
        $state=$Runtime.($r.id);$paused=-not $Config.enabled -or -not $r.enabled;$points=@()
        if($r.mode -eq 'at'){
            $at=(Get-HubRunAt $r).DateTime
            if(-not $state.completed -and $at -ge $Now.AddSeconds(-120)){$points+=,@($at,$at.AddMinutes(8),$true)}
        }elseif($r.mode -eq 'guard' -and $null -eq $r.endMinute -and $state.latched){$points+=,@($Start.Date,$end,$false)}
        else{
            # Include the previous day's start for guards crossing midnight.
            for($day=$Start.Date.AddDays(-1);$day -lt $end;$day=$day.AddDays(1)){
                $iso=if([int]$day.DayOfWeek -eq 0){7}else{[int]$day.DayOfWeek};if((Get-HubDays $r) -notcontains $iso){continue}
                $a=$day.AddMinutes([int]$r.startMinute)
                if($r.mode -eq 'guard' -and $null -eq $r.endMinute -and $day -lt $Now.Date){continue}
                $b=if($r.mode -eq 'once'){$a.AddMinutes(8)}elseif($null -eq $r.endMinute){$end}else{$day.AddMinutes([int]$r.endMinute)+$(if($r.endMinute -lt $r.startMinute){[TimeSpan]::FromDays(1)}else{[TimeSpan]::Zero})}
                if($b -gt $Start -and $a -lt $end){$points+=,@($a,$b,($r.mode -eq 'once'))}
                if($r.mode -eq 'guard' -and $null -eq $r.endMinute){break}
            }
        }
        foreach($point in $points){
            $slot=New-Object ProfileScheduleSlot;$slot.Id=$r.id;$slot.Device=$r.did;$slot.Name=$r.name;$slot.Start=$point[0];$slot.End=$point[1];$slot.Instant=$point[2];$slot.On=$r.value;$slot.Paused=$paused;$slot.Conflict=$conflicts.ContainsKey($r.id);$slot.Status=if($paused){'已暂停'}elseif($slot.Conflict){'相反任务存在冲突'}elseif($state.message){$state.message}else{'等待执行'}
            if($slot.End -gt $Start -and $slot.Start -lt $end){$slots.Add($slot)}
            $eligible=-not $paused -and -not $slot.Conflict
            if($r.mode -eq 'once' -and $slot.Start.Date -eq $Now.Date -and $state.executedDay -eq $Now.ToString('yyyy-MM-dd')){$eligible=$false}
            if($eligible -and (($slot.Instant -and $slot.Start -ge $Now.AddMinutes(-$(if($r.mode -eq 'at'){2}else{10}))) -or (-not $slot.Instant -and $slot.End -gt $Now))){
                $when=if($slot.Start -lt $Now){$Now}else{$slot.Start}
                if(-not $next.ContainsKey($r.id) -or $when -lt $next[$r.id]){$next[$r.id]=$when}
            }
        }
    }
    return @{Slots=$slots;Next=$next;Conflicts=$conflicts}
}
function Get-WorkspaceHub {
    $root=Get-WorkspaceRoot;$status=Read-WorkspaceJson (Join-Path $root '.codex\device-hub\status.json')
    $fresh=$false;if($status.observedAt){try{$age=([DateTime]::UtcNow-([DateTime]$status.observedAt).ToUniversalTime()).TotalSeconds;$fresh=$age -ge 0 -and $age -lt 90}catch{}}
    return @{Status=$status;Fresh=$fresh;Config=(Get-DeviceHubConfig)}
}
function Get-WorkspaceDevices($Hub,$Preferences,$Energy,[hashtable]$Next,[string]$Search='',[string]$Room='全部分组',[bool]$Favorites=$false){
    $list=New-Object 'Collections.Generic.List[ProfileDeviceView]'
    foreach($d in @($Hub.Status.devices)){
        $p=$Preferences.devices.($d.did);$name=if($p.alias){[string]$p.alias}else{[string]$d.name};$group=if($p.room){[string]$p.room}else{'未分组'}
        if($Favorites -and -not $p.favorite){continue};if($Room -ne '全部分组' -and $Room -ne $group){continue};if($Search -and ("$name $($d.name) $($d.model)".IndexOf($Search,[StringComparison]::OrdinalIgnoreCase) -lt 0)){continue}
        $view=New-Object ProfileDeviceView;$view.Id=$d.did;$view.Name=$name;$view.Model=$d.model;$view.Room=$group;$view.Favorite=[bool]$p.favorite;$view.ComputerPower=[bool]$d.computerPower
        $deviceFresh=$false;if($d.observedAt){$age=([DateTime]::UtcNow-([DateTime]$d.observedAt).ToUniversalTime()).TotalSeconds;$deviceFresh=$age -ge 0 -and $age -le 90}
        $view.Status=if(-not $Hub.Fresh){'? 中枢响应过期'}elseif(-not $d.switch){'○ 只读设备'}elseif(-not $deviceFresh){'? 设备读数未知 / 过期'}elseif($null -eq $d.state){'? 状态未知'}elseif($d.state){'● 已开启 · 状态已读回'}else{'○ 已关闭 · 状态已读回'}
        if(-not $Hub.Config.enabled){$view.Status+=' · 已暂停'}
        $view.CanControl=$Hub.Config.enabled -and $Hub.Fresh -and [bool]$d.switch
        $powerFresh=$Energy.ObservedAt -ne [DateTime]::MinValue -and ([DateTime]::UtcNow-$Energy.ObservedAt).TotalSeconds -le 90
        $view.Details=if($d.computerPower -and $powerFresh -and $null -ne $Energy.Watts){'{0:N1} W · 电脑供电插座' -f $Energy.Watts}elseif($d.computerPower){'电脑供电插座 · 断电需确认'}else{'功率 / 电量未提供'}
        $taskTimes=@($Hub.Config.rules|Where-Object {$_.did -eq $d.did -and $Next.ContainsKey($_.id)}|ForEach-Object {$Next[$_.id]}|Sort-Object)
        $holding=@($Hub.Config.rules|Where-Object {$_.did -eq $d.did -and $_.enabled -and $_.mode -eq 'guard' -and $Hub.Status.rules.($_.id).entered -and $Hub.Status.rules.($_.id).active})
        $view.Next=if($holding.Count -and $Hub.Fresh -and $Hub.Config.enabled){'正在保持：'+$holding[0].name}elseif($taskTimes.Count){'下次 '+(Format-EnergyCalendarDate $taskTimes[0] 'MM-dd')+' '+$taskTimes[0].ToString('HH:mm')}else{'暂无待执行任务'};$list.Add($view)
    }
    return ,$list
}
