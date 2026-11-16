# Read-only analysis and user-requested exports. Never issues device commands.
function Test-InsightsDay([DateTime]$Date,[int]$Type=0){$weekend=$Date.DayOfWeek -in @('Saturday','Sunday');return $Type -eq 0 -or ($Type -eq 1 -and -not $weekend) -or ($Type -eq 2 -and $weekend)}
function Get-InsightsBounds($State,[string]$Group,[int]$Count,$Window=$null){
    $end=[DateTime]::ParseExact($State.LocalDay,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
    $start=switch($Group){'Week'{$end.AddDays(-(([int]$end.DayOfWeek+6)%7)-7*($Count-1))};'Month'{$end.AddDays(1-$end.Day).AddMonths(1-$Count)};default{$end.AddDays(1-$Count)}}
    if($Window -and $Window.CustomDates.Checked){$start=$Window.FromDate.Value.Date;$end=$Window.ToDate.Value.Date}
    if($start -gt $end){throw '开始日期不能晚于结束日期。'};if(($end-$start).Days -ge 400){throw '最多查看 400 天。'}
    if($end -gt [DateTime]::ParseExact($State.LocalDay,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)){throw '结束日期不能晚于今天。'}
    return @{Start=$start;End=$end}
}
function Select-InsightsRows($Rows,[string]$Search='',[int]$Source=0,[int]$Quality=0,[int]$DayType=0){
    return @($Rows|Where-Object {
        (Test-InsightsDay $_.PeriodStart $DayType) -and (-not $Search -or (($_.Date+' '+$_.Names+' '+$_.Source).IndexOf($Search,[StringComparison]::OrdinalIgnoreCase) -ge 0)) -and
        ($Source -eq 0 -or ($Source -eq 1 -and $_.Source -like '*米家历史*') -or ($Source -eq 2 -and $_.Source -like '*本机功率积分*') -or ($Source -eq 3 -and $_.Missing)) -and
        ($Quality -eq 0 -or ($Quality -eq 1 -and $_.Estimated) -or ($Quality -eq 2 -and $_.Missing))
    })
}
function Sort-InsightsRows($Rows,[int]$Column=0,[bool]$Descending=$true){
    $field=@('Key','KWhNumber','CostNumber','UsageSeconds','HighSeconds','GameSeconds','Source')[$Column]
    # Always put unknown numbers last, including descending order.
    return @($Rows|Sort-Object @{Expression={$null -eq $_.$field}},@{Expression={$_.$field};Descending=$Descending},@{Expression={$_.Key};Descending=$true})
}
function Get-InsightsMetric($Row,[int]$Metric){return $Row.(@('UsageSeconds','CostNumber','KWhNumber','HighSeconds','GameSeconds')[$Metric])}
function Format-InsightsValue($Value,[int]$Metric){if($null -eq $Value){return '未采集'};switch($Metric){1{return ('¥{0:N2}' -f $Value)};2{return ('{0:N3} kWh' -f $Value)};default{return Format-EnergyDuration $Value}}}
function Get-InsightsMean($Rows,[int]$Metric,[int]$DayType=0){
    $eligible=@($Rows|Where-Object {Test-InsightsDay $_.PeriodStart $DayType});$values=@($eligible|ForEach-Object {Get-InsightsMetric $_ $Metric}|Where-Object {$null -ne $_})
    return @{Value=$(if($values.Count){($values|Measure-Object -Average).Average}else{$null});Known=$values.Count;Missing=$eligible.Count-$values.Count}
}
function Format-InsightsMean($Mean,[int]$Metric){return (Format-InsightsValue $Mean.Value $Metric)+"（有记录 $($Mean.Known) 天 / 缺失 $($Mean.Missing) 天）"}
function Get-InsightsComparison($State,[DateTime]$Start,[DateTime]$End,[int]$Metric,[int]$DayType=0){
    $today=[DateTime]::ParseExact($State.LocalDay,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
    $closedEnd=if($End -ge $today){$today.AddDays(-1)}else{$End}
    if($closedEnd -lt $Start){return '当前范围没有完整日期可比；今日未结束，不参与日均对比。'}
    $days=($closedEnd-$Start).Days+1;$priorEnd=$Start.AddDays(-1);$priorStart=$Start.AddDays(-$days)
    $current=Get-WorkspaceEnergyData $State Day $days $Start $closedEnd
    $previous=Get-WorkspaceEnergyData $State Day $days $priorStart $priorEnd
    $weekday=Get-InsightsMean $current.Rows $Metric 1;$weekend=Get-InsightsMean $current.Rows $Metric 2
    $a=Get-InsightsMean $current.Rows $Metric $DayType;$b=Get-InsightsMean $previous.Rows $Metric $DayType
    $change=if($null -eq $a.Value -or $null -eq $b.Value){'样本不足，无法比较'}elseif($b.Value -eq 0){if($a.Value -eq 0){'均为零'}else{'上期为零，不计算百分比'}}else{'{0:+0.0;-0.0;0.0}%' -f (100*($a.Value-$b.Value)/$b.Value)}
    return "记录日均：周一至周五 $(Format-InsightsMean $weekday $Metric)；周六日 $(Format-InsightsMean $weekend $Metric)。`r`n本期 $(Format-EnergyCalendarDate $Start) — $(Format-EnergyCalendarDate $closedEnd)：$(Format-InsightsMean $a $Metric)`r`n上期 $(Format-EnergyCalendarDate $priorStart) — $(Format-EnergyCalendarDate $priorEnd)：$(Format-InsightsMean $b $Metric)；变化 $change。`r`n仅完整日期；零值参与均值，缺失剔除。星期分组不识别法定节假日；来源、搜索和质量筛选仅作用于下表 / 图表。"
}
function Get-InsightsBrief($State,[DateTime]$Start,[DateTime]$End,[int]$Metric,[int]$DayType=0){
    $today=[DateTime]::ParseExact($State.LocalDay,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture);if($End -ge $today){$End=$today.AddDays(-1)}
    if($End -lt $Start){return '今天尚未结束，暂无完整日期可比。'}
    $count=($End-$Start).Days+1;$days=Get-WorkspaceEnergyData $State Day $count $Start $End;$last=Get-WorkspaceEnergyData $State Day $count $Start.AddDays(-$count) $Start.AddDays(-1)
    $week=Get-InsightsMean $days.Rows $Metric 1;$weekend=Get-InsightsMean $days.Rows $Metric 2;$a=Get-InsightsMean $days.Rows $Metric $DayType;$b=Get-InsightsMean $last.Rows $Metric $DayType
    $change=if($null -eq $a.Value -or $null -eq $b.Value){'上期样本不足'}elseif($b.Value -eq 0){'上期为零'}else{'较上期 {0:+0.0;-0.0;0.0}%' -f (100*($a.Value-$b.Value)/$b.Value)}
    return "日均  周一至五 $(Format-InsightsValue $week.Value $Metric) · 周末 $(Format-InsightsValue $weekend.Value $Metric)`r`n$change · 仅已结束且有记录的日期"
}
function Update-WorkspaceInsightsCore($State,[string]$Group,[int]$Count){
    $w=$Script:Workspace;$t=$w.Tag;$bounds=Get-InsightsBounds $State $Group $Count $w;$t.Bounds=$bounds
    $filtering=$w.CustomDates.Checked -or $w.LedgerSearch.Text.Trim() -or $w.DayFilter.SelectedIndex -gt 0 -or $w.SourceFilter.SelectedIndex -gt 0 -or $w.QualityFilter.SelectedIndex -gt 0
    $w.Sections['EnergyFilters'].Caption='筛选与显示'+$(if($filtering){' · 已应用'})
    $data=Get-WorkspaceEnergyData $State $Group $Count $bounds.Start $bounds.End $w.DayFilter.SelectedIndex
    $dayType=if($Group -eq 'Day'){$w.DayFilter.SelectedIndex}else{0}
    $rows=Select-InsightsRows $data.Rows $w.LedgerSearch.Text.Trim() $w.SourceFilter.SelectedIndex $w.QualityFilter.SelectedIndex $dayType
    $column=if($null -ne $t.SortColumn){$t.SortColumn}else{0};$desc=if($null -ne $t.SortDescending){$t.SortDescending}else{$true}
    $rows=Sort-InsightsRows $rows $column $desc;$t.VisibleRows=@($rows);$t.EnergyData=$data;$t.Suppress=$true
    try{$w.SetLedger([ProfileLedgerView[]]$rows);foreach($c in $w.Ledger.Columns){$c.HeaderCell.SortGlyphDirection='None'};$w.Ledger.Columns[$column].HeaderCell.SortGlyphDirection=if($desc){'Descending'}else{'Ascending'}}finally{$t.Suppress=$false}
    if($w.Ledger.CurrentRow){$key=[string]$w.Ledger.CurrentRow.Tag;$w.SelectionInfo.Text=$data.Details[$key]}else{$w.SelectionInfo.Text='当前筛选没有匹配记录。'}
    $keys=@{};foreach($row in $rows){$keys[$row.Key]=$true};foreach($period in $data.Periods){if(-not $keys.ContainsKey($period.Key)){$period.Cost=$null;$period.UsageHours=$null;$period.HighHours=$null;$period.GameHours=$null;$period.ModeGameHours=$null}}
    $t.Chart.Periods=$data.Periods;$t.Chart.Invalidate();$w.Quality.Text="$(Format-EnergyCalendarDate $bounds.Start) — $(Format-EnergyCalendarDate $bounds.End) · 当前明细 $($rows.Count) 行。周 / 月只汇总所选日期及星期。`r`n"+$data.Summary
    $daily=Get-WorkspaceEnergyData $State Day 1 $bounds.Start $bounds.End;$metric=$w.Insights.Metric.SelectedIndex;$heat=New-Object 'Collections.Generic.List[ProfileHeatDay]'
    $allowed=Select-InsightsRows $daily.Rows $w.LedgerSearch.Text.Trim() $w.SourceFilter.SelectedIndex $w.QualityFilter.SelectedIndex $w.DayFilter.SelectedIndex;$set=@{};foreach($row in $allowed){$set[$row.Key]=$true}
    foreach($row in $daily.Rows){$cell=New-Object ProfileHeatDay;$cell.Date=$row.PeriodStart;$cell.Value=Get-InsightsMetric $row $metric;$cell.Excluded=-not $set.ContainsKey($row.Key);$cell.Detail=(Format-InsightsValue $cell.Value $metric)+$(if($cell.Excluded){' · 已筛除'})+"`r`n"+$row.Explanation;$heat.Add($cell)}
    $w.Insights.Heatmap.Days=$heat;$w.Insights.Heatmap.Metric=$metric;$w.Insights.Heatmap.Fit();$w.Insights.Comparison.Text=Get-InsightsComparison $State $bounds.Start $bounds.End $metric $w.DayFilter.SelectedIndex;$w.Insights.Summary.Text=Get-InsightsBrief $State $bounds.Start $bounds.End $metric $w.DayFilter.SelectedIndex
    $w.Insights.PerformLayout()
}
function Get-WorkspaceGameRows($State,[DateTime]$Start,[DateTime]$End,[string]$Search=''){
    $zone=[TimeZoneInfo]::FindSystemTimeZoneById('China Standard Time');$a=[TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($Start.Date,'Unspecified'),$zone);$b=[TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($End.Date.AddDays(1),'Unspecified'),$zone)
    $rows=@();foreach($s in $State.GameSessions){
        if($s.End -le $a -or $s.Start -ge $b -or ($Search -and $s.Name.IndexOf($Search,[StringComparison]::OrdinalIgnoreCase) -lt 0)){continue}
        $begin=if($s.Start -lt $a){$a}else{$s.Start};$finish=if($s.End -gt $b){$b}else{$s.End};$seconds=($finish-$begin).TotalSeconds
        # A persisted power range can span many samples. Never apportion its energy to a clipped boundary.
        $ranges=@($s.Power|Where-Object {$_.Start -ge $begin -and $_.End -le $finish});$covered=0.0;$kwh=$null;foreach($p in $ranges){$covered+=($p.End-$p.Start).TotalSeconds;$kwh+=$p.KWh}
        $watts=if($covered -gt 0){$kwh*3600000/$covered}else{$null};$cost=if($null -ne $kwh -and $null -ne $State.Price){$kwh*[double]$State.Price}else{$null}
        $localStart=[TimeZoneInfo]::ConvertTimeFromUtc($begin,$zone);$localEnd=[TimeZoneInfo]::ConvertTimeFromUtc($finish,$zone)
        $status=if($s.Open){if(([DateTime]::UtcNow-$s.End).TotalSeconds -le 90){'截至最近识别；待结束边界'}else{'缺少结束边界；未外推'}}else{$s.Source}
        $clipped=$begin -ne $s.Start -or $finish -ne $s.End
        $cells=[string[]]@($s.Name,((Format-EnergyCalendarDate $localStart)+"`r`n"+$localStart.ToString('HH:mm:ss')),((Format-EnergyCalendarDate $localEnd)+"`r`n"+$localEnd.ToString('HH:mm:ss')),(Format-EnergyDuration $seconds),('{0:N0}% · {1}' -f (100*$covered/$seconds),(Format-EnergyDuration $covered)),$(if($null -ne $watts){'{0:N1}' -f $watts}else{'未采集'}),$(if($null -ne $cost){'¥{0:N3}' -f $cost}else{'未采集'}),($status+$(if($s.Estimated){' · 估'})+$(if($clipped){' · 区间截取'})))
        $rows+=,[PSCustomObject]@{Id=$s.Id;Name=$s.Name;Seconds=$seconds;Covered=$covered;KWh=$kwh;Cost=$cost;Cells=$cells;Detail=($cells -join ' · ')+"`r`n插座输入功率为整机与充电，不是游戏进程独占功率。电费只计算完整保留的采样覆盖，按当前固定电价估算；未采集部分不补零、不外推。边界截取时舍弃跨界的已汇总功率段。"}
    };return @($rows|Sort-Object {$_.Cells[1]} -Descending)
}
function Set-WorkspaceGameSessions($Rows){$w=$Script:Workspace;$list=New-Object 'Collections.Generic.List[ProfileTableRow]';$w.Tag.SessionDetails=@{};foreach($r in $Rows){$entry=New-Object ProfileTableRow;$entry.Key=$r.Id;$entry.Cells=[object[]]$r.Cells;$list.Add($entry);$w.Tag.SessionDetails[$r.Id]=$r.Detail};([ProfileBufferedGrid]$w.GameSessions).BindRows($list.ToArray());$w.GameDetail.Text=if($Rows.Count){$Rows[0].Detail}else{'当前范围没有可重建会话；可查看下方逐日汇总。'}}
function Get-WorkspaceGameModelKey($State,[int]$Count,[string]$Search){return "$($State.UsageUpdatedAt.Ticks)|$($State.ObservedAt.Ticks)|$($State.LocalDay)|$($State.Price)|$($State.GameSessions.Count)|$Count|$Search"}
function Get-WorkspaceGameModel($State,[int]$Count,[string]$Search=''){
    $end=[DateTime]::ParseExact($State.LocalDay,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture);$start=$end.AddDays(1-$Count)
    $rows=@(Get-WorkspaceGameRows $State $start $end $Search);$cards=New-Object 'Collections.Generic.List[ProfileGameView]';$totals=New-Object 'Collections.Generic.List[ProfileTableRow]'
    foreach($group in @($rows|Group-Object Name|Sort-Object @{Expression={($_.Group|Measure-Object Seconds -Sum).Sum};Descending=$true})){
        $seconds=($group.Group|Measure-Object Seconds -Sum).Sum;$covered=($group.Group|Measure-Object Covered -Sum).Sum;$known=@($group.Group|Where-Object {$null -ne $_.KWh});$kwh=if($known.Count){($known|Measure-Object KWh -Sum).Sum}else{$null};$cost=if($null -ne $kwh -and $null -ne $State.Price){$kwh*[double]$State.Price}else{$null}
        $cells=[object[]]@($group.Name,(Format-EnergyDuration $seconds),$group.Count,('{0:N0}% · {1}' -f (100*$covered/$seconds),(Format-EnergyDuration $covered)),$(if($covered -gt 0){'{0:N1}' -f ($kwh*3600000/$covered)}else{'未采集'}),$(if($null -ne $cost){'¥{0:N3}（仅覆盖）' -f $cost}else{'未采集'}));$entry=New-Object ProfileTableRow;$entry.Key=$group.Name;$entry.Cells=$cells;$totals.Add($entry)
        $card=New-Object ProfileGameView;$card.Name=$group.Name;$card.Duration=Format-EnergyDuration $seconds;$card.Sessions=$group.Count;$latest=@($group.Group|Sort-Object {$_.Cells[1]} -Descending)[0];$card.Recent='最近 '+(([string]$latest.Cells[1] -split "`r?`n")[0]);$card.Detail=($cells -join ' · ');$cards.Add($card)
    }
    $daily=Get-WorkspaceEnergyData $State Day $Count;$fallback=@($daily.Rows|Where-Object {-not $Search -or $_.Names.IndexOf($Search,[StringComparison]::OrdinalIgnoreCase) -ge 0})
    $tables=@{};$first=@{};$details=@{};$all=New-Object 'Collections.Generic.List[ProfileTableRow]';foreach($r in $rows){$entry=New-Object ProfileTableRow;$entry.Key=$r.Id;$entry.Cells=[object[]]$r.Cells;$all.Add($entry);$details[$r.Id]=$r.Detail;if(-not $tables.ContainsKey($r.Name)){$tables[$r.Name]=New-Object 'Collections.Generic.List[ProfileTableRow]';$first[$r.Name]=$r.Detail};$tables[$r.Name].Add($entry)};foreach($name in @($tables.Keys)){$tables[$name]=$tables[$name].ToArray()};$tables['']=$all.ToArray();$first['']=if($rows.Count){$rows[0].Detail}else{'当前范围没有可重建会话；可查看下方逐日汇总。'}
    return @{Key=(Get-WorkspaceGameModelKey $State $Count $Search);Rows=$rows;Tables=$tables;First=$first;Details=$details;Cards=$cards.ToArray();Totals=$totals.ToArray();Daily=[ProfileLedgerView[]]$fallback;Summary=('{0} 款游戏 · {1} · {2} 个片段' -f $cards.Count,(Format-EnergyDuration (($rows|Measure-Object Seconds -Sum).Sum)),$rows.Count);Info="$(Format-EnergyCalendarDate $start) — $(Format-EnergyCalendarDate $end) · $($rows.Count) 个记录片段。选择游戏筛选会话，清空搜索或切换范围查看全部。`r`n沿用识别与切档日志；睡眠会拆分片段，手动游戏档缺少游戏证据时不算游戏。历史只有逐日名称时无法分摊到单个游戏。费用仅采样覆盖，使用当前固定电价。"}
}
function Update-WorkspaceGamesCore($State){
    $w=$Script:Workspace;$t=$w.Tag;$count=@(7,30,90,400)[$w.GameRange.SelectedIndex];$key=Get-WorkspaceGameModelKey $State $count $w.GameSearch.Text.Trim()
    $model=$t.GameModel
    if(-not $model -or $model.Key -ne $key){if($t.DeferModels){Start-WorkspaceModels;return};$model=Get-WorkspaceGameModel $State $count $w.GameSearch.Text.Trim();$t.GameModel=$model}
    if($t.GameApplied -eq $key){return};$t.Suppress=$true
    try{$t.GameRows=$model.Rows;([ProfileBufferedGrid]$w.GameTotals).BindRows($model.Totals);$w.GameTotals.ClearSelection();$w.GameTotals.CurrentCell=$null;$w.SetGameCards($model.Cards);$t.SessionDetails=$model.Details;([ProfileBufferedGrid]$w.GameSessions).BindRows($model.Tables[[string]$w.SelectedGame]);$w.GameDetail.Text=$model.First[[string]$w.SelectedGame];$w.SetGames($model.Daily);$w.GameSummary.Text=$model.Summary;$w.GameInfo.Text=$model.Info;$t.GameApplied=$key}finally{$t.Suppress=$false}
}
function Get-InsightsExportTable($Grid){
    $columns=@($Grid.Columns|Where-Object Visible|Sort-Object DisplayIndex);$headers=[string[]]@($columns|ForEach-Object HeaderText);$rows=New-Object 'Collections.Generic.List[string[]]'
    foreach($row in $Grid.Rows){$values=[string[]]@($columns|ForEach-Object {[string]$row.Cells[$_.Index].Value});$rows.Add($values)};return @{Headers=$headers;Rows=$rows}
}
function Export-WorkspaceInsights([string]$Kind){
    $w=$Script:Workspace;$t=$w.Tag;$state=$Script:EnergyService.GetSnapshot();$type=switch($Kind){'ExportPng'{@('PNG 图片|*.png','png')};'ExportReport'{@('HTML 月报|*.html','html')};default{@('CSV 表格|*.csv','csv')}}
    $month=$null;$table=$null;$report=$null
    if($Kind -eq 'ExportReport'){
        $selected=$w.Ledger.CurrentRow;if(-not $selected){throw '请先在用电明细选择一个日期，用于确定报告月份。'};$month=[DateTime]::ParseExact([string]$selected.Tag,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture);$month=$month.AddDays(1-$month.Day);$end=$month.AddMonths(1).AddDays(-1);$today=[DateTime]::ParseExact($state.LocalDay,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture);if($end -gt $today){$end=$today}
        $data=Get-WorkspaceEnergyData $state Day 1 $month $end;$headers=[string[]]@('日期 / 星期','电量 kWh','电费','使用时长','高功耗（含估）','游戏（含估）','来源');$rr=New-Object 'Collections.Generic.List[string[]]';foreach($r in $data.Rows){$rr.Add([string[]]@($r.Date,$r.Energy,$r.Cost,$r.Usage,$r.High,$r.Game,$r.Source))}
        $sum=($data.Rows|Measure-Object KWhNumber -Sum).Sum;$known=@($data.Rows|Where-Object {-not $_.Missing}).Count;$totalFee=if($known){Format-EnergyCost $sum $state.Price}else{'未采集'}
        $timeSummary=@();foreach($field in @('UsageSeconds','HighSeconds','GameSeconds')){$observed=@($data.Rows|Where-Object {$null -ne $_.$field});$timeSummary+=(Format-EnergyDuration $(if($observed.Count){($observed|Measure-Object $field -Sum).Sum}else{$null}))+"（有记录 $($observed.Count) 天）"}
        $summary="电量记录 $known / $($data.Rows.Count) 天，已记录电量 $(if($known){[string]$sum+' kWh'}else{'未采集'})；记录电费 $totalFee。电脑 / 高功耗含估 / 游戏含估：$($timeSummary -join ' / ')。电价 $(if($null -ne $state.Price){[string]$state.Price+' 元/kWh'}else{'未设置'})。报告包含该月全部日期至今天，不应用明细搜索及列筛选。`r`n"+(Get-InsightsComparison $state $month $end 0)
        $report=[ProfileAnalyticsExport]::Report(($month.ToString('yyyy-MM')+' 用电月报'),((Format-EnergyCalendarDate $month)+' — '+(Format-EnergyCalendarDate $end)),$summary,$headers,$rr)
    }elseif($Kind -ne 'ExportPng'){$table=Get-InsightsExportTable $(if($Kind -eq 'ExportGames'){$w.GameSessions}else{$w.Ledger})}
    $dialog=New-Object Windows.Forms.SaveFileDialog;$dialog.Filter=$type[0];$dialog.DefaultExt=$type[1];$dialog.AddExtension=$true;$dialog.FileName=if($month){'PowerProfile-'+$month.ToString('yyyy-MM')+'.html'}else{'PowerProfile-'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'.'+$type[1]}
    try{if($dialog.ShowDialog($w) -ne 'OK'){return};switch($Kind){'ExportPng'{[ProfileAnalyticsExport]::SaveChart($t.Chart,$dialog.FileName,'PowerProfile · 用电分析',((Format-EnergyCalendarDate $t.Bounds.Start)+' — '+(Format-EnergyCalendarDate $t.Bounds.End)+' · 当前筛选与可见曲线；电费按当前固定电价估算，缺失非零。'))};'ExportReport'{[ProfileAnalyticsExport]::WriteText($dialog.FileName,$report)};default{[ProfileAnalyticsExport]::WriteText($dialog.FileName,[ProfileAnalyticsExport]::Csv($table.Headers,$table.Rows))}};$w.Footer.Text='✓ 已导出：'+$dialog.FileName}finally{$dialog.Dispose()}
}
function Invoke-InsightsCommand([string]$Action,[string]$Id){
    $w=$Script:Workspace;$t=$w.Tag
    switch($Action){
        'InsightsFilter'{$t.EnergyKey='';if($t.DeferModels){Start-WorkspaceModels}else{Update-ProfileWorkspace};return $true}
        'LedgerSort'{$column=[int]$Id;$t.SortDescending=if($t.SortColumn -eq $column){-not $t.SortDescending}else{$column -eq 0};$t.SortColumn=$column;$t.EnergyKey='';Update-ProfileWorkspace;return $true}
        'LedgerColumns'{
            $menu=New-Object Windows.Forms.ContextMenuStrip;foreach($c in $w.Ledger.Columns){$item=New-Object Windows.Forms.ToolStripMenuItem;$item.Text=$c.HeaderText;$item.Checked=$c.Visible;$item.CheckOnClick=$true;$item.Enabled=$c.Index -ne 0;$item.Tag=$c.Index;$item.Add_CheckedChanged({param($sender,$eventArgs) $Script:Workspace.Ledger.Columns[[int]$sender.Tag].Visible=$sender.Checked});[void]$menu.Items.Add($item)};$menu.Add_Closed({param($sender,$eventArgs) $sender.Dispose()});$menu.Show([Windows.Forms.Cursor]::Position);return $true
        }
        'HeatDate'{
            $date=[DateTime]::ParseExact($Id,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture);$t.Suppress=$true;try{$w.Group.SelectedIndex=0;$w.CustomDates.Checked=$true;$w.FromDate.Value=$date;$w.ToDate.Value=$date;$w.LedgerSearch.Clear();$w.DayFilter.SelectedIndex=0;$w.SourceFilter.SelectedIndex=0;$w.QualityFilter.SelectedIndex=0}finally{$t.Suppress=$false};$w.ShowSection('EnergyFilters');$t.EnergyKey='';Update-ProfileWorkspace;$w.SelectLedger($Id);$w.Pages['Energy'].ScrollControlIntoView($w.Ledger);return $true
        }
        'GamesFilter'{$t.GameKey='';if($t.DeferModels){Start-WorkspaceModels}else{Update-ProfileWorkspace};return $true}
        'AllGames'{$w.SelectGame('',$false);$w.GameSearch.Clear();$t.GameKey='';if($t.DeferModels){Start-WorkspaceModels}else{Update-ProfileWorkspace};return $true}
        'GameSelect'{$t.Suppress=$true;try{if($t.GameModel -and $t.GameModel.Tables.ContainsKey([string]$Id)){([ProfileBufferedGrid]$w.GameSessions).BindRows($t.GameModel.Tables[[string]$Id]);$w.GameDetail.Text=$t.GameModel.First[[string]$Id]}else{Set-WorkspaceGameSessions $(if($Id){@($t.GameRows|Where-Object Name -eq $Id)}else{@($t.GameRows)})}}finally{$t.Suppress=$false};return $true}
        'GameSessionSelect'{if($t.SessionDetails -and $t.SessionDetails.ContainsKey($Id)){$w.GameDetail.Text=$t.SessionDetails[$Id]};return $true}
        {$_ -in @('ExportCsv','ExportPng','ExportReport','ExportGames')}{Export-WorkspaceInsights $Action;return $true}
    };return $false
}

function Update-WorkspaceInsights($State,[string]$Group,[int]$Count){
 $w=$Script:Workspace;$grid=[ProfileBufferedGrid]$w.Ledger;$grid.BeginBatch();$w.Pages['Energy'].SuspendLayout()
 try{Update-WorkspaceInsightsCore $State $Group $Count}finally{$grid.EndBatch();$w.Pages['Energy'].ResumeLayout()}
}
function Update-WorkspaceGames($State){
 $w=$Script:Workspace;$grids=@($w.GameTotals,$w.GameSessions,$w.GameGrid);foreach($g in $grids){([ProfileBufferedGrid]$g).BeginBatch()};$w.Pages['Games'].SuspendLayout()
 try{Update-WorkspaceGamesCore $State}finally{foreach($g in $grids){([ProfileBufferedGrid]$g).EndBatch()};$w.Pages['Games'].ResumeLayout()}
}
