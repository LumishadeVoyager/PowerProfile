# Local AI telemetry. No credentials or conversational text are stored or sent.
function Start-AIUsageMonitor {
    $root=if($SettingsPath){Split-Path -Parent $SettingsPath}else{$ScriptDir}
    if([IO.Path]::GetFullPath($root).TrimEnd('\') -ne [IO.Path]::GetFullPath($ScriptDir).TrimEnd('\')){return}
    if($Script:AICollector -and -not $Script:AICollector.HasExited){return}
    $python=Join-Path $ScriptDir '.codex\energy-cloud\Scripts\python.exe'
    if(-not(Test-Path $python)){$cmd=Get-Command python.exe -ErrorAction SilentlyContinue;if(-not $cmd -or $cmd.Source -match 'WindowsApps'){return};$python=$cmd.Source}
    $script=Join-Path $ScriptDir 'PowerProfileAIUsage.py'
    $Script:AICollector=Start-Process -FilePath $python -WindowStyle Hidden -PassThru -ArgumentList @(('"'+$script+'"'),'--root',('"'+$root+'"'),'--watch','--parent-pid',"$PID")
    if(-not $Script:AIExitRegistered){$Script:AIExitRegistered=$true;[Windows.Forms.Application]::add_ApplicationExit({try{if($Script:AICollector -and -not $Script:AICollector.HasExited){$Script:AICollector.Kill()}}catch{}})}
}
function Read-AISnapshot {
    $path=Join-Path (Get-WorkspaceRoot) 'ai.snapshot.json'
    if(-not(Test-Path $path)){return $null};$stamp=(Get-Item $path).LastWriteTimeUtc.Ticks
    if($Script:AISnapshotStamp -ne $stamp -or $Script:AISnapshotPath -ne $path){$Script:AISnapshotCache=Read-WorkspaceJson $path;$Script:AISnapshotStamp=$stamp;$Script:AISnapshotPath=$path}
    return $Script:AISnapshotCache
}
function Get-AIRows($Snapshot,[string]$Source='native',[string]$Client='全部',[string]$Search=''){
    return @($Snapshot.rows|Where-Object {$_ -and $_.source -eq $Source -and ($Client -eq '全部' -or $_.client -eq $Client) -and (-not $Search -or (($_.model+' '+$_.client+' '+$_.date).IndexOf($Search,[StringComparison]::OrdinalIgnoreCase) -ge 0))})
}
function Format-AITimestamp($Value){if(-not $Value){return '尚未启用'};try{$date=[TimeZoneInfo]::ConvertTimeFromUtc(([DateTimeOffset]::Parse([string]$Value)).UtcDateTime,[TimeZoneInfo]::FindSystemTimeZoneById('China Standard Time'));return (Format-EnergyCalendarDate $date)+' '+$date.ToString('HH:mm:ss')}catch{return '时间未知'}}
function Update-WorkspaceAI {
    $w=$Script:Workspace;if(-not $w -or -not $w.Tag){return};$snapshot=Read-AISnapshot;$t=$w.Tag;$t.AISnapshot=$snapshot;if($t.AIChart){$t.AIChart.DarkMode=[ProfileTheme]::Dark;$t.AIChart.BackColor=[ProfileTheme]::Surface;$t.AIChart.ForeColor=[ProfileTheme]::Text}
    $source=@('native','cc-switch')[[Math]::Max(0,$w.AISource.SelectedIndex)];$rows=Get-AIRows $snapshot $source ([string]$w.AIClient.SelectedItem) $w.AISearch.Text.Trim()
    if($w.ActivePage -eq 'AI'){
        $localDay=[TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow,[TimeZoneInfo]::FindSystemTimeZoneById('China Standard Time')).ToString('yyyy-MM-dd');$key="$localDay|$($snapshot.revision)|$source|$($w.AIClient.SelectedIndex)|$($w.AISearch.Text)|$($w.AIRange.SelectedIndex)|$($w.AIView.SelectedIndex)|$($w.AICurrency.SelectedIndex)|$($t.AIChargeRevision)"
        if($t.AIKey -ne $key){
            $t.AIKey=$key;$days=@(7,30,90,400)[$w.AIRange.SelectedIndex];$today=[TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow,[TimeZoneInfo]::FindSystemTimeZoneById('China Standard Time')).Date;$from=$today.AddDays(1-$days)
            $lifetime=@(Get-AIRows $snapshot $source ([string]$w.AIClient.SelectedItem));$lifetimeTokens=($lifetime|Measure-Object tokens -Sum).Sum;$lifetimePriced=($lifetime|Measure-Object pricedTokens -Sum).Sum;$lifetimeCosts=@($lifetime|Where-Object {$null -ne $_.cost}|Group-Object currency|ForEach-Object {$_.Name+' '+('{0:N4}' -f ($_.Group|Measure-Object cost -Sum).Sum)});$rows=@($rows|Where-Object {[DateTime]$_.date -ge $from -and [DateTime]$_.date -le $today});$grid=[ProfileBufferedGrid]$w.AIGrid;$grid.BeginBatch()
            try{$grid.Rows.Clear();foreach($r in @($rows|Sort-Object date,client,model -Descending)){$date=Format-EnergyCalendarDate ([DateTime]$r.date);$cost=if($null -ne $r.cost){'{0} {1:N4}' -f $r.currency,$r.cost}else{'待配置'};if($null -ne $r.cost -and $r.pricedTokens -lt $r.tokens){$cost+=' *'};$coverage=if($r.pricedTokens -lt $r.tokens){'部分 / 未计价'}else{'来源估算 / 自定价'};[void]$grid.Rows.Add([object[]]@($date,$r.client,$r.model,('{0:N0}' -f $r.tokens),$cost,('{0:N0} / {1:N0} / {2:N0} / {3:N0}' -f $r.input,$r.cached,$r.write,$r.output),$coverage))}}finally{$grid.EndBatch()}
            $tokens=($rows|Measure-Object tokens -Sum).Sum;$amounts=@($rows|Where-Object {$null -ne $_.cost}|Group-Object currency|ForEach-Object {$_.Name+' '+('{0:N4}' -f ($_.Group|Measure-Object cost -Sum).Sum)})
            $priced=($rows|Measure-Object pricedTokens -Sum).Sum
            $w.AISummary.Text=if($snapshot){"本机累计 $('{0:N0}' -f $lifetimeTokens) tokens · $($w.AISource.SelectedItem)`r`n累计估算$(if($lifetimePriced -lt $lifetimeTokens){'（部分）'})：$(if($lifetimeCosts.Count){$lifetimeCosts -join ' · '}else{'待配置单价'})`r`n已计价 $('{0:N0}' -f $lifetimePriced) / $('{0:N0}' -f $lifetimeTokens) tokens`r`n近 $days 天：$('{0:N0}' -f $tokens) tokens · $(if($amounts.Count){$amounts -join ' · '}else{'费用待配置'})"}else{'正在等待本地采集器；需要 Python 3。'}
            $charges=@((Read-WorkspaceJson (Join-Path (Get-WorkspaceRoot) 'ai.charges.json')).charges|Where-Object {$_ -and [DateTime]$_.date -ge $from -and [DateTime]$_.date -le $today -and ($w.AIClient.SelectedItem -eq '全部' -or $_.client -eq $w.AIClient.SelectedItem)})
            $allCharges=@((Read-WorkspaceJson (Join-Path (Get-WorkspaceRoot) 'ai.charges.json')).charges|Where-Object {$_ -and [DateTime]$_.date -le $today -and ($w.AIClient.SelectedItem -eq '全部' -or $_.client -eq $w.AIClient.SelectedItem)});$payments=@($allCharges|Group-Object currency|ForEach-Object {$_.Name+' '+('{0:N2}' -f ($_.Group|Measure-Object amount -Sum).Sum)})
            if($w.AIView.SelectedIndex -eq 2){$grid.BeginBatch();try{$grid.Rows.Clear();foreach($charge in @($charges|Sort-Object date -Descending)){[void]$grid.Rows.Add([object[]]@((Format-EnergyCalendarDate ([DateTime]$charge.date)),$charge.client,'订阅 / 充值','—',('{0} {1:N2}' -f $charge.currency,$charge.amount),'—','独立记账'))}}finally{$grid.EndBatch()}};$w.AIChartHost.Visible=$w.AIView.SelectedIndex -ne 2
            $w.AISummary.Text+="`r`n独立累计支出：$(if($payments.Count){$payments -join ' · '}else{'未录入订阅 / 充值'})"
            $periods=New-Object 'Collections.Generic.List[ProfileEnergyPeriod]';$aiDays=@{};foreach($r in $rows){if(-not $aiDays.ContainsKey($r.date)){$aiDays[$r.date]=New-Object 'Collections.Generic.List[object]'};$aiDays[$r.date].Add($r)}
            for($i=$days-1;$i -ge 0;$i--){$date=$today.AddDays(-$i);$p=New-Object ProfileEnergyPeriod;$p.Key=$date.ToString('yyyy-MM-dd');$p.Label=Format-EnergyCalendarDate $date 'MM-dd';Set-AIPeriod $p $(if($aiDays.ContainsKey($p.Key)){$aiDays[$p.Key].ToArray()}else{@()}) ([string]$w.AICurrency.SelectedItem);$periods.Add($p)}
            $t.AIChart.AnalyticsMode=if($w.AIView.SelectedIndex -eq 0){1}else{2};$t.AIChart.AICurrency=[string]$w.AICurrency.SelectedItem;$t.AIChart.Periods=$periods;$t.AIChart.Invalidate()
        }
            $status=if($snapshot){($snapshot.status.PSObject.Properties|ForEach-Object {$_.Name+'：'+$_.Value}) -join "`r`n"}else{'未连接采集器'}
            $errors=if($snapshot.errors){($snapshot.errors.PSObject.Properties|ForEach-Object {$_.Name+'：'+$_.Value}) -join "`r`n"}else{''}
            $w.AIStatus.Text="$status`r`n$errors`r`n采集启用：$(Format-AITimestamp $snapshot.startedAt)`r`n历史：$($snapshot.backfill.status) · 最早 $($snapshot.backfill.earliestDate)`r`n更新：$(Format-AITimestamp $snapshot.updatedAt)`r`n仅本机可读取的记录；不同来源不相加。缓存是输入的组成部分，推理不重复加到输出。缺价不等于零；估算不等于订阅账单。"
    }
    if($w.ActivePage -eq 'Energy' -and $t.Chart){$overlayKey="$($snapshot.revision)|$source|$($w.AnalysisMode.SelectedIndex)|$($w.AICurrency.SelectedItem)|$($t.Chart.Periods.GetHashCode())";if($t.AIOverlayKey -eq $overlayKey){return};$t.AIOverlayKey=$overlayKey;$all=@($snapshot.daily|Where-Object {$_.source -eq $source});$visible=@{};foreach($r in $t.VisibleRows){$visible[$r.Key]=$true};$rowIndex=@{};foreach($row in $t.EnergyData.Rows){$rowIndex[$row.Key]=$row};$dateIndex=@{};foreach($row in $all){if(-not $dateIndex.ContainsKey($row.date)){$dateIndex[$row.date]=New-Object 'Collections.Generic.List[object]'};$dateIndex[$row.date].Add($row)};$periodIndex=@{};foreach($p in $t.Chart.Periods){$periodIndex[$p.Key]=$p;$row=$rowIndex[$p.Key];$begin=[DateTime]$p.Key;$end=if($row){$row.PeriodEnd}else{$begin};if($t.Bounds){if($begin -lt $t.Bounds.Start){$begin=$t.Bounds.Start};if($end -gt $t.Bounds.End){$end=$t.Bounds.End}};$selected=New-Object 'Collections.Generic.List[object]';if($visible.ContainsKey($p.Key)){for($day=$begin;$day -le $end;$day=$day.AddDays(1)){if(Test-InsightsDay $day $w.DayFilter.SelectedIndex){foreach($entry in $dateIndex[$day.ToString('yyyy-MM-dd')]){$selected.Add($entry)}}}};Set-AIPeriod $p $selected.ToArray() ([string]$w.AICurrency.SelectedItem)};foreach($gridRow in $w.Ledger.Rows){$period=$periodIndex[[string]$gridRow.Tag];if($period){$gridRow.Cells[7].Value=if($null -ne $period.CodexTokens){'{0:N0}' -f ($period.CodexTokens*1000000)}else{'未记录'};$gridRow.Cells[8].Value=if($null -ne $period.ClaudeTokens){'{0:N0}' -f ($period.ClaudeTokens*1000000)}else{'未记录'};$gridRow.Cells[9].Value=if($null -ne $period.CodexCost){'{0} {1:N4}' -f $w.AICurrency.SelectedItem,$period.CodexCost}else{'待配置'};$gridRow.Cells[10].Value=if($null -ne $period.ClaudeCost){'{0} {1:N4}' -f $w.AICurrency.SelectedItem,$period.ClaudeCost}else{'待配置'}}};foreach($i in @(7,8)){$w.Ledger.Columns[$i].Visible=$w.AnalysisMode.SelectedIndex -gt 0};foreach($i in @(9,10)){$w.Ledger.Columns[$i].Visible=$w.AnalysisMode.SelectedIndex -eq 2};$t.Chart.AnalyticsMode=$w.AnalysisMode.SelectedIndex;$t.Chart.AICurrency=[string]$w.AICurrency.SelectedItem;$t.Chart.Invalidate();$i=0;foreach($check in $w.SeriesChecks){$check.Text=if($w.AnalysisMode.SelectedIndex -eq 0){@('电费','使用','高功耗','游戏')[$i]}else{@('电费','Codex','Claude Code','')[$i]};$check.Visible=$i -lt 3 -or $w.AnalysisMode.SelectedIndex -eq 0;$i++}}
    if($snapshot -and -not $w.AIStatus.Text.StartsWith('采集超过') -and ([DateTime]::UtcNow-([DateTime]$snapshot.updatedAt).ToUniversalTime()).TotalSeconds -gt 120){$w.AIStatus.Text='采集超过两分钟未更新；保留最后数据。请检查 Python 与本地采集器。'+"`r`n"+$w.AIStatus.Text}
}
function Show-AIExpense {
    $f=New-Object Windows.Forms.Form;Initialize-ModernForm $f '记录订阅 / 充值支出' 440 300
    $date=New-Object Windows.Forms.DateTimePicker;$date.Format='Custom';$date.CustomFormat='yyyy-MM-dd dddd';$date.SetBounds(20,20,220,28);$f.Controls.Add($date)
    $client=New-Object Windows.Forms.ComboBox;$client.Items.AddRange([object[]]@('Codex','Claude Code'));$client.SelectedIndex=0;$client.DropDownStyle='DropDownList';$client.SetBounds(20,70,180,28);$f.Controls.Add($client)
    $amount=New-Object Windows.Forms.NumericUpDown;$amount.DecimalPlaces=2;$amount.Maximum=1000000;$amount.SetBounds(20,120,180,28);$f.Controls.Add($amount)
    $currency=New-Object Windows.Forms.ComboBox;$currency.Items.AddRange([object[]]@('USD','CNY'));$currency.SelectedIndex=0;$currency.DropDownStyle='DropDownList';$currency.SetBounds(220,120,100,28);$f.Controls.Add($currency)
    $f.Controls.Add((New-ModernLabel '此项独立记账，不与 token 估算相加；不会执行付款。' 20 165 390));$button=New-EnergyButton '保存支出' 280 225 130;$f.Controls.Add($button);$f.Tag=@{Date=$date;Client=$client;Amount=$amount;Currency=$currency}
    $button.Add_Click({param($sender,$args) $t=$sender.FindForm().Tag;$path=Join-Path (Get-WorkspaceRoot) 'ai.charges.json';$old=Read-WorkspaceJson $path ([PSCustomObject]@{charges=@()});$old.charges=@($old.charges)+@([PSCustomObject]@{date=$t.Date.Value.ToString('yyyy-MM-dd');client=$t.Client.SelectedItem;amount=$t.Amount.Value;currency=$t.Currency.SelectedItem});Write-AtomicJson $path $old -Pretty;$Script:Workspace.Tag.AIChargeRevision=[Guid]::NewGuid().ToString();$sender.FindForm().Close()})
    Show-WorkspaceDialog $f;Update-WorkspaceAI
}
function Set-AIPeriod($Period,$Rows,[string]$Currency='USD'){
    foreach($client in @('Codex','Claude Code')){$selected=@($Rows|Where-Object client -eq $client);$prefix=if($client -eq 'Codex'){'Codex'}else{'Claude'};$Period.($prefix+'Tokens')=if($selected.Count){($selected|Measure-Object tokens -Sum).Sum/1000000}else{$null};$priced=@($selected|Where-Object {$null -ne $_.cost -and $_.currency -eq $Currency});$Period.($prefix+'Cost')=if($priced.Count){($priced|Measure-Object cost -Sum).Sum}else{$null};$Period.($prefix+'CostPartial')=@($selected|Where-Object {$null -eq $_.cost -or $_.currency -ne $Currency -or $_.pricedTokens -lt $_.tokens}).Count -gt 0}
}
function Show-AIPriceEditor {
    $root=Get-WorkspaceRoot;$config=Read-WorkspaceJson (Join-Path $root 'ai.settings.json') ([PSCustomObject]@{prices=[PSCustomObject]@{}})
    $f=New-Object Windows.Forms.Form;Initialize-ModernForm $f 'AI 模型单价 · 每百万 tokens' 490 390
    $models=@((Read-AISnapshot).rows|Select-Object -ExpandProperty model -Unique);$model=New-Object Windows.Forms.ComboBox;$model.SetBounds(20,35,440,28);$model.DropDownStyle='DropDown';foreach($name in $models){[void]$model.Items.Add($name)};$f.Controls.Add($model)
    $f.Controls.Add((New-ModernLabel '精确模型名（包括中转模型）；费用为估算' 20 8 440));$fields=@();$i=0
    foreach($label in @('新增输入','缓存读取','缓存写入','输出')){$f.Controls.Add((New-ModernLabel $label 20 (80+42*$i) 120));$n=New-Object Windows.Forms.NumericUpDown;$n.DecimalPlaces=6;$n.Maximum=1000000;$n.SetBounds(150,(78+42*$i),180,28);$f.Controls.Add($n);$fields+=,$n;$i++}
    $currency=New-Object Windows.Forms.ComboBox;$currency.Items.AddRange([object[]]@('USD','CNY'));$currency.DropDownStyle='DropDownList';$currency.SelectedIndex=0;$currency.SetBounds(345,78,100,28);$f.Controls.Add($currency)
    $f.Controls.Add((New-ModernLabel '每百万 tokens 的供应商单价；0 表示免费，不表示未知。' 20 260 450))
    $save=New-EnergyButton '保存估算单价' 290 310 170;$f.Controls.Add($save);$f.Tag=@{Config=$config;Model=$model;Fields=$fields;Currency=$currency;Root=$root}
    $model.Add_SelectedIndexChanged({param($sender,$args) $t=$sender.FindForm().Tag;$rate=$t.Config.prices.($sender.Text);if($rate){$i=0;foreach($key in @('input','cached','write','output')){$t.Fields[$i++].Value=[decimal]$rate.$key};$t.Currency.SelectedItem=$rate.currency}else{foreach($field in $t.Fields){$field.Value=0};$t.Currency.SelectedIndex=0}})
    $save.Add_Click({param($sender,$args) $t=$sender.FindForm().Tag;if(-not $t.Model.Text.Trim()){return};if(-not $t.Config.prices){$t.Config|Add-Member prices ([PSCustomObject]@{}) -Force};$t.Config.prices|Add-Member -NotePropertyName $t.Model.Text.Trim() -NotePropertyValue ([PSCustomObject]@{input=$t.Fields[0].Value;cached=$t.Fields[1].Value;write=$t.Fields[2].Value;output=$t.Fields[3].Value;currency=$t.Currency.SelectedItem}) -Force;Write-AtomicJson (Join-Path $t.Root 'ai.settings.json') $t.Config -Pretty;$sender.FindForm().Close()})
    Show-WorkspaceDialog $f
}
function Show-AISourceEditor {
    $root=Get-WorkspaceRoot;$config=Read-WorkspaceJson (Join-Path $root 'ai.settings.json') ([PSCustomObject]@{prices=[PSCustomObject]@{}})
    $f=New-Object Windows.Forms.Form;Initialize-ModernForm $f 'AI 本地来源 · 留空使用默认路径' 500 350;$inputs=@{};$index=0
    foreach($item in @(@('codexPath','Codex sessions 目录'),@('claudePath','Claude Code projects 目录'),@('ccSwitchPath','CC Switch 数据库文件'))){$f.Controls.Add((New-ModernLabel $item[1] 20 (18+80*$index) 460));$box=New-Object Windows.Forms.TextBox;$box.SetBounds(20,(45+80*$index),450,28);$box.Text=[string]$config.($item[0]);$f.Controls.Add($box);$inputs[$item[0]]=$box;$index++}
    $status=New-ModernLabel '' 20 260 450;$f.Controls.Add($status);$save=New-EnergyButton '保存来源' 330 290 140;$f.Controls.Add($save);$f.Tag=@{Inputs=$inputs;Config=$config;Root=$root;Status=$status}
    $save.Add_Click({param($sender,$args) $t=$sender.FindForm().Tag;foreach($key in $t.Inputs.Keys){$path=$t.Inputs[$key].Text.Trim();if($path -and -not [IO.Path]::IsPathRooted($path)){$t.Status.Text='请填写绝对路径，或留空使用默认值。';return};$t.Config|Add-Member -NotePropertyName $key -NotePropertyValue $path -Force};Write-AtomicJson (Join-Path $t.Root 'ai.settings.json') $t.Config -Pretty;$sender.FindForm().Close()});Show-WorkspaceDialog $f
}
function Invoke-AICommand([string]$Action){
    if($Action -eq 'AIPrice'){Show-AIPriceEditor;return $true}
    if($Action -eq 'AISources'){Show-AISourceEditor;return $true}
    if($Action -eq 'AIExpense'){Show-AIExpense;return $true}
    if($Action -eq 'AIFilter'){$prefs=Get-WorkspacePreferences;if($prefs.aiSource -ne $Script:Workspace.AISource.SelectedIndex -or $prefs.aiCurrency -ne $Script:Workspace.AICurrency.SelectedItem){$prefs.aiSource=$Script:Workspace.AISource.SelectedIndex;$prefs.aiCurrency=$Script:Workspace.AICurrency.SelectedItem;Save-WorkspacePreferences $prefs};$Script:Workspace.Tag.AIKey='';$Script:Workspace.Tag.AIOverlayKey='';Update-WorkspaceAI;return $true}
    if($Action -eq 'AIExport'){$table=Get-InsightsExportTable $Script:Workspace.AIGrid;$dialog=New-Object Windows.Forms.SaveFileDialog;$dialog.Filter='CSV|*.csv';$dialog.FileName='PowerProfile-AI.csv';try{if($dialog.ShowDialog($Script:Workspace) -eq 'OK'){[ProfileAnalyticsExport]::WriteText($dialog.FileName,[ProfileAnalyticsExport]::Csv($table.Headers,$table.Rows))}}finally{$dialog.Dispose()};return $true}
    return $false
}
