# Energy monitoring is separate from settings.json and the power-control workers.
$Script:EnergyService=$null
$Script:EnergyDetails=$null
. (Join-Path $PSScriptRoot 'PowerProfileCloudHistoryUI.ps1')
function Initialize-EnergyService {
    if($Script:EnergyService){return}
    if(-not ('ProfileEnergyService' -as [type])){
        $source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'PowerProfileEnergy.cs'))
        $source+="`r`n"+[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'PowerProfileEnergyTimeline.cs'))
        $source+="`r`n"+[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'PowerProfileUsageLogs.cs'))
        $store=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'PowerProfileFileIO.cs')).Replace('ProfileSnapshotIO','ProfileEnergyStore')
        # Compile the existing atomic snapshot implementation into this isolated adapter.
        $usings=([regex]::Matches(($store+"`r`n"+$source),'(?m)^using [^;]+;') | ForEach-Object {$_.Value} | Select-Object -Unique) -join "`r`n"
        Add-Type -TypeDefinition ($usings+"`r`n"+(($store+"`r`n"+$source) -replace '(?m)^using ([^;]+);','')) -ReferencedAssemblies System.Drawing,System.Windows.Forms,System.Web.Extensions,System.Security,System.Core -ErrorAction Stop
    }
    $dataRoot=if($SettingsPath){Split-Path -Parent $SettingsPath}else{$ScriptDir}
    $Script:EnergyService=New-Object ProfileEnergyService $dataRoot
    $Script:EnergyLogTimer=New-Object Windows.Forms.Timer
    $Script:EnergyLogTimer.Interval=10000
    $Script:EnergyLogTimer.Add_Tick({
        foreach($entry in $Script:EnergyService.DrainEvents()){Write-ProfileEvent $entry[0] $entry[1] $entry[2] @{source='smart-plug';childOperationId=$entry[3]}}
        if($Script:EnergyDetails -and -not $Script:EnergyDetails.IsDisposed){Update-EnergyDetails}
    })
    $Script:EnergyLogTimer.Start()
    if(-not $Script:EnergyExitRegistered){
        [Windows.Forms.Application]::add_ApplicationExit({if($Script:EnergyService){$Script:EnergyService.Dispose()};if($Script:EnergyLogTimer){$Script:EnergyLogTimer.Stop();$Script:EnergyLogTimer.Dispose()}})
        $Script:EnergyExitRegistered=$true
    }
}
function Format-EnergyAmount($Value,[string]$Unit){if($null -eq $Value){return '等待累计'};return ('{0:N3} {1}' -f $Value,$Unit)}
function Format-EnergyCost($Value,$Price){if($null -eq $Price){return '待设置电价'};if($null -eq $Value){return '等待累计'};return ('¥{0:N2}' -f ([decimal]$Value*$Price))}
function Get-EnergyStatusText($State){
    if(-not $State.Configured){return '未连接'}
    if($State.Busy){return '正在连接 / 刷新'}
    if($State.Status -notin @('已连接','功率读数未提供')){return '连接异常'}
    if(([DateTime]::UtcNow-$State.ObservedAt).TotalSeconds -gt 90){return '数据过期'}
    if($null -eq $State.On){return '状态未知'}
    return $(if($State.On){'插座已开启'}else{'插座已关闭'})
}
function Update-EnergySummary {
    if(-not $Script:EnergyService -or -not $Script:Dashboard){return}
    $state=$Script:EnergyService.GetSnapshot();$fields=$Script:Dashboard.Tag.Fields
    $status=Get-EnergyStatusText $state;$fields.energyStatus.Text=$status
    $fresh=$state.ObservedAt -ne [DateTime]::MinValue -and ([DateTime]::UtcNow-$state.ObservedAt).TotalSeconds -le 90 -and $state.Status -in @('已连接','功率读数未提供')
    $fields.watts.Text=if($fresh -and $null -ne $state.Watts){'{0:N1} W' -f $state.Watts}else{'-- W'}
    $fields.energyToday.Text=Format-EnergyAmount $state.TodayKWh 'kWh'
    $fields.energyFee.Text=Format-EnergyCost $state.TodayKWh $state.Price
    $Script:DashboardTip.SetToolTip($fields.energyStatus,$state.Status)
    $Script:DashboardTip.SetToolTip($fields.energyToday,'按采集功率积分估算；仅计算有效连续采样，断线期间不补值。')
    $Script:DashboardTip.SetToolTip($fields.energyFee,"固定电价：$($state.Price) 元/度；基于已采集用电量估算。")
}
function New-EnergyButton([string]$Text,[int]$X,[int]$Y,[int]$Width=100){
    $button=New-Object Windows.Forms.Button;$button.Text=$Text;$button.SetBounds($X,$Y,$Width,29);$button.FlatStyle='Flat';$button.FlatAppearance.BorderColor=[Drawing.Color]::FromArgb(217,225,231);return $button
}
function Show-EnergyConnection {
    Initialize-EnergyService
    $form=New-Object Windows.Forms.Form;Initialize-ModernForm $form 'PowerProfile · 插座与电价' 480 390
    $form.Controls.Add((New-ModernLabel '米家智能插座 3 · 本地连接' 18 18 440))
    $hint=New-ModernLabel '需要同一局域网、插座 IP 与设备 Token。' 18 52 440;$hint.ForeColor=[Drawing.Color]::FromArgb(111,122,132);$form.Controls.Add($hint)
    $form.Controls.Add((New-ModernLabel '插座 IPv4' 18 93 140))
    $address=New-Object Windows.Forms.TextBox;$address.SetBounds(170,91,284,26);$address.Text=$Script:EnergyService.Address;$form.Controls.Add($address)
    $form.Controls.Add((New-ModernLabel '设备 Token' 18 136 140))
    $token=New-Object Windows.Forms.TextBox;$token.SetBounds(170,134,284,26);$token.UseSystemPasswordChar=$true;$form.Controls.Add($token)
    $form.Controls.Add((New-ModernLabel '已有 Token 时留空保留；清空 IP 可断开连接。' 18 175 440))
    $form.Controls.Add((New-ModernLabel '固定电价（元/度）' 18 216 160))
    $price=New-Object Windows.Forms.NumericUpDown;$price.DecimalPlaces=3;$price.Minimum=0;$price.Maximum=10;$price.Increment=[decimal]0.01;$price.SetBounds(200,214,170,26)
    $state=$Script:EnergyService.GetSnapshot();if($null -ne $state.Price){$price.Value=$state.Price};$form.Controls.Add($price)
    $note=New-ModernLabel 'Token 使用 Windows 当前用户加密；不会写入日志。' 18 258 440;$note.ForeColor=[Drawing.Color]::FromArgb(36,124,112);$form.Controls.Add($note)
    $help=New-EnergyButton '连接说明' 18 330 100;$form.Controls.Add($help)
    $help.Add_Click({
        [void][Windows.Forms.MessageBox]::Show("IP 可从路由器设备列表确认。设备 Token 是本地通信授权，不是米家账户密码。`r`n`r`n请勿把 Token 发到聊天中；在本窗口填写即可。不同固件可能禁用本地 MIOT。如连接失败，查看日志诊断，再决定是否改用小米官方 Home Assistant 接入。`r`n`r`n没有授权时仅显示未连接；不会自动扫描设备或登录账户。",'插座连接说明')
    })
    $save=New-EnergyButton '保存并连接' 324 330 130;$form.Controls.Add($save)
    $save.Add_Click({try{
        $Script:EnergyService.Configure($address.Text,$token.Text,[decimal]$price.Value);$token.Clear();$form.Close();Update-EnergySummary
    }catch{[void][Windows.Forms.MessageBox]::Show($_.Exception.GetBaseException().Message,'保存失败')}}.GetNewClosure())
    [void]$form.ShowDialog();$token.Clear();if($form.Icon){$form.Icon.Dispose()};$form.Dispose()
}
function Get-EnergyPeriodCoverage($State,[string]$Start){
    $cloudDays=0;$seconds=0.0
    foreach($item in $State.Days.GetEnumerator()){
        if([string]::CompareOrdinal($item.Key,$Start) -ge 0 -and [string]::CompareOrdinal($item.Key,$State.LocalDay) -le 0){
            if($item.Value.Source -eq 'MiHome'){$cloudDays++}else{$seconds+=$item.Value.Seconds}
        }
    }
    $local=if($seconds -lt 3600){'{0:N0} 分钟' -f ($seconds/60)}else{'{0:N1} 小时' -f ($seconds/3600)}
    if($cloudDays -gt 0){if($seconds -gt 0){return "米家 $cloudDays 天 + 估算 $local"};return "米家历史 · $cloudDays 天"}
    if($seconds -gt 0){return "本机估算 · 已采集 $local"}
    return '尚无连续采样 · 等待累计'
}
function Format-EnergyDuration($Seconds){
    if($null -eq $Seconds){return '未统计'}
    if($Seconds -eq 0){return '0 分钟'}
    if($Seconds -lt 60){return '<1 分钟'}
    $minutes=[int][Math]::Floor($Seconds/60);$hours=[int][Math]::Floor($minutes/60)
    if($hours -eq 0){return "$minutes 分钟"}
    return ('{0} 小时 {1:00} 分' -f $hours,($minutes%60))
}
function Format-EnergyCalendarDate([DateTime]$Date,[string]$Format='yyyy-MM-dd'){
    $weekday=@('周日','周一','周二','周三','周四','周五','周六')[[int]$Date.DayOfWeek]
    return ($Date.ToString($Format)+' '+$weekday)
}
function Update-EnergyRecordHint {
    if(-not $Script:EnergyDetails){return};$tag=$Script:EnergyDetails.Tag;$row=$tag.DailyGrid.CurrentRow
    if($row -and $row.Tag){$tag.Fields.recordHint.Text=$row.Tag;$Script:DashboardTip.SetToolTip($tag.Fields.recordHint,$row.Tag)}
}
function Update-EnergyDetails {
    param($State=$null)
    if(-not $Script:EnergyDetails -or $Script:EnergyDetails.IsDisposed){return}
    if($null -eq $State){$State=$Script:EnergyService.GetSnapshot()};$f=$Script:EnergyDetails.Tag.Fields
    $f.status.Text=Get-EnergyStatusText $state
    $fresh=$state.ObservedAt -ne [DateTime]::MinValue -and ([DateTime]::UtcNow-$state.ObservedAt).TotalSeconds -le 90 -and $state.Status -in @('已连接','功率读数未提供')
    $f.watts.Text=if($fresh -and $null -ne $state.Watts){'{0:N1} W' -f $state.Watts}else{'-- W'}
    $f.today.Text=Format-EnergyAmount $state.TodayKWh 'kWh';$f.week.Text=Format-EnergyAmount $state.WeekKWh 'kWh';$f.month.Text=Format-EnergyAmount $state.MonthKWh 'kWh';$f.fee.Text=Format-EnergyCost $state.MonthKWh $state.Price
    $f.price.Text=if($null -ne $state.Price){'固定电价：{0:N3} 元 / 度' -f $state.Price}else{'待设置电价'}
    $f.status.ForeColor=if($fresh){[Drawing.Color]::FromArgb(32,125,101)}elseif($state.Configured){[Drawing.Color]::FromArgb(173,107,35)}else{[Drawing.Color]::FromArgb(111,122,132)}
    $f.hourCost.Text=if($fresh -and $null -ne $state.Watts -and $null -ne $state.Price){'按当前功率 · 约 ¥{0:N3} / 小时' -f ($state.Watts/1000*$state.Price)}else{'有效采样后显示即时费用参考'}
    $f.dayCoverage.Text=Get-EnergyPeriodCoverage $state $state.LocalDay
    $f.weekCoverage.Text=Get-EnergyPeriodCoverage $state $state.WeekStart
    $f.monthCoverage.Text=Get-EnergyPeriodCoverage $state $state.MonthStart
    $f.dayFee.Text=Format-EnergyCost $state.TodayKWh $state.Price
    $f.weekFee.Text=Format-EnergyCost $state.WeekKWh $state.Price
    $Script:DashboardTip.SetToolTip($f.week,"北京时间 $($state.WeekStart) 至 $($state.LocalDay)；周一开始，已采集 $([Math]::Round($state.WeekSeconds/3600,1)) 小时。")
    $Script:DashboardTip.SetToolTip($f.month,"北京时间 $($state.MonthStart) 至 $($state.LocalDay)；自然月，已采集 $([Math]::Round($state.MonthSeconds/3600,1)) 小时。")
    $f.hint.Text=if($state.Configured){$state.Status}else{'尚未连接 · 点击“连接与电价”设置插座'}
    $Script:DashboardTip.SetToolTip($f.hint,$state.Status)
    $hasCloud=@($state.Days.Values | Where-Object {$_.Source -eq 'MiHome'}).Count -gt 0
    $f.coverage.Text='使用 / 游戏复用日志；高功耗含游戏档推算（估），不等于全部实测 ≥150 W；* 为部分覆盖。'
    $f.updated.Text=if($state.ObservedAt -ne [DateTime]::MinValue){"采样 $([TimeZoneInfo]::ConvertTimeFromUtc($state.ObservedAt,[TimeZoneInfo]::FindSystemTimeZoneById('China Standard Time')).ToString('HH:mm:ss')) · 每分钟更新"}else{'连接插座后开始采样'}
    $f.switch.Enabled=$fresh -and $null -ne $state.On -and -not $state.Busy
    $f.switch.Text=if($state.On -eq $false){'开启插座'}else{'关闭插座'};$f.refresh.Enabled=$state.Configured -and -not $state.Busy
    $Script:EnergyDetails.Tag.Chart.Points=$state.Points;$Script:EnergyDetails.Tag.Chart.Invalidate()
    Update-EnergyDailyRows $state
    Update-EnergySummary
}
function Update-EnergyDailyRows {
    param($State)
    $tag=$Script:EnergyDetails.Tag
    if(-not $tag.Range.SelectedItem -or -not $tag.Group.SelectedItem){return}
    $count=[int]$tag.Range.SelectedItem.Value;$view=[string]$tag.Group.SelectedItem.Value
    $key="$($State.ObservedAt.Ticks)|$($State.UsageUpdatedAt.Ticks)|$($State.LocalDay)|$($State.Price)|$view|$count|$($State.Days.Count)|$($State.MonthKWh)"
    if($tag.DailyKey -eq $key){return};$tag.DailyKey=$key
    $grid=$tag.DailyGrid;$scroll=$grid.FirstDisplayedScrollingRowIndex;$selectedDate=if($grid.CurrentRow){[string]$grid.CurrentRow.Cells[0].Value}else{''}
    $grid.Rows.Clear();$day=[DateTime]::ParseExact($State.LocalDay,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
    $totals=@{};$usage=@{};$periods=New-Object 'Collections.Generic.List[ProfileEnergyPeriod]'
    foreach($item in $State.UsageDays.GetEnumerator()){
        $date=[DateTime]::ParseExact($item.Key,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
        $start=switch($view){'Week'{$date.AddDays(-(([int]$date.DayOfWeek+6)%7))};'Month'{$date.AddDays(1-$date.Day)};default{$date}}
        $groupKey=$start.ToString('yyyy-MM-dd')
        if(-not $usage.ContainsKey($groupKey)){$usage[$groupKey]=@{Seconds=0.0;High=$null;Coverage=0.0;Game=$null;GameCoverage=0.0;FromLogs=$false;ModeGame=$null;Names=@();EffectiveHigh=$null;HighKnown=0.0}}
        $usage[$groupKey].Seconds+=$item.Value.Seconds
        if($null -ne $item.Value.HighPowerSeconds){$usage[$groupKey].High+=$item.Value.HighPowerSeconds;$usage[$groupKey].Coverage+=$item.Value.HighPowerCoverageSeconds}
        if($null -ne $item.Value.GameSeconds){$usage[$groupKey].Game+=$item.Value.GameSeconds;$usage[$groupKey].GameCoverage+=$item.Value.GameCoverageSeconds}
        if($item.Value.UsageSource){$usage[$groupKey].FromLogs=$true}
        if($null -ne $item.Value.ModeGameSeconds){$usage[$groupKey].ModeGame+=$item.Value.ModeGameSeconds}
        if($item.Value.GameNames){$usage[$groupKey].Names+=@($item.Value.GameNames -split '、')}
        $itemHigh=if($null -ne $item.Value.ModeGameSeconds){[Math]::Max([double]$item.Value.HighPowerSeconds,[double]$item.Value.ModeGameSeconds)}else{$item.Value.HighPowerSeconds}
        if($null -ne $itemHigh){$usage[$groupKey].EffectiveHigh+=$itemHigh}
        $usage[$groupKey].HighKnown+=[Math]::Max($item.Value.HighPowerCoverageSeconds,[double]$item.Value.ModeGameSeconds)
    }
    foreach($item in $State.Days.GetEnumerator()){
        $date=[DateTime]::ParseExact($item.Key,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
        $start=switch($view){'Week'{$date.AddDays(-(([int]$date.DayOfWeek+6)%7))};'Month'{$date.AddDays(1-$date.Day)};default{$date}}
        $groupKey=$start.ToString('yyyy-MM-dd')
        if(-not $totals.ContainsKey($groupKey)){$totals[$groupKey]=@{KWh=0.0;Seconds=0.0;CloudDays=0;LocalDays=0}}
        $totals[$groupKey].KWh+=$item.Value.KWh;$totals[$groupKey].Seconds+=$item.Value.Seconds
        if($item.Value.Source -eq 'MiHome'){$totals[$groupKey].CloudDays++}else{$totals[$groupKey].LocalDays++}
    }
    $grid.Columns[0].HeaderText=switch($view){'Week'{'周起始（周一）'};'Month'{'月份'};default{'日期 / 星期'}}
    for($i=0;$i -lt $count;$i++){
        $start=switch($view){'Week'{$day.AddDays(-(([int]$day.DayOfWeek+6)%7)-7*$i)};'Month'{$day.AddDays(1-$day.Day).AddMonths(-$i)};default{$day.AddDays(-$i)}}
        $groupKey=$start.ToString('yyyy-MM-dd');$date=if($view -eq 'Month'){$start.ToString('yyyy-MM')}else{Format-EnergyCalendarDate $start}
        $entry=if($totals.ContainsKey($groupKey)){$totals[$groupKey]}else{$null}
        $amount=if($null -ne $entry){'{0:N3}' -f $entry.KWh}else{'未采集'}
        $cost=if($null -ne $entry){Format-EnergyCost $entry.KWh $State.Price}else{'—'}
        $coverage=if($null -eq $entry){'—'}elseif($entry.CloudDays -gt 0){if($entry.LocalDays -gt 0){'历史 + 估算'}else{'米家历史'}}else{'本机估算'}
        $u=$usage[$groupKey];$online=if($u -and $u.Seconds -gt 0){Format-EnergyDuration $u.Seconds}else{'未采集'}
        $effectiveHigh=if($u){$u.EffectiveHigh}else{$null}
        $high=if($u -and $null -ne $effectiveHigh){(Format-EnergyDuration $effectiveHigh)+$(if($null -ne $u.ModeGame){' 估'})+$(if($u.HighKnown -lt $u.Seconds-0.5){' *'})}else{'未统计'}
        $game=if($u -and $null -ne $u.Game){(Format-EnergyDuration $u.Game)+$(if($null -ne $u.ModeGame){' 估'})+$(if($u.GameCoverage -lt $u.Seconds-0.5){' *'})}else{'未统计'}
        $index=$grid.Rows.Add([object[]]@($date,$amount,$cost,$coverage,$online,$high,$game))
        $usageSource=if($u -and $u.FromLogs){'运行日志 / 采样估算'}else{'本机监测'}
        $gameNames=if($u){(@($u.Names | Select-Object -Unique) -join '、')}else{''}
        $grid.Rows[$index].Tag=if($u){"$date · $usageSource $(Format-EnergyDuration $u.Seconds) · 高功耗实测覆盖 $(Format-EnergyDuration $u.Coverage) · 游戏识别覆盖 $(Format-EnergyDuration $u.GameCoverage)"+$(if($gameNames){" · 游戏：$gameNames"})+$(if($null -ne $u.ModeGame){'；估＝游戏档会话推算，不等于实测 ≥150 W'})}else{"$date · 没有本机监测时长；米家电量不能反推使用或游戏时长"}
        $grid.Rows[$index].Cells[4].ToolTipText='复用运行日志与有效采样估算；有运行日志时，即使插座断线仍可记录使用时长。日志缺口不补，重叠来源不相加。'
        $grid.Rows[$index].Cells[5].ToolTipText=if($u){"实测 ≥150 W：$(Format-EnergyDuration $u.High)；游戏档推算：$(Format-EnergyDuration $u.ModeGame)。同日取较大值再汇总，避免重叠相加；估算不是功率实测，不影响电量、电费。"}else{'没有实测或游戏档会话依据；不当作零。'}
        $grid.Rows[$index].Cells[6].ToolTipText='复用游戏识别及有游戏原因的进入 / 退出 Game 档日志重建会话，扣除已记录的休眠、关机；标“估”的包含会话推算。'+$(if($gameNames){" 游戏：$gameNames"})
        $period=New-Object ProfileEnergyPeriod;$period.Label=if($view -eq 'Month'){$start.ToString('yy-MM')}else{Format-EnergyCalendarDate $start 'MM-dd'}
        if($entry -and $null -ne $State.Price){$period.Cost=$entry.KWh*[double]$State.Price}
        if($u -and $u.Seconds -gt 0){$period.UsageHours=$u.Seconds/3600}
        if($u -and $null -ne $effectiveHigh){$period.HighHours=$effectiveHigh/3600;$period.HighCoverageHours=$u.Coverage/3600}
        if($u -and $null -ne $u.ModeGame){$period.ModeGameHours=$u.ModeGame/3600}
        if($u -and $null -ne $u.Game){$period.GameHours=$u.Game/3600;$period.GameCoverageHours=$u.GameCoverage/3600}
        $periods.Insert(0,$period)
        $weekend=$view -eq 'Day' -and $start.DayOfWeek -in @([DayOfWeek]::Saturday,[DayOfWeek]::Sunday)
        $grid.Rows[$index].Cells[0].ToolTipText=if($view -eq 'Week'){"$(Format-EnergyCalendarDate $start) 至 $(Format-EnergyCalendarDate $start.AddDays(6))（北京时间）；本周期截至今日"}elseif($view -eq 'Month'){"自然月 $date；本周期截至今日"}else{"北京时间 · $date"+$(if($weekend){' · 周末'})}
        if($weekend){
            $grid.Rows[$index].DefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(238,245,252)
            $grid.Rows[$index].Cells[0].Style.ForeColor=[Drawing.Color]::FromArgb(39,106,159)
            $grid.Rows[$index].Cells[0].Style.SelectionForeColor=[Drawing.Color]::FromArgb(39,106,159)
            $grid.Rows[$index].Cells[0].Style.Font=$grid.ColumnHeadersDefaultCellStyle.Font
        }
        if($null -eq $entry){foreach($column in @(1,2,3)){$grid.Rows[$index].Cells[$column].Style.ForeColor=[Drawing.Color]::FromArgb(133,142,150)}}
        if($date -eq $selectedDate){$grid.CurrentCell=$grid.Rows[$index].Cells[0]}
    }
    if($scroll -ge 0 -and $scroll -lt $grid.Rows.Count){$grid.FirstDisplayedScrollingRowIndex=$scroll}
    Update-EnergyRecordHint
    if($tag.Timeline){$tag.Timeline.Periods=$periods;$tag.Timeline.Invalidate()}
}
function Update-EnergyHistoryRange {
    param($Form)
    $tag=$Form.Tag;if(-not $tag.Group.SelectedItem){return}
    $range=$tag.Range;$range.Items.Clear()
    $choices=switch($tag.Group.SelectedItem.Value){'Week'{@(@(4,'近 4 周'),@(8,'近 8 周'),@(12,'近 12 周'))};'Month'{@(@(3,'近 3 个月'),@(6,'近 6 个月'),@(12,'近 12 个月'))};default{@(@(7,'近 7 天'),@(30,'近 30 天'),@(90,'近 90 天'))}}
    foreach($choice in $choices){[void]$range.Items.Add([PSCustomObject]@{Value=$choice[0];Label=$choice[1]})}
    $range.SelectedIndex=1;$tag.DailyKey='';Update-EnergyDetails
}
function Show-EnergyDetails {
    Initialize-EnergyService
    if($Script:EnergyDetails -and -not $Script:EnergyDetails.IsDisposed){$Script:EnergyDetails.Show();[ProfileVisual]::ActivateDashboard($Script:EnergyDetails.Handle);return}
    $form=New-Object Windows.Forms.Form;Initialize-ModernForm $form 'PowerProfile · 电费与用电' 1040 820
    $fields=@{}
    $title=New-ModernLabel '电费与用电' 20 16 340;$title.Font=New-Object Drawing.Font 'Microsoft YaHei UI',17,([Drawing.FontStyle]::Bold);$title.Height=36;$form.Controls.Add($title)
    $subtitle=New-ModernLabel '电脑专用插座 · 北京时间 · 固定电价估算' 22 57 530;$subtitle.ForeColor=[Drawing.Color]::FromArgb(111,122,132);$form.Controls.Add($subtitle)
    $fields.status=New-ModernLabel '未连接' 760 22 260;$fields.status.TextAlign='MiddleRight';$form.Controls.Add($fields.status)
    $fields.updated=New-ModernLabel '' 710 57 310;$fields.updated.TextAlign='MiddleRight';$fields.updated.Font=New-Object Drawing.Font 'Microsoft YaHei UI',8;$form.Controls.Add($fields.updated)
    $i=0
    foreach($row in @(@('今日','today','dayFee','dayCoverage'),@('本周 · 周一起','week','weekFee','weekCoverage'),@('本月 · 自然月','month','fee','monthCoverage'))){
        $card=New-Object Windows.Forms.Panel;$card.BackColor=[Drawing.Color]::White;$card.SetBounds((20+340*$i),88,320,124);$form.Controls.Add($card)
        $caption=New-ModernLabel $row[0] 18 12 280;$caption.Height=20;$caption.ForeColor=[Drawing.Color]::FromArgb(91,107,118);$card.Controls.Add($caption)
        $cost=New-ModernLabel '等待累计' 16 36 284;$cost.Font=New-Object Drawing.Font 'Segoe UI',23,([Drawing.FontStyle]::Bold);$cost.Height=40;$cost.ForeColor=[Drawing.Color]::FromArgb(29,93,131);$card.Controls.Add($cost);$fields[$row[2]]=$cost
        $value=New-ModernLabel '等待累计' 20 78 280;$value.Font=New-Object Drawing.Font 'Segoe UI',10;$value.Height=22;$card.Controls.Add($value);$fields[$row[1]]=$value
        $coverage=New-ModernLabel '' 20 103 280;$coverage.Height=18;$coverage.Font=New-Object Drawing.Font 'Microsoft YaHei UI',8;$coverage.ForeColor=[Drawing.Color]::FromArgb(111,122,132);$card.Controls.Add($coverage);$fields[$row[3]]=$coverage
        $i++
    }
    $curve=New-Object Windows.Forms.Panel;$curve.BackColor=[Drawing.Color]::White;$curve.SetBounds(20,226,660,190);$form.Controls.Add($curve)
    $curve.Controls.Add((New-ModernLabel '费用与使用趋势' 18 14 180))
    $chart=New-Object ProfileEnergyChart;$chart.Font=New-Object Drawing.Font 'Segoe UI',8;$chart.SetBounds(10,51,640,129);$curve.Controls.Add($chart)
    $timeline=New-Object ProfileEnergyTimeline;$timeline.Font=New-Object Drawing.Font 'Microsoft YaHei UI',8;$timeline.SetBounds(10,51,640,129);$curve.Controls.Add($timeline);$chart.Visible=$false
    $chartMode=New-WorkstationCombo $curve 210 12 134 @(@('History','费用与时长'),@('Power','实时功率')) 'History'
    $chartMode.Add_SelectedIndexChanged({
        if(-not $Script:EnergyDetails){return};$tag=$Script:EnergyDetails.Tag;$power=$tag.ChartMode.SelectedItem.Value -eq 'Power'
        $tag.Chart.Visible=$power;$tag.Timeline.Visible=-not $power;$tag.HourButton.Visible=$power;$tag.TodayButton.Visible=$power
    })
    $hour=New-EnergyButton '近 1 小时' 350 12 112;$today=New-EnergyButton '今日' 470 12 80;$curve.Controls.Add($hour);$curve.Controls.Add($today)
    $hour.Visible=$false;$today.Visible=$false
    $hour.Add_Click({Set-EnergyChartRange $false});$today.Add_Click({Set-EnergyChartRange $true})
    $meter=New-Object Windows.Forms.Panel;$meter.BackColor=[Drawing.Color]::White;$meter.SetBounds(694,226,326,190);$form.Controls.Add($meter)
    $meter.Controls.Add((New-ModernLabel '实时输入功率' 18 14 242))
    $fields.watts=New-ModernLabel '-- W' 16 42 288;$fields.watts.Font=New-Object Drawing.Font 'Segoe UI',27,([Drawing.FontStyle]::Bold);$fields.watts.Height=50;$fields.watts.ForeColor=[Drawing.Color]::FromArgb(29,93,131);$meter.Controls.Add($fields.watts)
    $meaning=New-ModernLabel '含电脑、适配器损耗与电池充电' 18 96 288;$meaning.Font=New-Object Drawing.Font 'Microsoft YaHei UI',8;$meaning.ForeColor=[Drawing.Color]::FromArgb(111,122,132);$meter.Controls.Add($meaning)
    $fields.price=New-ModernLabel '' 18 126 288;$meter.Controls.Add($fields.price)
    $fields.hourCost=New-ModernLabel '' 18 158 288;$fields.hourCost.Font=New-Object Drawing.Font 'Microsoft YaHei UI',8;$fields.hourCost.ForeColor=[Drawing.Color]::FromArgb(111,122,132);$meter.Controls.Add($fields.hourCost)
    $daily=New-Object Windows.Forms.Panel;$daily.BackColor=[Drawing.Color]::White;$daily.SetBounds(20,430,1000,306);$form.Controls.Add($daily)
    $daily.Controls.Add((New-ModernLabel '用电账目' 18 13 220))
    $group=New-WorkstationCombo $daily 688 10 124 @(@('Day','按日'),@('Week','按周'),@('Month','按月')) 'Day'
    $range=New-WorkstationCombo $daily 824 10 158 @(@(7,'近 7 天'),@(30,'近 30 天'),@(90,'近 90 天')) 30
    $grid=New-Object Windows.Forms.DataGridView;$grid.SetBounds(12,48,976,234);$grid.ReadOnly=$true;$grid.AllowUserToAddRows=$false;$grid.AllowUserToDeleteRows=$false;$grid.AllowUserToResizeRows=$false;$grid.RowHeadersVisible=$false;$grid.MultiSelect=$false;$grid.SelectionMode='FullRowSelect';$grid.AutoSizeColumnsMode='Fill';$grid.BackgroundColor=[Drawing.Color]::White;$grid.BorderStyle='None';$grid.GridColor=[Drawing.Color]::FromArgb(234,239,242);$grid.EnableHeadersVisualStyles=$false;$grid.ColumnHeadersDefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(244,247,249);$grid.ColumnHeadersDefaultCellStyle.ForeColor=[Drawing.Color]::FromArgb(91,107,118);$grid.ColumnHeadersDefaultCellStyle.WrapMode='False';$grid.ColumnHeadersHeight=32;$grid.ColumnHeadersHeightSizeMode='DisableResizing';$grid.RowTemplate.Height=32;$grid.DefaultCellStyle.SelectionBackColor=[Drawing.Color]::FromArgb(228,240,247);$grid.DefaultCellStyle.SelectionForeColor=[Drawing.Color]::FromArgb(42,55,67);$grid.AlternatingRowsDefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(249,251,252);$grid.CellBorderStyle='SingleHorizontal'
    foreach($column in @(@('date','日期',145),@('amount','用电量 (kWh)',128),@('cost','电费',100),@('coverage','电量来源',130),@('usage','使用时长',155),@('high','高功耗(含估)',155),@('game','游戏时长',155))){$index=$grid.Columns.Add($column[0],$column[1]);$grid.Columns[$index].FillWeight=$column[2];$grid.Columns[$index].SortMode='NotSortable';$grid.Columns[$index].DefaultCellStyle.Padding=New-Object Windows.Forms.Padding 8,0,8,0;if($index -gt 0){$grid.Columns[$index].DefaultCellStyle.Alignment='MiddleRight';$grid.Columns[$index].HeaderCell.Style.Alignment='MiddleRight'}}
    $grid.Columns[4].DefaultCellStyle.ForeColor=[Drawing.Color]::FromArgb(32,139,111);$grid.Columns[5].DefaultCellStyle.ForeColor=[Drawing.Color]::FromArgb(181,105,26)
    $grid.Columns[6].DefaultCellStyle.ForeColor=[Drawing.Color]::FromArgb(130,83,176)
    $grid.Columns[2].DefaultCellStyle.Font=New-Object Drawing.Font 'Segoe UI',10,([Drawing.FontStyle]::Bold)
    $grid.ColumnHeadersDefaultCellStyle.Font=New-Object Drawing.Font 'Microsoft YaHei UI',9,([Drawing.FontStyle]::Bold)
    $grid.Columns[3].DefaultCellStyle.Alignment='MiddleCenter';$grid.Columns[3].HeaderCell.Style.Alignment='MiddleCenter'
    $grid.ClipboardCopyMode='EnableAlwaysIncludeHeaderText'
    foreach($pair in @(@(2,[Drawing.Color]::FromArgb(39,106,159)),@(4,[Drawing.Color]::FromArgb(32,139,111)),@(5,[Drawing.Color]::FromArgb(181,105,26)),@(6,[Drawing.Color]::FromArgb(130,83,176)))){$grid.Columns[$pair[0]].HeaderCell.Style.ForeColor=$pair[1]}
    $fields.recordHint=New-ModernLabel '选择一行查看统计覆盖情况；* 表示仅覆盖部分使用时间' 14 286 972;$fields.recordHint.Height=18;$fields.recordHint.Font=New-Object Drawing.Font 'Microsoft YaHei UI',8;$fields.recordHint.ForeColor=[Drawing.Color]::FromArgb(111,122,132);$fields.recordHint.AutoEllipsis=$true;$daily.Controls.Add($fields.recordHint)
    $grid.Add_CurrentCellChanged({Update-EnergyRecordHint})
    $daily.Controls.Add($grid);$range.Add_SelectedIndexChanged({if($Script:EnergyDetails){$Script:EnergyDetails.Tag.DailyKey='';Update-EnergyDetails}})
    $group.Add_SelectedIndexChanged({if($Script:EnergyDetails){Update-EnergyHistoryRange $Script:EnergyDetails}})
    $fields.coverage=New-ModernLabel '' 22 744 996;$fields.coverage.Height=20;$fields.coverage.Font=New-Object Drawing.Font 'Microsoft YaHei UI',8;$fields.coverage.ForeColor=[Drawing.Color]::FromArgb(111,122,132);$form.Controls.Add($fields.coverage)
    $fields.hint=New-ModernLabel '' 22 784 394;$fields.hint.Height=22;$fields.hint.Font=New-Object Drawing.Font 'Microsoft YaHei UI',8;$fields.hint.AutoEllipsis=$true;$form.Controls.Add($fields.hint)
    $setup=New-EnergyButton '连接与电价' 426 780 120;$form.Controls.Add($setup);$setup.Add_Click({Show-EnergyConnection;Update-EnergyDetails})
    $cloudButton=New-EnergyButton '补录米家历史' 558 780 136;$form.Controls.Add($cloudButton);$cloudButton.Add_Click({Show-CloudHistory;Update-EnergyDetails})
    $fields.refresh=New-EnergyButton '刷新数据' 706 780 100;$form.Controls.Add($fields.refresh);$fields.refresh.Add_Click({$Script:EnergyService.Refresh();Update-EnergyDetails})
    $fields.switch=New-EnergyButton '关闭插座' 818 780 98;$form.Controls.Add($fields.switch)
    $fields.switch.Add_Click({
        $state=$Script:EnergyService.GetSnapshot();if(-not $state.Configured -or $state.Busy -or $null -eq $state.On){return}
        $on=-not $state.On
        $message=if($on){'确认开启电脑插座？'}else{'确认关闭电脑插座？这会切断适配器供电，电脑将转为电池供电。不会触发自动休眠。请确认电池可用，避免远程连接中断。'}
        if([Windows.Forms.MessageBox]::Show($message,'插座控制','YesNo','Question','Button2') -eq 'Yes'){$Script:EnergyService.SetSwitch($on);Update-EnergyDetails}
    })
    $close=New-EnergyButton '关闭' 928 780 92;$form.Controls.Add($close);$close.Add_Click({$Script:EnergyDetails.Close()})
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=1000;$timer.Add_Tick({try{Update-EnergyDetails}catch{Write-ProfileEvent 'ui.energy.refresh.failed' $_.Exception.Message 'ERROR'}})
    $form.Tag=@{Fields=$fields;Chart=$chart;Timeline=$timeline;ChartMode=$chartMode;Timer=$timer;DailyGrid=$grid;Range=$range;Group=$group;DailyKey='';HourButton=$hour;TodayButton=$today};$Script:EnergyDetails=$form
    $form.Add_FormClosed({param($sender,$args) $sender.Tag.Timer.Stop();$sender.Tag.Timer.Dispose();if($sender.Icon){$sender.Icon.Dispose()};$Script:EnergyDetails=$null})
    Set-EnergyChartRange $false
    Update-EnergyDetails;$timer.Start();$form.Show();[ProfileVisual]::ActivateDashboard($form.Handle)
    Write-ProfileEvent 'ui.energy.open' '用电详情已打开' -Data @{handle=$form.Handle.ToInt64();historyView=$group.SelectedItem.Value}
}
function Set-EnergyChartRange([bool]$Today){
    $tag=$Script:EnergyDetails.Tag;$tag.Chart.Today=$Today;$tag.Chart.Invalidate()
    foreach($pair in @(@($tag.HourButton,(-not $Today)),@($tag.TodayButton,$Today))){
        $pair[0].BackColor=if($pair[1]){[Drawing.Color]::FromArgb(228,240,247)}else{[Drawing.Color]::White}
        $pair[0].ForeColor=if($pair[1]){[Drawing.Color]::FromArgb(29,93,131)}else{[Drawing.Color]::FromArgb(91,107,118)}
    }
}
