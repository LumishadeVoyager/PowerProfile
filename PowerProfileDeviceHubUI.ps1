# Device hub is opt-in and keeps its credentials in the existing DPAPI cloud session.
$Script:DeviceHubForm=$null
$Script:DeviceHubTick=$null
function Get-DeviceHubRoot {
    if($SettingsPath){return Split-Path -Parent $SettingsPath};return $ScriptDir
}
function Get-DeviceHubConfig {
    $path=Join-Path (Get-DeviceHubRoot) 'devices.hub.json'
    if(Test-Path $path){return Read-AtomicJson $path}
    return [PSCustomObject]@{enabled=$false;rules=@()}
}
function Save-DeviceHubConfig($Config){
    Write-AtomicJson (Join-Path (Get-DeviceHubRoot) 'devices.hub.json') $Config -Pretty
}
function Start-DeviceHubWorker {
    $root=Get-DeviceHubRoot;$statusPath=Join-Path $root '.codex\device-hub\status.json'
    try{
        $status=Read-AtomicJson $statusPath
        if(([DateTime]::UtcNow-([DateTime]$status.observedAt).ToUniversalTime()).TotalSeconds -lt 180 -and (Get-Process -Id $status.pid -ErrorAction SilentlyContinue)){return}
    }catch{}
    $python=Join-Path $ScriptDir '.codex\energy-cloud\Scripts\pythonw.exe'
    if(-not(Test-Path $python)){throw '请先运行 Install-EnergyHistory.ps1 安装米家连接组件。'}
    [void](Start-Process $python -WindowStyle Hidden -PassThru -ArgumentList @(('"{0}"' -f (Join-Path $ScriptDir 'PowerProfileDeviceHub.py')),'--root',('"{0}"' -f $root)))
}
function Send-DeviceHubRequest([string]$Action,$Device=$null,$Value=$null){
    $root=Get-DeviceHubRoot;$queue=Join-Path $root '.codex\device-hub\queue'
    [void][IO.Directory]::CreateDirectory($queue)
    $request=@{action=$Action;createdAt=[DateTime]::UtcNow.ToString('o')}
    if($Device){$request.did=$Device.did;$request.model=$Device.model;$request.value=$Value}
    Write-AtomicJson (Join-Path $queue (([Guid]::NewGuid().ToString())+'.json')) $request
    Start-DeviceHubWorker
}
function Format-HubMinute($Minute){if($null -eq $Minute){return '直到暂停'};return ('{0:00}:{1:00}' -f [int][Math]::Floor($Minute/60),($Minute%60))}
function Update-HubDeviceActions {
    if(-not $Script:DeviceHubForm){return};$tag=$Script:DeviceHubForm.Tag
    $device=if($tag.Devices.CurrentRow){$tag.Devices.CurrentRow.Tag}else{$null}
    $can=(Get-DeviceHubConfig).enabled -and $tag.Fresh -and $device -and $device.switch
    $tag.On.Enabled=$can;$tag.Off.Enabled=$can;$tag.Add.Enabled=$can
}
function Test-HubRulesConflict($First,$Second){
    if($First.did -ne $Second.did -or $First.value -eq $Second.value -or -not $First.enabled -or -not $Second.enabled){return $false}
    for($minute=0;$minute -lt 1440;$minute++){
        $a=if($First.mode -eq 'once'){$minute -eq $First.startMinute}elseif($null -eq $First.endMinute){$true}elseif($First.startMinute -lt $First.endMinute){$minute -ge $First.startMinute -and $minute -lt $First.endMinute}else{$minute -ge $First.startMinute -or $minute -lt $First.endMinute}
        $b=if($Second.mode -eq 'once'){$minute -eq $Second.startMinute}elseif($null -eq $Second.endMinute){$true}elseif($Second.startMinute -lt $Second.endMinute){$minute -ge $Second.startMinute -and $minute -lt $Second.endMinute}else{$minute -ge $Second.startMinute -or $minute -lt $Second.endMinute}
        if($a -and $b){return $true}
    };return $false
}
function Update-DeviceHubWindow {
    $form=$Script:DeviceHubForm;if(-not $form -or $form.IsDisposed){return};$tag=$form.Tag
    try{
        $config=Get-DeviceHubConfig;$status=Read-AtomicJson (Join-Path (Get-DeviceHubRoot) '.codex\device-hub\status.json')
        $fresh=([DateTime]::UtcNow-([DateTime]$status.observedAt).ToUniversalTime()).TotalSeconds -lt 90
        $tag.Status.Text=if($fresh){$status.message}else{'中枢响应过期 · 状态未知'}
        $tag.Pause.Text=if($config.enabled){'暂停中枢'}else{'启动中枢'}
        $selected=if($tag.Devices.CurrentRow){$tag.Devices.CurrentRow.Tag.did}else{''}
        $tag.Devices.Rows.Clear()
        foreach($device in $status.devices){
            $deviceFresh=$device.observedAt -and ([DateTime]::UtcNow-([DateTime]$device.observedAt).ToUniversalTime()).TotalSeconds -lt 90
            $label=if(-not $config.enabled -and $device.switch){'已暂停监测'}elseif(-not $fresh){'状态未知'}elseif($null -eq $device.state){$device.message}elseif(-not $deviceFresh){'读数过期'}elseif($device.state){'开启'}else{'关闭'}
            $idx=$tag.Devices.Rows.Add([object[]]@($device.name,$label,$device.model,$(if($device.switch){'云端开关'}else{'只读 / 专用入口'})))
            $tag.Devices.Rows[$idx].Tag=$device
            if($device.did -eq $selected){$tag.Devices.CurrentCell=$tag.Devices.Rows[$idx].Cells[0]}
            if($config.enabled -and $fresh -and $deviceFresh -and $null -ne $device.state){$tag.Devices.Rows[$idx].Cells[1].Style.ForeColor=if($device.state){[Drawing.Color]::FromArgb(173,107,35)}else{[Drawing.Color]::FromArgb(32,125,101)}}
        }
        $selectedRule=if($tag.Rules.CurrentRow){$tag.Rules.CurrentRow.Tag.id}else{''}
        $tag.Rules.Rows.Clear()
        foreach($rule in @($config.rules)){
            $runtime=$status.rules.($rule.id)
            $description=if($rule.mode -eq 'guard'){'每天 {0}–{1} · 保持{2}' -f (Format-HubMinute $rule.startMinute),(Format-HubMinute $rule.endMinute),$(if($rule.value){'开启'}else{'关闭'})}else{'每天 {0} · {1}一次' -f (Format-HubMinute $rule.startMinute),$(if($rule.value){'开启'}else{'关闭'})}
            $state=if(-not $rule.enabled){'已暂停'}elseif(-not $config.enabled){'中枢已暂停'}elseif(-not $fresh){'状态未知'}elseif($runtime){$runtime.message}else{'等待检查'}
            $idx=$tag.Rules.Rows.Add([object[]]@($rule.name,$description,$state));$tag.Rules.Rows[$idx].Tag=$rule
            if($rule.id -eq $selectedRule){$tag.Rules.CurrentCell=$tag.Rules.Rows[$idx].Cells[0]}
        }
        $tag.Events.Text=(@($status.events | Select-Object -Last 3 | ForEach-Object {([DateTime]$_.at).ToString('HH:mm:ss')+'  '+$_.message}) -join "`r`n")
        $tag.Fresh=$fresh;Update-HubDeviceActions
    }catch{$tag.Status.Text='等待设备中枢连接；首次使用可先扫码授权'}
}
function New-HubGrid($Parent,[int]$Y,[int]$Height,$Columns){
    $grid=New-Object Windows.Forms.DataGridView;$grid.SetBounds(20,$Y,860,$Height);$grid.ReadOnly=$true;$grid.AllowUserToAddRows=$false;$grid.AllowUserToDeleteRows=$false;$grid.AllowUserToResizeRows=$false;$grid.MultiSelect=$false;$grid.SelectionMode='FullRowSelect';$grid.RowHeadersVisible=$false;$grid.AutoSizeColumnsMode='Fill';$grid.BackgroundColor=[Drawing.Color]::White;$grid.BorderStyle='None';$grid.EnableHeadersVisualStyles=$false;$grid.ColumnHeadersDefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(238,243,247);$grid.ColumnHeadersHeight=32;$grid.RowTemplate.Height=34;$grid.DefaultCellStyle.SelectionBackColor=[Drawing.Color]::FromArgb(228,240,247);$grid.DefaultCellStyle.SelectionForeColor=[Drawing.Color]::FromArgb(42,55,67);$grid.AlternatingRowsDefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(248,250,252)
    foreach($column in $Columns){$i=$grid.Columns.Add($column[0],$column[1]);$grid.Columns[$i].FillWeight=$column[2];$grid.Columns[$i].SortMode='NotSortable'}
    $Parent.Controls.Add($grid);return $grid
}
function Show-HubRuleEditor {
    param($Device,$Rule=$null,[switch]$ReturnForm)
    if(-not $Device.switch){return}
    $form=New-Object Windows.Forms.Form;Initialize-ModernForm $form '设备定时任务' 500 400
    $form.Controls.Add((New-ModernLabel $Device.name 20 18 460))
    $form.Controls.Add((New-ModernLabel '任务名称' 20 65 110));$name=New-Object Windows.Forms.TextBox;$name.SetBounds(160,63,314,26);$name.MaxLength=200;$name.Text=if($Rule){$Rule.name}else{'夜间保持关闭'};$form.Controls.Add($name)
    $form.Controls.Add((New-ModernLabel '执行方式' 20 110 110));$mode=New-WorkstationCombo $form 160 108 180 @(@('guard','时段内保持状态'),@('once','每天定时执行一次')) $(if($Rule){$Rule.mode}else{'guard'})
    $value=New-WorkstationCombo $form 354 108 120 @(@('off','关闭'),@('on','开启')) $(if($Rule -and $Rule.value){'on'}else{'off'})
    $form.Controls.Add((New-ModernLabel '每天开始' 20 157 110));$start=New-Object Windows.Forms.DateTimePicker;$start.Format='Custom';$start.CustomFormat='HH:mm';$start.ShowUpDown=$true;$start.SetBounds(160,155,140,27);$start.Value=[DateTime]::Today.AddMinutes($(if($Rule){$Rule.startMinute}else{0}));$form.Controls.Add($start)
    $form.Controls.Add((New-ModernLabel '保持至' 20 204 110));$end=New-Object Windows.Forms.DateTimePicker;$end.Format='Custom';$end.CustomFormat='HH:mm';$end.ShowUpDown=$true;$end.SetBounds(160,202,140,27);$end.Value=[DateTime]::Today.AddMinutes($(if($Rule -and $null -ne $Rule.endMinute){$Rule.endMinute}else{420}));$form.Controls.Add($end)
    $until=New-Object Windows.Forms.CheckBox;$until.Text='直到手动暂停';$until.SetBounds(316,202,160,27);$until.Checked=($Rule -and $null -eq $Rule.endMinute);$form.Controls.Add($until)
    $hint=New-ModernLabel '每 30 秒检查；时段结束后停止保持，不自动反向开关。' 20 251 460;$hint.Height=42;$hint.ForeColor=[Drawing.Color]::FromArgb(111,122,132);$form.Controls.Add($hint)
    $errorLabel=New-ModernLabel '' 20 303 460;$errorLabel.Height=34;$errorLabel.ForeColor=[Drawing.Color]::FromArgb(174,63,66);$form.Controls.Add($errorLabel)
    $save=New-EnergyButton '保存并启用' 332 350 142;$form.Controls.Add($save)
    $form.Tag=@{Device=$Device;Rule=$Rule;Name=$name;Mode=$mode;Value=$value;Start=$start;End=$end;Until=$until;Error=$errorLabel}
    $update={param($sender,$args) $t=$sender.FindForm().Tag;$t.Until.Enabled=$t.Mode.SelectedItem.Value -eq 'guard';$t.End.Enabled=$t.Until.Enabled -and -not $t.Until.Checked}
    $until.Add_CheckedChanged($update);$mode.Add_SelectedIndexChanged($update)
    $end.Enabled=($mode.SelectedItem.Value -eq 'guard' -and -not $until.Checked)
    $save.Add_Click({param($sender,$args) $f=$sender.FindForm();$t=$f.Tag
        try{
            $startMinute=$t.Start.Value.Hour*60+$t.Start.Value.Minute
            $endMinute=if($t.Mode.SelectedItem.Value -eq 'once' -or $t.Until.Checked){$null}else{$t.End.Value.Hour*60+$t.End.Value.Minute}
            if($null -ne $endMinute -and $endMinute -eq $startMinute){throw '开始与结束不能相同；持续保持请勾选直到暂停。'}
            if([string]::IsNullOrWhiteSpace($t.Name.Text)){throw '请输入任务名称。'}
            $config=Get-DeviceHubConfig;$id=if($t.Rule){$t.Rule.id}else{[Guid]::NewGuid().ToString()}
            $rule=[PSCustomObject]@{id=$id;name=$t.Name.Text.Trim();did=$t.Device.did;model=$t.Device.model;enabled=$true;mode=$t.Mode.SelectedItem.Value;value=($t.Value.SelectedItem.Value -eq 'on');startMinute=$startMinute;endMinute=$endMinute;revision=[Guid]::NewGuid().ToString()}
            foreach($other in @($config.rules)){if($other.id -ne $id -and (Test-HubRulesConflict $other $rule)){throw '该设备存在时间冲突的相反任务，请先暂停或调整它。'}}
            if(@($config.rules).Count -ge 32 -and -not $t.Rule){throw '最多支持 32 个任务。'}
            $config.rules=@($config.rules | Where-Object {$_.id -ne $id})+@($rule);Save-DeviceHubConfig $config;Start-DeviceHubWorker;$f.Close();Update-DeviceHubWindow
        }catch{$t.Error.Text=$_.Exception.Message}
    })
    if($ReturnForm){return $form}
    [void]$form.ShowDialog();if($form.Icon){$form.Icon.Dispose()};$form.Dispose()
}
function Show-DeviceHub {
    if($Script:DeviceHubForm -and -not $Script:DeviceHubForm.IsDisposed){$Script:DeviceHubForm.Show();[ProfileVisual]::ActivateDashboard($Script:DeviceHubForm.Handle);return}
    $form=New-Object Windows.Forms.Form;Initialize-ModernForm $form 'PowerProfile · 米家设备中枢' 900 780
    $title=New-ModernLabel '米家设备中枢' 20 16 500;$title.Font=New-Object Drawing.Font 'Microsoft YaHei UI',17,([Drawing.FontStyle]::Bold);$title.Height=36;$form.Controls.Add($title)
    $status=New-ModernLabel '等待连接…' 22 60 650;$form.Controls.Add($status)
    $pause=New-EnergyButton '启动中枢' 746 54 134;$form.Controls.Add($pause)
    $devices=New-HubGrid $form 105 242 @(@('name','设备',290),@('state','开关状态',200),@('model','型号',230),@('control','控制方式',140))
    $on=New-EnergyButton '开启设备' 20 352 120;$off=New-EnergyButton '关闭设备' 152 352 120;$add=New-EnergyButton '添加定时任务' 284 352 148
    foreach($b in @($on,$off,$add)){$form.Controls.Add($b)}
    $refresh=New-EnergyButton '刷新设备' 610 352 128;$form.Controls.Add($refresh);$login=New-EnergyButton '米家扫码授权' 750 352 130;$form.Controls.Add($login)
    $form.Controls.Add((New-ModernLabel '定时任务 · 北京时间' 20 402 450))
    $rules=New-HubGrid $form 440 155 @(@('name','任务',260),@('window','执行时间与动作',330),@('state','执行状态',270))
    $edit=New-EnergyButton '编辑任务' 20 607 120;$toggle=New-EnergyButton '启用 / 暂停' 152 607 132;$remove=New-EnergyButton '移除任务' 296 607 120
    foreach($b in @($edit,$toggle,$remove)){$form.Controls.Add($b)}
    $events=New-ModernLabel '' 22 651 856;$events.Height=58;$events.Font=New-Object Drawing.Font 'Microsoft YaHei UI',8;$events.ForeColor=[Drawing.Color]::FromArgb(111,122,132);$form.Controls.Add($events)
    $note=New-ModernLabel '需电脑唤醒、联网及网关在线；关闭窗口不停止任务。暂停中枢可停止全部任务。' 22 723 856;$note.Height=38;$note.ForeColor=[Drawing.Color]::FromArgb(111,122,132);$form.Controls.Add($note)
    $form.Tag=@{Status=$status;Pause=$pause;Devices=$devices;Rules=$rules;On=$on;Off=$off;Add=$add;Events=$events;Timer=$null;Fresh=$false};$Script:DeviceHubForm=$form
    $devices.Add_CurrentCellChanged({Update-HubDeviceActions})
    $pause.Add_Click({try{$c=Get-DeviceHubConfig;$c.enabled=-not $c.enabled;foreach($r in @($c.rules)){$r|Add-Member -NotePropertyName revision -NotePropertyValue ([Guid]::NewGuid().ToString()) -Force};Save-DeviceHubConfig $c;Start-DeviceHubWorker;Update-DeviceHubWindow}catch{$Script:DeviceHubForm.Tag.Status.Text=$_.Exception.Message}})
    $refresh.Add_Click({try{Send-DeviceHubRequest 'refresh'}catch{$Script:DeviceHubForm.Tag.Status.Text=$_.Exception.Message}})
    $login.Add_Click({Show-CloudHistory})
    foreach($pair in @(@($on,$true),@($off,$false))){$pair[0].Tag=$pair[1];$pair[0].Add_Click({param($sender,$args) try{if($Script:DeviceHubForm.Tag.Devices.CurrentRow){Send-DeviceHubRequest 'set' $Script:DeviceHubForm.Tag.Devices.CurrentRow.Tag $sender.Tag}}catch{$Script:DeviceHubForm.Tag.Status.Text=$_.Exception.Message}})}
    $add.Add_Click({if($Script:DeviceHubForm.Tag.Devices.CurrentRow){Show-HubRuleEditor $Script:DeviceHubForm.Tag.Devices.CurrentRow.Tag}})
    $edit.Add_Click({$tag=$Script:DeviceHubForm.Tag;if($tag.Rules.CurrentRow){$rule=$tag.Rules.CurrentRow.Tag;$device=@($tag.Devices.Rows | Where-Object {$_.Tag.did -eq $rule.did})[0].Tag;if($device){Show-HubRuleEditor $device $rule}}})
    $toggle.Add_Click({try{$tag=$Script:DeviceHubForm.Tag;if($tag.Rules.CurrentRow){$id=$tag.Rules.CurrentRow.Tag.id;$c=Get-DeviceHubConfig;foreach($r in @($c.rules)){if($r.id -eq $id){$r.enabled=-not $r.enabled;$r|Add-Member -NotePropertyName revision -NotePropertyValue ([Guid]::NewGuid().ToString()) -Force}};Save-DeviceHubConfig $c;Start-DeviceHubWorker;Update-DeviceHubWindow}}catch{$Script:DeviceHubForm.Tag.Status.Text=$_.Exception.Message}})
    $remove.Add_Click({$tag=$Script:DeviceHubForm.Tag;if($tag.Rules.CurrentRow){$id=$tag.Rules.CurrentRow.Tag.id;$c=Get-DeviceHubConfig;$c.rules=@($c.rules | Where-Object {$_.id -ne $id});Save-DeviceHubConfig $c;Update-DeviceHubWindow}})
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=3000;$timer.Add_Tick({Update-DeviceHubWindow});$form.Tag.Timer=$timer
    $form.Add_FormClosed({param($sender,$args) $sender.Tag.Timer.Stop();$sender.Tag.Timer.Dispose();if($sender.Icon){$sender.Icon.Dispose()};$Script:DeviceHubForm=$null})
    $c=Get-DeviceHubConfig;if(-not(Test-Path (Join-Path (Get-DeviceHubRoot) 'devices.hub.json'))){Save-DeviceHubConfig $c}
    if($c.enabled){Start-DeviceHubWorker};Update-DeviceHubWindow;$timer.Start();$form.Show();[ProfileVisual]::ActivateDashboard($form.Handle)
}
function Initialize-DeviceHub {
    try{if((Get-DeviceHubConfig).enabled){Start-DeviceHubWorker}}catch{}
    if(-not $Script:DeviceHubTick){
        $Script:DeviceHubTick=New-Object Windows.Forms.Timer;$Script:DeviceHubTick.Interval=60000
        $Script:DeviceHubTick.Add_Tick({try{if((Get-DeviceHubConfig).enabled){Start-DeviceHubWorker}}catch{}})
        $Script:DeviceHubTick.Start()
        [Windows.Forms.Application]::add_ApplicationExit({if($Script:DeviceHubTick){$Script:DeviceHubTick.Stop();$Script:DeviceHubTick.Dispose()}})
    }
}
