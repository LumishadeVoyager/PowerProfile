# Energy monitoring is separate from settings.json and the power-control workers.
$Script:EnergyService=$null
$Script:EnergyDetails=$null
function Initialize-EnergyService {
    if($Script:EnergyService){return}
    if(-not ('ProfileEnergyService' -as [type])){
        $source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'PowerProfileEnergy.cs'))
        $store=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'PowerProfileFileIO.cs')).Replace('ProfileSnapshotIO','ProfileEnergyStore')
        # Compile the existing atomic snapshot implementation into this isolated adapter.
        $usings=([regex]::Matches(($store+"`r`n"+$source),'(?m)^using [^;]+;') | ForEach-Object {$_.Value} | Select-Object -Unique) -join "`r`n"
        Add-Type -TypeDefinition ($usings+"`r`n"+(($store+"`r`n"+$source) -replace '(?m)^using ([^;]+);','')) -ReferencedAssemblies System.Drawing,System.Windows.Forms,System.Web.Extensions,System.Security -ErrorAction Stop
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
function Update-EnergyDetails {
    if(-not $Script:EnergyDetails -or $Script:EnergyDetails.IsDisposed){return}
    $state=$Script:EnergyService.GetSnapshot();$f=$Script:EnergyDetails.Tag.Fields
    $f.status.Text=Get-EnergyStatusText $state
    $fresh=$state.ObservedAt -ne [DateTime]::MinValue -and ([DateTime]::UtcNow-$state.ObservedAt).TotalSeconds -le 90 -and $state.Status -in @('已连接','功率读数未提供')
    $f.watts.Text=if($fresh -and $null -ne $state.Watts){'{0:N1} W' -f $state.Watts}else{'-- W'}
    $f.today.Text=Format-EnergyAmount $state.TodayKWh 'kWh';$f.week.Text=Format-EnergyAmount $state.WeekKWh 'kWh';$f.month.Text=Format-EnergyAmount $state.MonthKWh 'kWh';$f.fee.Text=Format-EnergyCost $state.MonthKWh $state.Price
    $f.price.Text=if($null -ne $state.Price){'固定电价：{0:N3} 元 / 度' -f $state.Price}else{'待设置电价'}
    $f.dayFee.Text=Format-EnergyCost $state.TodayKWh $state.Price
    $f.weekFee.Text=Format-EnergyCost $state.WeekKWh $state.Price
    $Script:DashboardTip.SetToolTip($f.week,"北京时间 $($state.WeekStart) 至 $($state.LocalDay)；周一开始，已采集 $([Math]::Round($state.WeekSeconds/3600,1)) 小时。")
    $Script:DashboardTip.SetToolTip($f.month,"北京时间 $($state.MonthStart) 至 $($state.LocalDay)；自然月，已采集 $([Math]::Round($state.MonthSeconds/3600,1)) 小时。")
    $f.hint.Text=if($state.Configured){$state.Status}else{'尚未连接 · 点击“连接与电价”设置插座'}
    $Script:DashboardTip.SetToolTip($f.hint,$state.Status)
    $f.coverage.Text='用电量、电费为已采集片段的估算；未采集日期与断线不补值'
    $f.updated.Text=if($state.ObservedAt -ne [DateTime]::MinValue){"采样 $($state.ObservedAt.ToLocalTime().ToString('HH:mm:ss')) · 每分钟更新"}else{'连接后开始累计，无接入前历史数据'}
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
    $key="$($State.ObservedAt.Ticks)|$($State.LocalDay)|$($State.Price)|$view|$count|$($State.Days.Count)|$($State.MonthKWh)"
    if($tag.DailyKey -eq $key){return};$tag.DailyKey=$key
    $grid=$tag.DailyGrid;$selectedDate=if($grid.CurrentRow){[string]$grid.CurrentRow.Cells[0].Value}else{''}
    $grid.Rows.Clear();$day=[DateTime]::ParseExact($State.LocalDay,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
    $totals=@{}
    foreach($item in $State.Days.GetEnumerator()){
        $date=[DateTime]::ParseExact($item.Key,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
        $start=switch($view){'Week'{$date.AddDays(-(([int]$date.DayOfWeek+6)%7))};'Month'{$date.AddDays(1-$date.Day)};default{$date}}
        $groupKey=$start.ToString('yyyy-MM-dd')
        if(-not $totals.ContainsKey($groupKey)){$totals[$groupKey]=@{KWh=0.0;Seconds=0.0}}
        $totals[$groupKey].KWh+=$item.Value.KWh;$totals[$groupKey].Seconds+=$item.Value.Seconds
    }
    $grid.Columns[0].HeaderText=switch($view){'Week'{'周起始（周一）'};'Month'{'月份'};default{'日期'}}
    for($i=0;$i -lt $count;$i++){
        $start=switch($view){'Week'{$day.AddDays(-(([int]$day.DayOfWeek+6)%7)-7*$i)};'Month'{$day.AddDays(1-$day.Day).AddMonths(-$i)};default{$day.AddDays(-$i)}}
        $groupKey=$start.ToString('yyyy-MM-dd');$date=if($view -eq 'Month'){$start.ToString('yyyy-MM')}else{$groupKey}
        $entry=if($totals.ContainsKey($groupKey)){$totals[$groupKey]}else{$null}
        $amount=if($null -ne $entry){Format-EnergyAmount $entry.KWh 'kWh'}else{'未采集'}
        $cost=if($null -ne $entry){Format-EnergyCost $entry.KWh $State.Price}else{'—'}
        $coverage=if($null -ne $entry){'{0:N1} 小时' -f ($entry.Seconds/3600)}else{'—'}
        $index=$grid.Rows.Add([object[]]@($date,$amount,$cost,$coverage))
        $grid.Rows[$index].Cells[0].ToolTipText=if($view -eq 'Week'){"$groupKey 至 $($start.AddDays(6).ToString('yyyy-MM-dd'))（北京时间）；本周期截至今日"}elseif($view -eq 'Month'){"自然月 $date；本周期截至今日"}else{'北京时间日期'}
        if($null -eq $entry){$grid.Rows[$index].DefaultCellStyle.ForeColor=[Drawing.Color]::FromArgb(133,142,150)}
        if($date -eq $selectedDate){$grid.CurrentCell=$grid.Rows[$index].Cells[0]}
    }
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
    $form=New-Object Windows.Forms.Form;Initialize-ModernForm $form 'PowerProfile · 电脑用电' 560 810
    $fields=@{}
    $title=New-ModernLabel '电脑用电' 20 16 260;$title.Font=New-Object Drawing.Font 'Microsoft YaHei UI',14,([Drawing.FontStyle]::Bold);$title.Height=36;$form.Controls.Add($title)
    $fields.status=New-ModernLabel '未连接' 320 23 220;$fields.status.TextAlign='TopRight';$fields.status.ForeColor=[Drawing.Color]::FromArgb(36,124,112);$form.Controls.Add($fields.status)
    $form.Controls.Add((New-ModernLabel '米家智能插座 3 · 仅为电脑供电' 20 54 245))
    $card=New-Object Windows.Forms.Panel;$card.BackColor=[Drawing.Color]::White;$card.SetBounds(12,92,536,104);$form.Controls.Add($card)
    $powerCaption=New-ModernLabel '电源输入功率' 16 10 210;$powerCaption.Height=20;$card.Controls.Add($powerCaption);$fields.watts=New-ModernLabel '-- W' 16 32 240;$fields.watts.Font=New-Object Drawing.Font 'Segoe UI',24,([Drawing.FontStyle]::Bold);$fields.watts.Height=46;$fields.watts.ForeColor=[Drawing.Color]::FromArgb(39,106,159);$card.Controls.Add($fields.watts)
    $meaning=New-ModernLabel '电脑 + 适配器 + 电池充电' 270 34 250;$meaning.ForeColor=[Drawing.Color]::FromArgb(111,122,132);$card.Controls.Add($meaning)
    $summary=New-Object Windows.Forms.Panel;$summary.BackColor=[Drawing.Color]::White;$summary.SetBounds(12,208,536,116);$form.Controls.Add($summary)
    foreach($row in @(@('今日','today','dayFee',16),@('本周 · 周一起','week','weekFee',190),@('本月 · 自然月','month','fee',364))){
        $caption=New-ModernLabel $row[0] $row[3] 11 156;$caption.ForeColor=[Drawing.Color]::FromArgb(111,122,132);$summary.Controls.Add($caption)
        $value=New-ModernLabel '等待累计' $row[3] 39 156;$value.Font=New-Object Drawing.Font 'Segoe UI',12,([Drawing.FontStyle]::Bold);$value.Height=29;$summary.Controls.Add($value);$fields[$row[1]]=$value
        $cost=New-ModernLabel '等待累计' $row[3] 75 156;$cost.ForeColor=[Drawing.Color]::FromArgb(39,106,159);$summary.Controls.Add($cost);$fields[$row[2]]=$cost
    }
    $curve=New-Object Windows.Forms.Panel;$curve.BackColor=[Drawing.Color]::White;$curve.SetBounds(12,336,536,164);$form.Controls.Add($curve)
    $curve.Controls.Add((New-ModernLabel '功率变化' 16 12 180));$chart=New-Object ProfileEnergyChart;$chart.Font=$Script:ModernFont;$chart.SetBounds(10,47,516,107);$curve.Controls.Add($chart)
    $hour=New-EnergyButton '近 1 小时' 347 9 91;$today=New-EnergyButton '今日' 445 9 74;$curve.Controls.Add($hour);$curve.Controls.Add($today)
    $hour.Add_Click({$Script:EnergyDetails.Tag.Chart.Today=$false;$Script:EnergyDetails.Tag.Chart.Invalidate()});$today.Add_Click({$Script:EnergyDetails.Tag.Chart.Today=$true;$Script:EnergyDetails.Tag.Chart.Invalidate()})
    $daily=New-Object Windows.Forms.Panel;$daily.BackColor=[Drawing.Color]::White;$daily.SetBounds(12,512,536,202);$form.Controls.Add($daily)
    $daily.Controls.Add((New-ModernLabel '用电明细' 16 12 180))
    $group=New-WorkstationCombo $daily 250 9 105 @(@('Day','按日'),@('Week','按周'),@('Month','按月')) 'Day'
    $range=New-WorkstationCombo $daily 370 9 150 @(@(7,'近 7 天'),@(30,'近 30 天'),@(90,'近 90 天')) 30
    $grid=New-Object Windows.Forms.DataGridView;$grid.SetBounds(10,44,516,148);$grid.ReadOnly=$true;$grid.AllowUserToAddRows=$false;$grid.AllowUserToDeleteRows=$false;$grid.AllowUserToResizeRows=$false;$grid.RowHeadersVisible=$false;$grid.MultiSelect=$false;$grid.SelectionMode='FullRowSelect';$grid.AutoSizeColumnsMode='Fill';$grid.BackgroundColor=[Drawing.Color]::White;$grid.BorderStyle='None';$grid.GridColor=[Drawing.Color]::FromArgb(234,239,242);$grid.EnableHeadersVisualStyles=$false;$grid.ColumnHeadersDefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(244,247,249);$grid.ColumnHeadersDefaultCellStyle.ForeColor=[Drawing.Color]::FromArgb(91,107,118);$grid.ColumnHeadersDefaultCellStyle.WrapMode='False';$grid.ColumnHeadersHeight=28;$grid.ColumnHeadersHeightSizeMode='DisableResizing';$grid.RowTemplate.Height=25;$grid.DefaultCellStyle.SelectionBackColor=[Drawing.Color]::FromArgb(228,240,247);$grid.DefaultCellStyle.SelectionForeColor=[Drawing.Color]::FromArgb(42,55,67)
    foreach($column in @(@('date','日期',130),@('amount','用电量',135),@('cost','估算电费',100),@('coverage','已采集',110))){$index=$grid.Columns.Add($column[0],$column[1]);$grid.Columns[$index].FillWeight=$column[2];$grid.Columns[$index].SortMode='NotSortable';if($index -gt 0){$grid.Columns[$index].DefaultCellStyle.Alignment='MiddleRight';$grid.Columns[$index].HeaderCell.Style.Alignment='MiddleRight'}}
    $daily.Controls.Add($grid);$range.Add_SelectedIndexChanged({if($Script:EnergyDetails){$Script:EnergyDetails.Tag.DailyKey='';Update-EnergyDetails}})
    $group.Add_SelectedIndexChanged({if($Script:EnergyDetails){Update-EnergyHistoryRange $Script:EnergyDetails}})
    $fields.price=New-ModernLabel '' 16 81 504;$fields.price.Height=20;$fields.price.Font=New-Object Drawing.Font 'Microsoft YaHei UI',8;$card.Controls.Add($fields.price)
    $fields.switch=New-EnergyButton '关闭插座' 284 770 124;$form.Controls.Add($fields.switch)
    $fields.switch.Add_Click({
        $state=$Script:EnergyService.GetSnapshot();if(-not $state.Configured -or $state.Busy -or $null -eq $state.On){return}
        $on=-not $state.On
        $message=if($on){'确认开启电脑插座？'}else{'确认关闭电脑插座？这会切断适配器供电，电脑将转为电池供电。不会触发自动休眠。请确认电池可用，避免远程连接中断。'}
        if([Windows.Forms.MessageBox]::Show($message,'插座控制','YesNo','Question','Button2') -eq 'Yes'){$Script:EnergyService.SetSwitch($on);Update-EnergyDetails}
    })
    $setup=New-EnergyButton '连接与电价' 18 770 136;$form.Controls.Add($setup);$setup.Add_Click({Show-EnergyConnection;Update-EnergyDetails})
    $fields.refresh=New-EnergyButton '刷新' 164 770 92;$form.Controls.Add($fields.refresh);$fields.refresh.Add_Click({$Script:EnergyService.Refresh();Update-EnergyDetails})
    $fields.coverage=New-ModernLabel '' 18 720 524;$fields.coverage.Height=20;$fields.coverage.Font=New-Object Drawing.Font 'Microsoft YaHei UI',8;$fields.coverage.ForeColor=[Drawing.Color]::FromArgb(111,122,132);$form.Controls.Add($fields.coverage)
    $fields.updated=New-ModernLabel '' 18 743 524;$fields.updated.Font=New-Object Drawing.Font 'Microsoft YaHei UI',8;$form.Controls.Add($fields.updated)
    $fields.hint=New-ModernLabel '' 288 65 252;$fields.hint.Height=20;$fields.hint.AutoEllipsis=$true;$fields.hint.ForeColor=[Drawing.Color]::FromArgb(111,122,132);$form.Controls.Add($fields.hint)
    $close=New-EnergyButton '关闭' 430 770 112;$form.Controls.Add($close);$close.Add_Click({$Script:EnergyDetails.Close()})
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=1000;$timer.Add_Tick({try{Update-EnergyDetails}catch{Write-ProfileEvent 'ui.energy.refresh.failed' $_.Exception.Message 'ERROR'}})
    $form.Tag=@{Fields=$fields;Chart=$chart;Timer=$timer;DailyGrid=$grid;Range=$range;Group=$group;DailyKey=''};$Script:EnergyDetails=$form
    $form.Add_FormClosed({param($sender,$args) $sender.Tag.Timer.Stop();$sender.Tag.Timer.Dispose();if($sender.Icon){$sender.Icon.Dispose()};$Script:EnergyDetails=$null})
    Update-EnergyDetails;$timer.Start();$form.Show();[ProfileVisual]::ActivateDashboard($form.Handle)
    Write-ProfileEvent 'ui.energy.open' '用电详情已打开' -Data @{handle=$form.Handle.ToInt64();historyView=$group.SelectedItem.Value}
}
