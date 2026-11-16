. (Join-Path $PSScriptRoot 'PowerProfileWorkspaceData.ps1')
if(-not ('ProfileWorkspaceForm' -as [type])){Add-Type -Path @((Join-Path $PSScriptRoot 'PowerProfileWorkspace.cs'),(Join-Path $PSScriptRoot 'PowerProfileSkin.cs'),(Join-Path $PSScriptRoot 'PowerProfileInsightsUI.cs')) -ReferencedAssemblies System.Drawing,System.Windows.Forms,System.Core}
. (Join-Path $PSScriptRoot 'PowerProfileInsights.ps1')
. (Join-Path $PSScriptRoot 'PowerProfileWorkspaceAsync.ps1')
. (Join-Path $PSScriptRoot 'PowerProfileConnectionUI.ps1')
. (Join-Path $PSScriptRoot 'PowerProfileAI.ps1')
$Script:Workspace=$null
$skinOptions=Get-WorkspacePreferences;[ProfileSkin]::Set($skinOptions.skin);[ProfileTheme]::Dark=($skinOptions.theme -eq 'Dark' -or ($skinOptions.theme -eq 'System' -and [ProfileTheme]::SystemDark()));[ProfileSkin]::SystemBlur=$skinOptions.glass;[ProfileSkin]::MonitorWindows()
# Fixed read-only views for tray requests; no arbitrary commands or paths are accepted.
function Open-WorkspaceAIView {
    param([ValidateSet('Tokens','Costs','Combined')][string]$View='Tokens')
    Show-ProfileWorkspace -Page $(if($View -eq 'Combined'){'Energy'}else{'AI'})
    $w=$Script:Workspace;$t=$w.Tag;$suppressed=$t.Suppress;$t.Suppress=$true
    try{
        $w.AIClient.SelectedIndex=0;$w.AICurrency.SelectedItem='USD';$w.AISource.SelectedIndex=2
        $w.AIView.SelectedIndex=$(if($View -eq 'Costs'){1}else{0});$w.AIRange.SelectedIndex=4
        if($View -eq 'Combined'){$w.AnalysisMode.SelectedIndex=1}
    }finally{$t.Suppress=$suppressed}
    $t.AIKey='';$t.AIOverlayKey='';Update-ProfileWorkspace
    # A user-requested tray view should be visible even when the hidden host lacks focus.
    $topmost=$w.TopMost;try{$w.TopMost=$true;$w.BringToFront()}finally{$w.TopMost=$topmost}
    [ProfileVisual]::ActivateDashboard($w.Handle)
}
function Show-WorkspaceDialog($Form){
    [ProfileWorkspaceForm]::ScaleDialog($Form,(Get-WorkspacePreferences).textScale)
    [ProfileTheme]::Apply($Form,[ProfileTheme]::Dark)
    try{[void]$Form.ShowDialog($Script:Workspace)}finally{if($Form.Icon){$Form.Icon.Dispose()};$Form.Dispose()}
}
function Show-WorkspaceDeviceEditor($Device){
    $prefs=Get-WorkspacePreferences;$p=$prefs.devices.($Device.did)
    $f=New-Object Windows.Forms.Form;Initialize-ModernForm $f '设备别名与分组' 460 260
    $f.Controls.Add((New-ModernLabel '显示名称' 20 24 130));$alias=New-Object Windows.Forms.TextBox;$alias.SetBounds(156,22,280,27);$alias.MaxLength=80;$alias.Text=if($p.alias){$p.alias}else{$Device.name};$f.Controls.Add($alias)
    $f.Controls.Add((New-ModernLabel '分组 / 房间' 20 82 130));$room=New-Object Windows.Forms.TextBox;$room.SetBounds(156,80,280,27);$room.MaxLength=40;$room.Text=if($p.room){$p.room}else{'未分组'};$f.Controls.Add($room)
    $note=New-ModernLabel '只修改本机显示，不重命名米家设备。' 20 135 410;$f.Controls.Add($note)
    $save=New-EnergyButton '保存' 320 204 116;$f.Controls.Add($save);$f.Tag=@{Alias=$alias;Room=$room;Device=$Device}
    $save.Add_Click({param($sender,$eventArgs) $t=$sender.FindForm().Tag;$prefs=Get-WorkspacePreferences;$old=$prefs.devices.($t.Device.did);$prefs.devices|Add-Member -NotePropertyName $t.Device.did -NotePropertyValue ([PSCustomObject]@{alias=$t.Alias.Text.Trim();room=$t.Room.Text.Trim();favorite=[bool]$old.favorite}) -Force;Save-WorkspacePreferences $prefs;$sender.FindForm().Close();$Script:Workspace.Tag.DeviceKey='';Update-ProfileWorkspace})
    Show-WorkspaceDialog $f
}
function Get-WorkspaceSelectedRule {
    $row=$Script:Workspace.RuleGrid.CurrentRow;if(-not $row){throw '先选择一个任务。'}
    $id=[string]$row.Tag;$rule=@((Get-DeviceHubConfig).rules|Where-Object {$_.id -eq $id})[0];if(-not $rule){throw '任务已变化，请刷新。'};return $rule
}
function Get-WorkspaceSelectedDevice([string]$Id){
    $device=@($Script:Workspace.Tag.Hub.Status.devices|Where-Object {$_.did -eq $Id})[0]
    if(-not $device -or -not $device.switch){throw '没有已验证开关的设备；请先同步设备。'};return $device
}
function Select-WorkspaceDevice {
    $devices=@($Script:Workspace.Tag.Hub.Status.devices|Where-Object {$_.switch})
    if(-not $devices.Count){throw '先在设备页完成连接并同步可控制设备。'}
    $f=New-Object Windows.Forms.Form;Initialize-ModernForm $f '选择任务设备' 480 180
    $combo=New-Object Windows.Forms.ComboBox;$combo.DropDownStyle='DropDownList';$combo.DisplayMember='name';$combo.SetBounds(20,30,438,30);foreach($d in $devices){[void]$combo.Items.Add($d)};$combo.SelectedIndex=0;$f.Controls.Add($combo)
    $select=New-EnergyButton '继续' 330 115 128;$f.Controls.Add($select);$f.Tag=@{Combo=$combo;Selected=$null};$select.Add_Click({param($sender,$eventArgs) $sender.FindForm().Tag.Selected=$sender.FindForm().Tag.Combo.SelectedItem;$sender.FindForm().Close()})
    [ProfileTheme]::Apply($f,[ProfileTheme]::Dark);[void]$f.ShowDialog($Script:Workspace);$selected=$f.Tag.Selected;$f.Dispose();return $selected
}
function Invoke-WorkspaceCommand([string]$Action,[string]$Id=''){
    $w=$Script:Workspace;$t=$w.Tag
    try{
        if(Invoke-AICommand $Action){return}
        if(Invoke-InsightsCommand $Action $Id){return}
        switch($Action){
            'AIColumns'{foreach($i in @(2,5,6)){$w.AIGrid.Columns[$i].Visible=-not $w.AIGrid.Columns[$i].Visible};return}
            'Navigate'{$w.Navigate($Id);return}
            'Skin'{$prefs=Get-WorkspacePreferences;$prefs.skin=$Id;Save-WorkspacePreferences $prefs;return}
            'Glass'{$prefs=Get-WorkspacePreferences;$prefs.glass=$w.Glass.Checked;Save-WorkspacePreferences $prefs;return}
            'Motion'{$prefs=Get-WorkspacePreferences;$prefs.motion=$w.Motion.Checked;Save-WorkspacePreferences $prefs;return}
            'GameColumns'{$show=-not $w.GameSessions.Columns[2].Visible;foreach($i in @(2,4,5,6,7)){$w.GameSessions.Columns[$i].Visible=$show};foreach($i in @(3,4,5)){$w.GameTotals.Columns[$i].Visible=$show};return}
            'Page'{if($t.DeferModels -and $Id -in @('Energy','Games')){Start-WorkspaceModels;return};Update-ProfileWorkspace;return}
            'Theme'{$prefs=Get-WorkspacePreferences;$prefs.theme=@('System','Light','Dark')[[int]$Id];Save-WorkspacePreferences $prefs;$w.SetTheme([int]$Id);$t.Chart.DarkMode=[ProfileTheme]::Dark;$t.Chart.BackColor=[ProfileTheme]::Surface;$t.Chart.ForeColor=[ProfileTheme]::Text;$t.Chart.Invalidate();return}
            'TextSize'{$prefs=Get-WorkspacePreferences;$prefs.textScale=[int]$Id;Save-WorkspacePreferences $prefs;$page=$w.ActivePage;$w.Dispose();Show-ProfileWorkspace -Page $page;return}
            'Metric'{$pair=$Id -split ':';$prefs=Get-WorkspacePreferences;if($pair[1] -eq 'True'){$prefs.metrics=@($prefs.metrics)+@($pair[0])|Select-Object -Unique}else{$prefs.metrics=@($prefs.metrics|Where-Object {$_ -ne $pair[0]})};Save-WorkspacePreferences $prefs;$w.SetMetricVisible($pair[0],($pair[1] -eq 'True'));return}
            'Series'{$pair=$Id -split ':';$t.Chart.SeriesVisible[[int]$pair[0]]=($pair[1] -eq 'True');$t.Chart.Invalidate();return}
            'ResetChart'{$t.Chart.ResetView();return}
            'EnergyRange'{
                $labels=switch($w.Group.SelectedIndex){1{@('近 4 周','近 8 周','近 12 周')};2{@('近 3 个月','近 6 个月','近 12 个月')};default{@('近 7 天','近 30 天','近 90 天')}}
                if([string]$w.Range.Items[0] -ne $labels[0]){$index=$w.Range.SelectedIndex;$t.Suppress=$true;$w.Range.Items.Clear();foreach($label in $labels){[void]$w.Range.Items.Add($label)};$w.Range.SelectedIndex=[Math]::Max(0,$index);$t.Suppress=$false}
                $t.EnergyKey='';$t.Chart.ResetView();if($t.DeferModels){Start-WorkspaceModels}else{Update-ProfileWorkspace};return
            }
            'LedgerSelection'{if($t.EnergyData.Details.ContainsKey($Id)){$w.SelectionInfo.Text=$t.EnergyData.Details[$Id]};return}
            'ChartSelection'{$w.SelectLedger($Id);return}
            'FilterDevices'{$t.DeviceKey='';Update-ProfileWorkspace;return}
            'CalendarFilter'{$t.ScheduleKey='';Update-ProfileWorkspace;return}
            'Week'{$w.WeekOffset=if($Id -eq '0'){0}else{$w.WeekOffset+[int]$Id};$t.ScheduleKey='';Update-ProfileWorkspace;return}
            'Favorite'{$prefs=Get-WorkspacePreferences;$old=$prefs.devices.($Id);$prefs.devices|Add-Member -NotePropertyName $Id -NotePropertyValue ([PSCustomObject]@{alias=$old.alias;room=$old.room;favorite=(-not [bool]$old.favorite)}) -Force;Save-WorkspacePreferences $prefs;$t.DeviceKey='';Update-ProfileWorkspace;return}
            'DeviceEdit'{Show-WorkspaceDeviceEditor (Get-WorkspaceSelectedDevice $Id);return}
            {$_ -in @('DeviceOn','DeviceOff')}{
                if($t.PendingRequest){throw '上一项设备操作仍在处理中，请等待实际状态读回后再操作。'}
                if(-not $t.Hub.Fresh -or -not $t.Hub.Config.enabled){throw '中枢暂停或响应过期，先同步连接后再控制。'}
                $device=Get-WorkspaceSelectedDevice $Id;$on=$Action -eq 'DeviceOn';$ack=$false
                if(-not $on -and (Test-HubPlug $device)){
                    if([Windows.Forms.MessageBox]::Show($w,"确认关闭 $($device.name)？`r`n这将切断负载供电。电脑插座断电不等于正常关机；请确认电池或设备可安全断电。`r`n本机停止、休眠或断网后无法继续执行之后的通电任务。",'插座断电确认','YesNo','Warning','Button2') -ne 'Yes'){return};$ack=$true
                }
                $t.PendingRequest=Send-DeviceHubRequest 'set' $device $on -PowerRiskAcknowledged $ack;$t.PendingSince=[DateTime]::UtcNow;$w.Footer.Text='◷ 指令已排队，等待中枢发送与实际状态读回';return
            }
            {$_ -in @('DeviceSchedule','NewRule')}{
                $device=if($Id){Get-WorkspaceSelectedDevice $Id}else{Select-WorkspaceDevice};if($device){Show-WorkspaceDialog (Show-HubRuleEditor $device -ReturnForm);$t.ScheduleKey=''};Update-ProfileWorkspace;return
            }
            'SelectRule'{foreach($row in $w.RuleGrid.Rows){if([string]$row.Tag -eq $Id){$w.RuleGrid.CurrentCell=$row.Cells[0];break}};return}
            'EditRule'{$rule=Get-WorkspaceSelectedRule;$device=Get-WorkspaceSelectedDevice $rule.did;Show-WorkspaceDialog (Show-HubRuleEditor $device $rule -ReturnForm);$t.ScheduleKey='';Update-ProfileWorkspace;return}
            'ToggleRule'{$rule=Get-WorkspaceSelectedRule;Set-HubRuleEnabled $rule.id;$t.ScheduleKey='';Update-ProfileWorkspace;return}
            'RemoveRule'{$rule=Get-WorkspaceSelectedRule;if([Windows.Forms.MessageBox]::Show($w,"移除任务 [$($rule.name)]？移除只停止后续执行，不发送反向开关指令。",'移除任务','YesNo','Question','Button2') -eq 'Yes'){$c=Get-DeviceHubConfig;$c.rules=@($c.rules|Where-Object {$_.id -ne $rule.id});Save-DeviceHubConfig $c;$t.ScheduleKey='';Update-ProfileWorkspace};return}
            'ToggleHub'{$c=Get-DeviceHubConfig;$c.enabled=-not $c.enabled;foreach($rule in @($c.rules)){$rule|Add-Member -NotePropertyName revision -NotePropertyValue ([Guid]::NewGuid().ToString()) -Force};Save-DeviceHubConfig $c;Start-DeviceHubWorker;$t.ScheduleKey='';Update-ProfileWorkspace;return}
            'RefreshDevices'{$t.PendingRequest=Send-DeviceHubRequest 'refresh';$t.PendingSince=[DateTime]::UtcNow;$w.Footer.Text='◷ 正在同步云端设备与实际状态';return}
            'RefreshEnergy'{$Script:EnergyService.Refresh();$w.Footer.Text='◷ 正在刷新插座采样；数据返回前保留原值';return}
            'Connection'{Show-WorkspaceConnectionWizard;return}
            'Cloud'{$Script:WorkspaceModels=$null;$t.ModelSignature='';$t.PageSignatures.Clear();$form=Show-CloudHistory -ReturnForm;[ProfileTheme]::Apply($form,[ProfileTheme]::Dark);$form.Tag.Timer.Start();try{[void]$form.ShowDialog($w)}finally{$form.Dispose()};$t.EnergyKey='';Update-ProfileWorkspace;return}
            'AdvancedSettings'{Show-Settings;return}
            'PlanSettings'{Show-WorkspaceDialog (Show-ModernSettings -ReturnForm);return}
            'CState'{Show-WorkspaceDialog (Show-CStateProtection -ReturnForm);return}
            'Welcome'{Show-WorkspaceDialog (Show-ProfileWelcome -ReturnForm);return}
            'Logs'{Show-ModernLogViewer;return}
            'Hardware'{Show-ModernDashboard;return}
            {$_ -in @('Auto','Idle','Balanced','Game')}{Invoke-DashboardAction $Action;$w.Footer.Text='◷ 档位请求已发送，当前档位以 Worker 实际结果为准';Update-ProfileWorkspace;return}
            'Refresh'{$t.ModelSignature='';$Script:WorkspaceModels=$null;$t.EnergyKey='';$t.DeviceKey='';$t.ScheduleKey='';Update-ProfileWorkspace;return}
        }
    }catch{$w.Footer.Text='! '+$_.Exception.GetBaseException().Message;Write-ProfileEvent 'workspace.action.failed' $_.Exception.GetBaseException().Message 'WARN' @{action=$Action}}
}
function Update-ProfileWorkspace {
    param($State=$null)
    $w=$Script:Workspace;if(-not $w -or $w.IsDisposed){return};$t=$w.Tag
    $t.Chart.DarkMode=[ProfileTheme]::Dark;$t.Chart.BackColor=[ProfileTheme]::Surface;$t.Chart.ForeColor=[ProfileTheme]::Text
    if($null -eq $State){$State=$Script:EnergyService.GetSnapshot()};$t.State=$State
    $now=[TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow,[TimeZoneInfo]::FindSystemTimeZoneById('China Standard Time'))
    $hub=Get-WorkspaceHub;$t.Hub=$hub;$monday=$now.Date.AddDays(-(([int]$now.DayOfWeek+6)%7));$week=$monday.AddDays(7*$w.WeekOffset)
    $future=Get-WorkspaceSchedule $hub.Config $hub.Status.rules $now.Date $now
    $mode=if(Get-Command Get-CurrentMode -ErrorAction SilentlyContinue){Get-CurrentMode}else{'Idle'}
    $modeName=if($Script:Settings -and $Script:Settings.modes -and $Script:Settings.modes[$mode]){$Script:Settings.modes[$mode].name}else{@{Idle='静音';Balanced='均衡';Game='游戏'}[$mode]}
    $w.Metrics['mode'].Set($modeName,$(if(Get-Command Get-AutoEnabled -ErrorAction SilentlyContinue){if(Get-AutoEnabled){'自动切换已开启'}else{'手动档位优先'}}else{'等待托盘状态'}))
    $fresh=$State.Configured -and $State.ObservedAt -ne [DateTime]::MinValue -and ([DateTime]::UtcNow-$State.ObservedAt).TotalSeconds -ge 0 -and ([DateTime]::UtcNow-$State.ObservedAt).TotalSeconds -le 90 -and $State.Status -in @('已连接','功率读数未提供')
    $w.Metrics['power'].Set($(if($fresh -and $null -ne $State.Watts){'{0:N1} W' -f $State.Watts}else{'— W'}),(Get-EnergyStatusText $State))
    $w.Metrics['cost'].Set((Format-EnergyCost $State.TodayKWh $State.Price),(Get-EnergyPeriodCoverage $State $State.LocalDay))
    $todayUsage=if($State.UsageDays.ContainsKey($State.LocalDay)){$State.UsageDays[$State.LocalDay]}else{$null}
    $w.Metrics['usage'].Set((Format-EnergyDuration $(if($todayUsage){$todayUsage.Seconds}else{$null})),'今日 · 有效监测')
    $w.Metrics['game'].Set((Format-EnergyDuration $(if($todayUsage){$todayUsage.GameSeconds}else{$null})),$(if($null -ne $todayUsage.ModeGameSeconds){'今日 · 含日志推算'}else{'今日 · 游戏识别'}))
    $nextRule=@($hub.Config.rules|Where-Object {$future.Next.ContainsKey($_.id)}|Sort-Object {$future.Next[$_.id]}|Select-Object -First 1)
    if($nextRule.Count){$next=$future.Next[$nextRule[0].id];$holding=$hub.Fresh -and $nextRule[0].mode -eq 'guard' -and $hub.Status.rules.($nextRule[0].id).entered;$w.Metrics['next'].Set($(if($holding){'保持中'}else{$next.ToString('HH:mm')}),(Format-EnergyCalendarDate $next 'MM-dd')+' · '+$nextRule[0].name)}else{$w.Metrics['next'].Set('暂无',$(if($hub.Config.enabled){'未来七天无待执行任务'}else{'设备自动化已暂停'}))}
    $reason=if(Get-Command Read-GameDetectionState -ErrorAction SilentlyContinue){Read-GameDetectionState}else{$null}
    $w.OverviewReason.Text=if($reason.Fresh){'档位原因：'+$reason.Reason}else{'档位原因：等待新的游戏识别记录；原控制逻辑继续运行。'}
    $tray=Read-WorkspaceJson (Join-Path (Get-WorkspaceRoot) 'tray_ready.json');$trayAlive=$tray.processId -and [bool](Get-Process -Id $tray.processId -ErrorAction SilentlyContinue)
    $w.Runtime.Text="托盘：$(if($trayAlive){'运行中'}else{'未确认运行'}) · 自动化中枢：$(if(-not $hub.Config.enabled){'已暂停'}elseif($hub.Fresh){'运行中'}else{'响应过期 / 未连接'})`r`n插座：$(Get-EnergyStatusText $State) · $(if($State.ObservedAt -ne [DateTime]::MinValue){'最近读回 '+$State.ObservedAt.ToLocalTime().ToString('HH:mm:ss')}else{'尚无实际读回'})`r`n关闭工作台仅隐藏窗口；托盘与已启用的中枢仍继续工作。"
    $view=@('Day','Week','Month')[$w.Group.SelectedIndex];$count=if($view -eq 'Day'){@(7,30,90)[$w.Range.SelectedIndex]}elseif($view -eq 'Week'){@(4,8,12)[$w.Range.SelectedIndex]}else{@(3,6,12)[$w.Range.SelectedIndex]}
    $energyKey="$($State.ObservedAt.Ticks)|$($State.UsageUpdatedAt.Ticks)|$($State.Price)|$view|$count|$($State.Days.Count)|$($State.MonthKWh)"
    if($w.ActivePage -eq 'Energy' -and $t.EnergyKey -ne $energyKey){$t.EnergyKey=$energyKey;Update-WorkspaceInsights $State $view $count}
    if($w.ActivePage -eq 'Games'){$gameKey="$($State.UsageUpdatedAt.Ticks)|$($State.LocalDay)|$($State.UsageDays.Count)";if($t.GameKey -ne $gameKey){$t.GameKey=$gameKey;Update-WorkspaceGames $State}}
    if($w.ActivePage -eq 'Devices'){
        $prefs=Get-WorkspacePreferences;$groups=@('全部分组')+@($hub.Status.devices|ForEach-Object {$p=$prefs.devices.($_.did);if($p.room){$p.room}else{'未分组'}}|Sort-Object -Unique)
        if(($groups -join '|') -ne (@($w.Room.Items) -join '|')){$selected=$w.Room.SelectedItem;$t.Suppress=$true;$w.Room.Items.Clear();foreach($g in $groups){[void]$w.Room.Items.Add($g)};$w.Room.SelectedItem=if($groups -contains $selected){$selected}else{'全部分组'};$t.Suppress=$false}
        $devices=Get-WorkspaceDevices $hub $prefs $State $future.Next $w.Search.Text ([string]$w.Room.SelectedItem) $w.Favorites.Checked
        $key=ConvertTo-Json -InputObject $devices.ToArray() -Depth 5 -Compress
        if($t.DeviceKey -ne $key){$t.DeviceKey=$key;$scroll=$w.Pages['Devices'].AutoScrollPosition;$w.SetDevices($devices.ToArray());$w.Pages['Devices'].AutoScrollPosition=New-Object Drawing.Point (-$scroll.X),(-$scroll.Y)}
    }
    if($w.ActivePage -eq 'Automation'){
        $key=($hub.Config|ConvertTo-Json -Depth 8 -Compress)+'|'+($hub.Status.rules|ConvertTo-Json -Depth 8 -Compress)+'|'+$w.WeekOffset+'|'+$w.CalendarDevice.SelectedItem+'|'+$now.ToString('yyyyMMddHHmm')+'|'+$hub.Fresh
        if($t.ScheduleKey -ne $key){
            $t.ScheduleKey=$key;$plan=Get-WorkspaceSchedule $hub.Config $hub.Status.rules $week $now;$selected=$w.CalendarDevice.SelectedItem;$names=@{'全部设备'=''}
            foreach($d in @($hub.Status.devices)){$label=$d.name+' · '+$d.model;$base=$label;$n=2;while($names.ContainsKey($label)){$label=$base+'（'+$n+'）';$n++};$names[$label]=$d.did}
            if((@($w.CalendarDevice.Items) -join '|') -ne (@($names.Keys|Sort-Object) -join '|')){$t.Suppress=$true;$w.CalendarDevice.Items.Clear();foreach($n in @($names.Keys|Sort-Object)){[void]$w.CalendarDevice.Items.Add($n)};$w.CalendarDevice.SelectedItem=if($names.ContainsKey([string]$selected)){$selected}else{'全部设备'};$t.Suppress=$false}
            $filter=$names[[string]$w.CalendarDevice.SelectedItem];$slots=@($plan.Slots|Where-Object {-not $filter -or $_.Device -eq $filter});foreach($slot in $slots){$device=@($hub.Status.devices|Where-Object {$_.did -eq $slot.Device})[0];if($device){$slot.Device=$device.name}}
            $w.Calendar.WeekStart=$week;$w.Calendar.Slots.Clear();foreach($s in $slots){$w.Calendar.Slots.Add($s)};$max=1;for($i=0;$i -lt 7;$i++){$day=$week.AddDays($i);$n=@($slots|Where-Object {$_.Start.Date -le $day -and $_.End -gt $day}).Count;$max=[Math]::Max($max,$n)};$w.Calendar.Height=[Math]::Max(350,7*(32+22*$max)+35);$w.Calendar.Invalidate()
            $selectedRule=if($w.RuleGrid.CurrentRow){[string]$w.RuleGrid.CurrentRow.Tag}else{''};$w.RuleGrid.Rows.Clear()
            foreach($r in @($hub.Config.rules|Where-Object {-not $filter -or $_.did -eq $filter})){$device=@($hub.Status.devices|Where-Object {$_.did -eq $r.did})[0];$status=if(-not $r.enabled -or -not $hub.Config.enabled){'已暂停'}elseif(-not $hub.Fresh){'中枢响应过期'}elseif($plan.Conflicts.ContainsKey($r.id)){'! 存在冲突'}elseif($hub.Status.rules.($r.id).message){$hub.Status.rules.($r.id).message}else{'等待执行'};$next=if($future.Next.ContainsKey($r.id)){(Format-EnergyCalendarDate $future.Next[$r.id] 'MM-dd')+' '+$future.Next[$r.id].ToString('HH:mm')+' · '}else{''};$i=$w.RuleGrid.Rows.Add([object[]]@($r.name,$(if($device){$device.name}else{'未同步设备'}),(Format-HubRule $r),($next+$status)));$w.RuleGrid.Rows[$i].Tag=$r.id;if($r.id -eq $selectedRule){$w.RuleGrid.CurrentCell=$w.RuleGrid.Rows[$i].Cells[0]}}
            $w.TaskInfo.Text="$(Format-EnergyCalendarDate $week) — $(Format-EnergyCalendarDate $week.AddDays(6)) · $(if($hub.Config.enabled -and $hub.Fresh){'● 中枢运行中'}elseif(-not $hub.Config.enabled){'Ⅱ 中枢已暂停'}else{'? 中枢响应过期'}) · 冲突 $($plan.Conflicts.Count) 项。时间轴为计划；是否执行以读回状态为准。"
        }
    }
    Update-WorkspaceAI
    if($t.PendingRequest){$operation=@($hub.Status.operations|Where-Object {$_.id -eq $t.PendingRequest})[0];if($operation){$w.Footer.Text=@{sending='◷ 正在发送';checking='◷ 等待实际状态读回';confirmed='✓ 已完成并读回';failed='! 操作失败'}[$operation.phase]+' · '+$operation.message;if($operation.phase -in @('confirmed','failed')){$t.PendingRequest=$null;$t.DeviceKey=''}}elseif($t.PendingSince -and ([DateTime]::UtcNow-$t.PendingSince).TotalSeconds -gt 120){$w.Footer.Text='! 请求已超时，未确认执行；请检查连接和设备实际状态后再试。';$t.PendingRequest=$null}}
}
function Show-ProfileWorkspace {
    param([string]$Page='Overview',[switch]$ReturnForm)
    if($Script:Workspace -and -not $Script:Workspace.IsDisposed){$Script:Workspace.Show();$Script:Workspace.Navigate($Page);[ProfileVisual]::ActivateDashboard($Script:Workspace.Handle);if($ReturnForm){return $Script:Workspace};return}
    Initialize-EnergyService
    $prefs=Get-WorkspacePreferences;[ProfileSkin]::Set($prefs.skin);$w=New-Object ProfileWorkspaceForm ([int]$prefs.textScale);$area=[Windows.Forms.Screen]::FromControl($w).WorkingArea;$space=New-Object Drawing.Size ($area.Width-40),($area.Height-70);$size=[ProfileWorkspaceForm]::PortraitSize($space);$w.MinimumSize=New-Object Drawing.Size ([Math]::Min(436,$size.Width+16)),([Math]::Min(596,$size.Height+39));$w.ClientSize=$size;$w.Glass.Checked=$prefs.glass;$w.Motion.Checked=$prefs.motion;[ProfileMotion]::Enabled=$prefs.motion;$w.Icon=[ProfileVisual]::CreateIcon('Balanced');$w.DeferDevices=(-not $ReturnForm);$Script:Workspace=$w
    $chart=New-Object ProfileInteractiveTimeline;$chart.Dock='Fill';$w.ChartHost.Controls.Add($chart)
    $aiChart=New-Object ProfileInteractiveTimeline;$aiChart.Dock='Fill';$aiChart.AIOnly=$true;$w.AIChartHost.Controls.Add($aiChart)
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=2000
    $w.Tag=@{AIChart=$aiChart;Chart=$chart;Timer=$timer;EnergyKey='';DeviceKey='';ScheduleKey='';EnergyData=@{Details=@{}};PendingRequest=$null;Suppress=$false;DeferModels=(-not $ReturnForm);ModelReady=@{};PageSignatures=@{}}
    $tModel=New-Object Windows.Forms.Timer;$tModel.Interval=30;$w.Tag.ModelTimer=$tModel;$tModel.Add_Tick({Complete-WorkspaceModels})
    $prefs=Get-WorkspacePreferences;$w.AISource.SelectedIndex=$prefs.aiSource;$w.AICurrency.SelectedItem=$prefs.aiCurrency;$mode=[array]::IndexOf(@('System','Light','Dark'),$prefs.theme);$w.Theme.SelectedIndex=$mode;$w.SetTheme($mode)
    foreach($key in $w.MetricOptions.Keys){$visible=$prefs.metrics -contains $key;$w.MetricOptions[$key].Checked=$visible;$w.SetMetricVisible($key,$visible)}
    $w.add_Command({param($sender,$eventArgs) if(-not $sender.Tag.Suppress){Invoke-WorkspaceCommand $eventArgs.Action $eventArgs.Id}})
    $chart.add_PeriodSelected({param($sender,$eventArgs) Invoke-WorkspaceCommand 'ChartSelection' $eventArgs.Key})
    $timer.Add_Tick({if($Script:Workspace -and $Script:Workspace.Visible){try{if($Script:Workspace.Tag.DeferModels -and $Script:Workspace.ActivePage -in @('Energy','Games')){Start-WorkspaceModels;Update-WorkspaceAI}else{Update-ProfileWorkspace}}catch{$Script:Workspace.Footer.Text='! 状态暂不可读，保留现有显示；下轮自动重试';Write-ProfileEvent 'workspace.refresh.failed' $_.Exception.Message 'WARN'}}})
    $w.Add_Disposed({param($sender,$eventArgs) $sender.Tag.ModelTimer.Stop();$sender.Tag.ModelTimer.Dispose();if($sender.Tag.ModelJob){$sender.Tag.ModelJob.PowerShell.Stop();$sender.Tag.ModelJob.PowerShell.Dispose()};$sender.Tag.Timer.Stop();$sender.Tag.Timer.Dispose();if($sender.Icon){$sender.Icon.Dispose()};$Script:Workspace=$null})
    [Windows.Forms.Application]::add_ApplicationExit({if($Script:Workspace){$Script:Workspace.Dispose()}})
    $chart.DarkMode=[ProfileTheme]::Dark;$chart.BackColor=[ProfileTheme]::Surface;$chart.ForeColor=[ProfileTheme]::Text
    Update-ProfileWorkspace;$w.Footer.Text='● 已就绪';$timer.Start();$w.Navigate($Page)
    if($ReturnForm){return $w};$w.Show();[ProfileVisual]::ActivateDashboard($w.Handle)
}
