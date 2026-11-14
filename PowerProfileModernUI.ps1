Add-Type -Path (Join-Path $ScriptDir 'PowerProfileUI.cs') -ReferencedAssemblies System.Drawing,System.Windows.Forms
. (Join-Path $ScriptDir 'PowerProfileVersion.ps1')
. (Join-Path $ScriptDir 'PowerProfileWorkstation.ps1')
. (Join-Path $ScriptDir 'PowerProfileDetection.ps1')
. (Join-Path $ScriptDir 'PowerProfileLog.ps1')
$Script:ModernFont=New-Object Drawing.Font 'Microsoft YaHei UI',9
$Script:Dashboard=$null
$Script:TelemetryProcess=$null
$Script:LogViewer=$null
$Script:DashboardTip=New-Object Windows.Forms.ToolTip
. (Join-Path $ScriptDir 'PowerProfileEnergyUI.ps1')
. (Join-Path $ScriptDir 'PowerProfileDeviceHubUI.ps1')

function Get-ModernUIOptions {
    $o=@{toastEnabled=$true}
    try { $j=Read-AtomicJson $SettingsPath; if($j.ui.toastEnabled -is [bool]){$o.toastEnabled=$j.ui.toastEnabled} } catch {}
    return $o
}
function Save-WorkstationOptions {
    param([bool]$Enabled,[int]$Frequency,[string]$PausedUntil='',[int]$AwayMinutes,[string]$Schedule,[int]$StartMinute,[int]$EndMinute,[int]$QuietConfirmSeconds,$ToastEnabled=$null,[string]$SettingsFile=$SettingsPath)
    if([string]::IsNullOrWhiteSpace($SettingsFile)){$SettingsFile=Join-Path $PSScriptRoot 'settings.json'}
    $json=Read-AtomicJson $SettingsFile
    $options=Get-WorkstationOptions $json
    foreach($key in @('AwayMinutes','Schedule','StartMinute','EndMinute','QuietConfirmSeconds')){if($PSBoundParameters.ContainsKey($key)){$options[$key]=$PSBoundParameters[$key]}}
    $checked=Get-WorkstationOptions ([PSCustomObject]@{workstation=[PSCustomObject]$options})
    if(-not $checked.scheduleValid){throw '请选择有效日期、1–240 分钟等待、同一天的开始/结束时间，以及至少 10 秒的低负载确认时间。'}
    $minimum=[int]$json.modes.Idle.min
    $base=[int]$json.processorBaseMHz
    if($Enabled -and ($base -le 0 -or $Frequency -lt 500 -or $Frequency -ge $json.modes.Idle.freqMax -or [Math]::Floor(100*$Frequency/$base) -lt $minimum+5)){throw '频率必须低于静音档，且保持原最低处理器比例；请先校准基频。'}
    $w=if($json.workstation){$json.workstation}else{[PSCustomObject]@{}}
    foreach($pair in @(@('enabled',$Enabled),@('freqMax',$Frequency),@('awayMinutes',$checked.awayMinutes),@('schedule',$checked.schedule),@('startMinute',$checked.startMinute),@('endMinute',$checked.endMinute),@('quietConfirmSeconds',$checked.quietConfirmSeconds),@('pausedUntil',$PausedUntil))){$w | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] -Force}
    $json | Add-Member -NotePropertyName workstation -NotePropertyValue $w -Force
    if($ToastEnabled -is [bool]){
        $ui=if($json.ui){$json.ui}else{[PSCustomObject]@{}}
        $ui | Add-Member -NotePropertyName toastEnabled -NotePropertyValue $ToastEnabled -Force
        $json | Add-Member -NotePropertyName ui -NotePropertyValue $ui -Force
    }
    Write-AtomicJson $SettingsFile $json -Pretty
    $Script:ProfileSettingsHash=Get-ProfileFileHash $SettingsFile
    Write-ProfileEvent 'settings.workstation.saved' '保存附加省电配置' -Data @{enabled=$Enabled;freqMax=$Frequency;awayMinutes=$checked.awayMinutes;schedule=$checked.schedule;startMinute=$checked.startMinute;endMinute=$checked.endMinute;quietConfirmSeconds=$checked.quietConfirmSeconds;pausedUntil=$PausedUntil}
}
function New-WorkstationCombo {
    param($Parent,[int]$X,[int]$Y,[int]$Width,$Choices,$Selected)
    $combo=New-Object Windows.Forms.ComboBox;$combo.DropDownStyle='DropDownList';$combo.DisplayMember='Label';$combo.SetBounds($X,$Y,$Width,27)
    foreach($choice in $Choices){[void]$combo.Items.Add([PSCustomObject]@{Value=$choice[0];Label=[string]$choice[1]})}
    for($i=0;$i -lt $combo.Items.Count;$i++){if([string]$combo.Items[$i].Value -eq [string]$Selected){$combo.SelectedIndex=$i;break}}
    if($combo.SelectedIndex -lt 0){$combo.SelectedIndex=$combo.Items.Add([PSCustomObject]@{Value=$Selected;Label="当前配置：$Selected"})}
    $Parent.Controls.Add($combo);return $combo
}
function Open-ModernDashboard {
    $ErrorActionPreference='Stop'
    try {
        Show-ModernDashboard
        if(-not [ProfileVisual]::IsWindowVisible($Script:Dashboard.Handle)){throw 'Windows 窗口可见性检查失败'}
        Write-ProfileEvent 'ui.dashboard.open' '运行状态窗口已显示并激活' -Data @{handle=$Script:Dashboard.Handle.ToInt64()}
    }
    catch {
        Write-ProfileEvent 'ui.dashboard.failed' $_.Exception.Message 'ERROR' @{stack=$_.ScriptStackTrace;position=$_.InvocationInfo.PositionMessage}
        if($Script:Dashboard -and -not $Script:Dashboard.IsDisposed){$Script:Dashboard.Close()}
        [void][Windows.Forms.MessageBox]::Show("运行状态窗口打开失败：$($_.Exception.Message)`r`n详细原因已写入本日日志。",'PowerProfile')
    }
}
function New-ModernLabel {
    param([string]$Text,[int]$X,[int]$Y,[int]$Width=330)
    $label=New-Object Windows.Forms.Label
    $label.Text=$Text;$label.Font=$Script:ModernFont;$label.AutoSize=$false
    $label.SetBounds($X,$Y,$Width,25)
    return $label
}
function Invoke-DashboardAction {
    param([string]$Action)
    try {
        if($Action -eq 'More'){return}
        if($Script:DashboardActions -and $Script:DashboardActions.ContainsKey($Action)){$Script:DashboardActions[$Action].PerformClick()}
        elseif($Action -eq 'Settings'){Show-ModernSettings}
        elseif($Action -eq 'Logs'){Show-ModernLogViewer}
        else{throw '托盘操作尚未初始化，请稍后重试。'}
        Update-ModernDashboard
    }catch{Write-ProfileEvent 'ui.dashboard.action.failed' $_.Exception.Message 'ERROR' @{action=$Action};[void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'PowerProfile')}
}
function New-DashboardButton {
    param($Parent,[string]$Text,[int]$X,[int]$Y,[int]$Width,[string]$Action)
    $button=New-Object Windows.Forms.Button;$button.Text=$Text;$button.SetBounds($X,$Y,$Width,30);$button.FlatStyle='Flat';$button.FlatAppearance.BorderColor=[Drawing.Color]::FromArgb(217,225,231);$button.BackColor=[Drawing.Color]::White;$button.Tag=$Action
    $button.Add_Click({param($sender,$eventArgs) Invoke-DashboardAction $sender.Tag})
    $Parent.Controls.Add($button);return $button
}
function Initialize-ModernForm {
    param($Form,[string]$Title,[int]$Width,[int]$Height)
    $Form.Text=$Title;$Form.Font=$Script:ModernFont
    $Form.ClientSize=New-Object Drawing.Size $Width,$Height
    $Form.AutoScroll=$true;$Form.AutoScrollMinSize=New-Object Drawing.Size $Width,$Height
    $Form.BackColor=[Drawing.Color]::FromArgb(250,250,250)
    $Form.AutoScaleMode='Dpi';$Form.StartPosition='CenterScreen'
    $Form.FormBorderStyle='FixedDialog';$Form.MaximizeBox=$false;$Form.MinimizeBox=$false
    $Form.Icon=[ProfileVisual]::CreateIcon('Balanced')
    $Form.Add_Shown({param($sender,$eventArgs) [ProfileVisual]::ActivateDashboard($sender.Handle)})
}
function Invoke-TelemetrySample {
    $timedOut=$false
    if($Script:TelemetryProcess -and -not $Script:TelemetryProcess.HasExited){
        # A partial snapshot is progress, even while WMI/PDH is still completing.
        try {
            $progress=Read-AtomicJson (Join-Path $ScriptDir 'system_status.json')
            if($progress.operationId -eq $Script:TelemetryOperationId){
                $stamp=([DateTime]$progress.observedAt).ToUniversalTime()
                if($stamp -gt $Script:TelemetryProgressAt){$Script:TelemetryProgressAt=$stamp}
            }
        } catch {}
        $elapsed=([DateTime]::UtcNow-$Script:TelemetryStarted).TotalSeconds
        if($elapsed -lt 45 -and ([DateTime]::UtcNow-$Script:TelemetryProgressAt).TotalSeconds -lt 30){return}
        $Script:TelemetryProcess.Kill()
        $timedOut=$true
        Write-ProfileEvent 'telemetry.timeout' '只读采样长时间无进展，已终止并重新采样' 'WARN' @{childOperationId=$Script:TelemetryOperationId;elapsedSeconds=[Math]::Round($elapsed,1);lastStage=$progress.stage}
    }
    if(-not $timedOut -and $Script:TelemetryProcess -and $Script:TelemetryProcess.HasExited -and $Script:TelemetryProcess.ExitCode -ne 0){Write-ProfileEvent 'telemetry.failed' '只读采样进程失败，将重试；请按关联操作查阅具体异常' 'WARN' @{exitCode=$Script:TelemetryProcess.ExitCode;childOperationId=$Script:TelemetryOperationId}}
    if($Script:TelemetryProcess){$Script:TelemetryProcess.Dispose()}
    $Script:TelemetryStarted=[DateTime]::UtcNow
    $Script:TelemetryProgressAt=$Script:TelemetryStarted
    $Script:TelemetryOperationId=[Guid]::NewGuid().ToString()
    $Script:TelemetryProcess=Start-HiddenPowerShell @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f (Join-Path $ScriptDir 'Read-SystemStatus.ps1')),'-OperationId',$Script:TelemetryOperationId)
}
function Show-ModernLogViewer {
    param([string]$Search='')
    $ErrorActionPreference='Stop'
    try{
        if(-not ('ProfileLogViewer' -as [type])){Add-Type -Path (Join-Path $ScriptDir 'PowerProfileLogViewer.cs') -ReferencedAssemblies System.Drawing,System.Windows.Forms,System.Web.Extensions}
        if(-not $Script:LogViewer -or $Script:LogViewer.IsDisposed){
            $Script:LogViewer=New-Object ProfileLogViewer $ScriptDir
            $Script:LogViewer.Icon.Dispose();$Script:LogViewer.Icon=[ProfileVisual]::CreateIcon('Balanced')
            $Script:LogViewer.Add_FormClosed({$Script:LogViewer=$null})
        }
        if($Search){$Script:LogViewer.SelectSearch($Search)}
        $Script:LogViewer.Show();[ProfileVisual]::ActivateDashboard($Script:LogViewer.Handle);$Script:LogViewer.Activate()
    }catch{Write-ProfileEvent 'ui.log.failed' $_.Exception.Message 'ERROR' @{stack=$_.ScriptStackTrace};[void][Windows.Forms.MessageBox]::Show("日志窗口打开失败：$($_.Exception.Message)",'PowerProfile')}
}
function Update-ModernDashboard {
    if(-not $Script:Dashboard -or $Script:Dashboard.IsDisposed){return}
    $fields=$Script:Dashboard.Tag.Fields
    $mode=Get-CurrentMode
    if($Script:Dashboard.Tag.Actions){
        foreach($key in @('Auto','Idle','Balanced','Game')){
            $button=$Script:Dashboard.Tag.Actions[$key]
            $selected=if($key -eq 'Auto'){Get-AutoEnabled}else{$key -eq $mode}
            $button.BackColor=if($selected){[Drawing.Color]::FromArgb(228,240,247)}else{[Drawing.Color]::White}
            $button.ForeColor=if($selected){[Drawing.Color]::FromArgb(39,106,159)}else{[Drawing.Color]::FromArgb(42,55,67)}
            $button.Text=if($key -eq 'Auto'){if(Get-AutoEnabled){'自动切换 · 开'}else{'自动切换 · 关'}}else{$Script:Settings.modes[$key].name}
        }
    }
    $fields.mode.Text="$(if($Script:Settings.modes.ContainsKey($mode)){$Script:Settings.modes[$mode].name}else{$mode}) · $(if(Get-AutoEnabled){'自动'}else{'手动锁定'})"
    $d=Read-GameDetectionState
    $fields.reason.Text=if($d.Fresh){([string]$d.Reason -split ';')[0]}else{'等待新一轮检测 · 原有控制逻辑保持'}
    $Script:DashboardTip.SetToolTip($fields.reason,[string]$d.Reason)
    $idleSeconds=Get-UserActivityIdleSeconds
    $fields.idle.Text="$([int][Math]::Floor($idleSeconds/60)) 分 $($idleSeconds%60) 秒 · 含远程输入"
    $limit=if($Script:Settings.modes.ContainsKey($mode)){$Script:Settings.modes[$mode].freqMax}else{$null}
    $fields.limit.Text=if($null -eq $limit){'--'}elseif($limit -eq 0){'不设额外频率上限'}else{('{0:N2} GHz' -f ($limit/1000.0))}
    $fields.mode.ForeColor=[Drawing.Color]::FromArgb(36,124,112)
    if($mode -eq 'Game'){$fields.mode.ForeColor=[Drawing.Color]::FromArgb(151,75,83)}
    elseif($mode -eq 'Balanced'){$fields.mode.ForeColor=[Drawing.Color]::FromArgb(39,106,159)}
    $power=[Windows.Forms.SystemInformation]::PowerStatus
    $fields.power.Text=switch([string]$power.PowerLineStatus){'Online'{'已接电 · 交流电'};'Offline'{if($power.BatteryLifePercent -ge 0){'电池供电 · '+[Math]::Round(100*$power.BatteryLifePercent)+'%'}else{'电池供电'}};default{'供电状态未知'}}
    $uptime=[ProfileSystemStatus]::Uptime()
    $fields.uptime.Text="$(if($uptime.Days){"$($uptime.Days) 天 "})$($uptime.Hours) 小时 $($uptime.Minutes) 分钟"
    $fields.plan.Text='附加省电：等待检测'
    try{
        $ws=Read-AtomicJson (Join-Path $ScriptDir 'workstation_state.json')
        $age=([DateTime]::UtcNow-([DateTime]$ws.observedAt).ToUniversalTime()).TotalSeconds
        $fields.plan.Text=if($age -gt 45){'附加省电：检测过期，等待恢复检查'}else{"附加省电：$(if($ws.active){'已生效'}else{'未生效'}) · $($ws.reason)"}
        if($ws.active -and $mode -eq 'Idle'){
            $fields.mode.Text="工作站省电 · $(if(Get-AutoEnabled){'自动'}else{'手动锁定'})"
            $fields.mode.ForeColor=[Drawing.Color]::FromArgb(39,106,159)
            $fields.plan.Text="基础档位：静音 · $($fields.plan.Text)"
            $fields.limit.Text=('{0:N2} GHz · 工作站附加上限' -f ($ws.freqMax/1000.0))
        }
    }catch{}
    $Script:DashboardTip.SetToolTip($fields.plan,$fields.plan.Text)
    $j=$null
    try {
        $j=Read-AtomicJson (Join-Path $ScriptDir 'system_status.json')
        $age=([DateTime]::UtcNow-([DateTime]$j.observedAt).ToUniversalTime()).TotalSeconds
    } catch {$age=999999}
    $fields.hardware.Text=if($j.hardware.cpuName){$j.hardware.cpuName}else{'运行状态 · 按需系统监测'}
    $Script:DashboardTip.SetToolTip($fields.hardware,"$($j.hardware.cpuName)`r`n$($j.hardware.cores) 核心 / $($j.hardware.logicalProcessors) 逻辑处理器")
    $frequency=$j.cpuFrequencyMHz;$frequencyState=$j.fieldStates.cpuFrequencyMHz
    $frequencyAge=999999
    if($frequencyState.observedAt){try{$frequencyAge=([DateTime]::UtcNow-([DateTime]$frequencyState.observedAt).ToUniversalTime()).TotalSeconds}catch{}}
    $frequencyValid=$null -ne $frequency -and $frequencyAge -ge 0 -and $frequencyAge -le 60
    $frequencyStale=$frequencyValid -and ($frequencyAge -gt 15 -or $frequencyState.state -eq 'stale')
    $fields.frequency.Text=if($frequencyValid){('{0:N2} GHz{1}' -f ($frequency/1000.0),$(if($frequencyStale){' · 旧值'}else{''}))}else{'等待采样'}
    $fields.frequency.ForeColor=if($frequencyValid -and -not $frequencyStale){[Drawing.Color]::FromArgb(39,106,159)}else{[Drawing.Color]::FromArgb(133,142,150)}
    $Script:DashboardTip.SetToolTip($fields.frequency,"Windows 标称频率 × Processor Performance 的总体估算；不同核心频率可能不同，不是逐核心硬件测频。`r`n采样时间：$($frequencyState.observedAt)`r`n$($frequencyState.reason)")
    $degraded=$false
    foreach($pair in @(@('cpu','cpu'),@('gpu','gpu3d'),@('video','videoEncode'),@('compute','compute'),@('memory','memoryPercent'))) {
        $key=$pair[0];$metric=$pair[1];$v=$j.$metric;$metadata=$j.fieldStates.$metric
        $valueAge=$age
        if($metadata.observedAt){try{$valueAge=([DateTime]::UtcNow-([DateTime]$metadata.observedAt).ToUniversalTime()).TotalSeconds}catch{}}
        $valid=($null -ne $v -and $valueAge -ge 0 -and $valueAge -le 60)
        $stale=$valid -and ($valueAge -gt 15 -or $metadata.state -eq 'stale')
        $fields[$key].Text=if($valid){"$v%$(if($stale){' · 旧值'})"}elseif($metadata.reason -match '驱动未提供'){'未提供'}else{'--'}
        $fields[$key].ForeColor=if($stale -or -not $valid){[Drawing.Color]::FromArgb(133,142,150)}else{[Drawing.Color]::FromArgb(42,55,67)}
        $bar=$Script:Dashboard.Tag.Bars[$key];$bar.Percent=if($valid){[double]$v}else{-1}
        $bar.ForeColor=if($stale){[Drawing.Color]::FromArgb(163,177,188)}else{[Drawing.Color]::FromArgb(39,106,159)}
        $stamp=if($metadata.observedAt){$metadata.observedAt}else{$j.observedAt}
        $hint=if($stale){"最近有效值：$(([DateTime]$stamp).ToLocalTime().ToString('HH:mm:ss'))`r`n$($metadata.reason)"}elseif(-not $valid){$(if($metadata.reason){$metadata.reason}else{'等待有效采样'})}else{'实时采样'}
        $Script:DashboardTip.SetToolTip($fields[$key],$hint);$Script:DashboardTip.SetToolTip($bar,$hint)
        if($stale -or -not $valid){$degraded=$true}
    }
    if($null -ne $j.memoryUsedGB -and $age -le 60){$fields.memory.Text+=" · $($j.memoryUsedGB) / $($j.memoryTotalGB) GB";$Script:DashboardTip.SetToolTip($fields.memory,"已用 $($j.memoryUsedGB) GB / 总计 $($j.memoryTotalGB) GB")}
    $fields.updated.Text=if($age -le 15){"更新 $(([DateTime]$j.observedAt).ToLocalTime().ToString('HH:mm:ss'))$(if($j.stage -eq 'gpu-loading'){' · GPU 刷新中'}elseif($degraded){' · 部分指标有说明'})"}else{'采样延迟 · 正在自动重试'}
    Update-EnergySummary
}
function Show-ModernDashboard {
    if($Script:Dashboard -and -not $Script:Dashboard.IsDisposed){$Script:Dashboard.WindowState='Normal';$Script:Dashboard.Show();[ProfileVisual]::ActivateDashboard($Script:Dashboard.Handle);$Script:Dashboard.Activate();return}
    try {Initialize-EnergyService} catch {Write-ProfileEvent 'energy.start.failed' '用电模块暂不可用；继续显示系统状态' 'WARN'}
    $form=New-Object Windows.Forms.Form
    Initialize-ModernForm $form 'PowerProfile · 概览' 500 804
    $form.ShowInTaskbar=$true
    $fields=@{};$bars=@{}
    $accent=New-Object Windows.Forms.Panel;$accent.BackColor=[Drawing.Color]::FromArgb(39,106,159);$accent.SetBounds(18,20,4,49);$form.Controls.Add($accent)
    $fields.mode=New-ModernLabel '' 34 17 425
    $fields.mode.Height=32;$fields.mode.Font=New-Object Drawing.Font 'Microsoft YaHei UI',14,([Drawing.FontStyle]::Bold)
    $subtitle=New-ModernLabel '运行状态 · 按需系统监测' 34 51 445;$subtitle.ForeColor=[Drawing.Color]::FromArgb(111,122,132);$subtitle.AutoEllipsis=$true;$fields.hardware=$subtitle
    $fields.reason=New-ModernLabel '' 18 82 443;$fields.reason.AutoEllipsis=$true
    $form.Controls.Add($fields.mode);$form.Controls.Add($subtitle);$form.Controls.Add($fields.reason)
    $actions=@{}
    $actions.Auto=New-DashboardButton $form '自动切换' 18 114 131 'Auto'
    $x=159
    foreach($key in @('Idle','Balanced','Game')){$actions[$key]=New-DashboardButton $form $Script:Settings.modes[$key].name $x 114 101 $key;$x+=111}
    $Script:DashboardTip.SetToolTip($actions.Auto,'开启或关闭自动档位检测；选择具体档位会进入手动锁定。')
    $card=New-Object Windows.Forms.Panel;$card.BackColor=[Drawing.Color]::White;$card.SetBounds(12,160,476,235);$form.Controls.Add($card)
    $card.Controls.Add((New-ModernLabel 'CPU 当前频率 · 估算' 14 15 185))
    $fields.frequency=New-ModernLabel '等待采样' 235 8 225;$fields.frequency.Height=34;$fields.frequency.TextAlign='TopRight';$fields.frequency.Font=New-Object Drawing.Font 'Segoe UI',18,([Drawing.FontStyle]::Bold);$card.Controls.Add($fields.frequency)
    $divider=New-Object Windows.Forms.Panel;$divider.BackColor=[Drawing.Color]::FromArgb(234,239,242);$divider.SetBounds(14,47,448,1);$card.Controls.Add($divider)
    $y=61
    foreach($row in @(@('CPU','cpu'),@('GPU 3D','gpu'),@('视频编码','video'),@('GPU 计算','compute'),@('内存','memory'))){
        $caption=New-ModernLabel $row[0] 14 $y 87;$caption.ForeColor=[Drawing.Color]::FromArgb(91,107,118)
        $bar=New-Object ProfileMetricBar;$bar.SetBounds(107,($y+5),128,10);$bar.ForeColor=[Drawing.Color]::FromArgb(39,106,159)
        $value=New-ModernLabel '--' 240 $y 220;$value.TextAlign='TopRight'
        $card.Controls.Add($caption);$card.Controls.Add($bar);$card.Controls.Add($value)
        $fields[$row[1]]=$value;$bars[$row[1]]=$bar;$y+=32
    }
    $energy=New-Object Windows.Forms.Panel;$energy.BackColor=[Drawing.Color]::White;$energy.SetBounds(12,409,476,124);$form.Controls.Add($energy)
    $energy.Controls.Add((New-ModernLabel '电脑用电' 14 11 170))
    $fields.energyStatus=New-ModernLabel '未连接' 250 11 210;$fields.energyStatus.TextAlign='TopRight';$fields.energyStatus.ForeColor=[Drawing.Color]::FromArgb(36,124,112);$energy.Controls.Add($fields.energyStatus)
    foreach($row in @(@('当前功率','watts',14),@('今日估算用电','energyToday',167),@('今日估算电费','energyFee',320))){
        $caption=New-ModernLabel $row[0] $row[2] 43 143;$caption.ForeColor=[Drawing.Color]::FromArgb(111,122,132);$energy.Controls.Add($caption)
        $value=New-ModernLabel '--' $row[2] 68 143;$value.Font=New-Object Drawing.Font 'Microsoft YaHei UI',11,([Drawing.FontStyle]::Bold);$energy.Controls.Add($value);$fields[$row[1]]=$value
    }
    $source=New-ModernLabel '米家智能插座 3 · 实际采样' 14 99 210;$source.ForeColor=[Drawing.Color]::FromArgb(111,122,132);$source.Font=New-Object Drawing.Font 'Microsoft YaHei UI',8;$energy.Controls.Add($source)
    $hubLink=New-Object Windows.Forms.LinkLabel;$hubLink.Text='设备中枢 →';$hubLink.Font=$Script:ModernFont;$hubLink.SetBounds(234,97,108,25);$hubLink.LinkColor=[Drawing.Color]::FromArgb(39,106,159);$energy.Controls.Add($hubLink);$hubLink.Add_LinkClicked({Show-DeviceHub})
    $energyLink=New-Object Windows.Forms.LinkLabel;$energyLink.Text='用电详情 →';$energyLink.Font=$Script:ModernFont;$energyLink.SetBounds(352,97,110,25);$energyLink.LinkColor=[Drawing.Color]::FromArgb(39,106,159);$energy.Controls.Add($energyLink);$energyLink.Add_LinkClicked({try{Show-EnergyDetails}catch{Write-ProfileEvent 'ui.energy.open.failed' $_.Exception.GetBaseException().Message 'ERROR';[void][Windows.Forms.MessageBox]::Show('用电详情暂时无法打开，请查看日志。','PowerProfile')}})
    $details=New-Object Windows.Forms.Panel;$details.BackColor=[Drawing.Color]::White;$details.SetBounds(12,545,476,193);$form.Controls.Add($details)
    foreach($row in @(@('配置频率上限','limit',13),@('键鼠未输入','idle',41),@('供电状态','power',69),@('连续运行','uptime',97))){
        $caption=New-ModernLabel $row[0] 14 $row[2] 120;$caption.ForeColor=[Drawing.Color]::FromArgb(91,107,118)
        $value=New-ModernLabel '--' 135 $row[2] 325;$value.TextAlign='TopRight'
        $details.Controls.Add($caption);$details.Controls.Add($value);$fields[$row[1]]=$value
    }
    $fields.plan=New-ModernLabel '' 14 125 448;$fields.plan.Height=35;$fields.plan.AutoEllipsis=$true;$details.Controls.Add($fields.plan)
    $stable=New-ModernLabel '稳定参数保留 · C-state 不作更改' 14 163 448;$stable.ForeColor=[Drawing.Color]::FromArgb(36,124,112);$details.Controls.Add($stable)
    $fields.updated=New-ModernLabel '' 18 742 464;$fields.updated.ForeColor=[Drawing.Color]::FromArgb(111,122,132);$form.Controls.Add($fields.updated)
    $actions.Settings=New-DashboardButton $form '设置' 18 768 100 'Settings'
    $actions.Logs=New-DashboardButton $form '查看日志' 128 768 100 'Logs'
    $more=New-Object Windows.Forms.ContextMenuStrip;$more.Font=$Script:ModernFont
    foreach($entry in @(@('工作时段附加省电','Workstation'),@('暂停附加省电到今天结束','PauseWorkstation'),@('切换为旧版','Legacy'),@('退出 PowerProfile','Exit'))){$item=$more.Items.Add($entry[0]);$item.Tag=$entry[1];$item.Add_Click({param($sender,$eventArgs) Invoke-DashboardAction $sender.Tag})}
    $more.Add_Opening({param($sender,$eventArgs) try{$options=Get-WorkstationOptions (Read-AtomicJson $SettingsPath);$sender.Items[0].Checked=$options.enabled;$sender.Items[1].Enabled=$options.enabled}catch{}})
    $actions.More=New-DashboardButton $form '更多操作 ▾' 238 768 130 'More'
    $actions.More.Add_Click({param($sender,$eventArgs) $Script:Dashboard.Tag.MoreMenu.Show($sender,(New-Object Drawing.Point 0,$sender.Height))})
    $close=New-Object Windows.Forms.Button;$close.Text='收起';$close.SetBounds(378,768,104,30);$close.FlatStyle='Flat';$close.FlatAppearance.BorderColor=[Drawing.Color]::FromArgb(217,225,231);$form.Controls.Add($close)
    $close.Add_Click({$Script:Dashboard.Close()})
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=5000
    $timer.Add_Tick({try{Invoke-TelemetrySample;Update-ModernDashboard}catch{Write-ProfileEvent 'ui.dashboard.refresh.failed' $_.Exception.Message 'ERROR' @{stack=$_.ScriptStackTrace}}})
    $form.Tag=@{Fields=$fields;Bars=$bars;Timer=$timer;Actions=$actions;MoreMenu=$more}
    $form.Add_FormClosed({
        param($sender,$eventArgs)
        $sender.Tag.Timer.Stop();$sender.Tag.Timer.Dispose()
        $sender.Tag.MoreMenu.Dispose()
        if($Script:TelemetryProcess -and -not $Script:TelemetryProcess.HasExited){try{$Script:TelemetryProcess.Kill()}catch{}}
        if($Script:TelemetryProcess){$Script:TelemetryProcess.Dispose();$Script:TelemetryProcess=$null}
        if($sender.Icon){$sender.Icon.Dispose()}
        $Script:Dashboard=$null
    })
    $Script:Dashboard=$form;Invoke-TelemetrySample;Update-ModernDashboard
    $timer.Start();$form.TopMost=$true;$form.Show();[ProfileVisual]::ActivateDashboard($form.Handle);$form.Activate();$form.TopMost=$false
}

# A configured meter continues accumulating while the dashboard is closed.
try {Initialize-EnergyService} catch {Write-ProfileEvent 'energy.start.failed' '用电模块无法启动；原电源控制继续运行' 'ERROR' @{reason=$_.Exception.GetBaseException().Message}}
Initialize-DeviceHub

function Update-WorkstationTimeControls {
    param($Form)
    if(-not $Form -or -not $Form.Tag){return}
    $plan=$Form.Tag.Plan
    $plan.Start.Enabled=-not $plan.AllDay.Checked;$plan.End.Enabled=-not $plan.AllDay.Checked
    $plan.TimeHint.Text=if($plan.AllDay.Checked){'全天 00:00–24:00；仍需满足离开和低负载条件'}else{'北京时间；结束 00:00 表示当天 24:00'}
}
function Save-ModernSettingsForm {
    param($Form)
    $plan=$Form.Tag.Plan
    $startMinute=if($plan.AllDay.Checked){0}else{[int]$plan.Start.Value.TimeOfDay.TotalMinutes}
    $endMinute=if($plan.AllDay.Checked){1440}else{[int]$plan.End.Value.TimeOfDay.TotalMinutes}
    if($endMinute -eq 0){$endMinute=1440}
    if($startMinute -ge $endMinute){throw '结束时间需晚于开始时间；全天生效请勾选“全天生效”。'}
    Save-WorkstationOptions $plan.Enabled.Checked ([int]$plan.Frequency.SelectedItem.Value) '' -AwayMinutes ([int]$plan.Away.SelectedItem.Value) -Schedule ([string]$plan.Schedule.SelectedItem.Value) -StartMinute $startMinute -EndMinute $endMinute -QuietConfirmSeconds ([int]$plan.Quiet.SelectedItem.Value) -ToastEnabled $Form.Tag.Toast.Checked -SettingsFile $Form.Tag.SettingsFile
    try{if(Get-Command Invoke-WorkstationWorker -ErrorAction SilentlyContinue){Invoke-WorkstationWorker -Restore -WorkerPath (Join-Path $Form.Tag.Root 'PowerProfile.ps1')}}
    catch{Write-ProfileEvent 'settings.restore.retry' '设置已保存，托盘下一轮检测将重试恢复检查' 'WARN' @{error=$_.Exception.Message}}
    $Form.Tag.LastSaveError='';$Form.Close()
}
function Show-ModernSettings {
    param([switch]$ReturnForm)
    $form=New-Object Windows.Forms.Form
    Initialize-ModernForm $form 'PowerProfile · 设置' 480 480
    $tabs=New-Object Windows.Forms.TabControl;$tabs.SetBounds(12,12,456,412)
    $general=New-Object Windows.Forms.TabPage;$general.Text='常用设置'
    $plan=New-Object Windows.Forms.TabPage;$plan.Text='省电计划'
    $smart=New-Object Windows.Forms.TabPage;$smart.Text='高级与规则'
    foreach($page in @($general,$plan,$smart)){$page.BackColor=$form.BackColor;$tabs.TabPages.Add($page)}
    $form.Controls.Add($tabs)
    $toast=New-Object Windows.Forms.CheckBox;$toast.Text='切换时显示简短提示';$toast.Checked=(Get-ModernUIOptions).toastEnabled;$toast.SetBounds(18,18,350,26);$general.Controls.Add($toast)
    $general.Controls.Add((New-ModernLabel '性能档位' 18 66 405))
    $advanced=New-Object Windows.Forms.Button;$advanced.Text='调整档位与检测参数…';$advanced.SetBounds(18,100,240,32);$general.Controls.Add($advanced)
    $advanced.Add_Click({Show-Settings})
    $general.Controls.Add((New-ModernLabel '集中调整三档频率、检测间隔和手动锁定。' 18 145 410))
    $general.Controls.Add((New-ModernLabel '附加省电的日期、时段与等待条件在“省电计划”。' 18 187 410))
    $general.Controls.Add((New-ModernLabel '插座连接、电价及用电记录在“电费与用电”。' 18 229 410))
    $general.Controls.Add((New-ModernLabel '关闭看板后，插座监测仍在托盘后台运行。' 18 271 410))
    $legacy=New-Object Windows.Forms.Button;$legacy.Text='切换为旧版';$legacy.SetBounds(18,280,180,32);$smart.Controls.Add($legacy)
    $legacy.Add_Click({Start-TrayVersionSwitch $ScriptDir 'Legacy'})
    $smart.Controls.Add((New-ModernLabel '旧版代码与配置独立保存，可随时返回。' 18 327 410))
    $w=Get-WorkstationOptions (Read-AtomicJson $SettingsPath)
    $enabled=New-Object Windows.Forms.CheckBox;$enabled.Text='启用工作时段附加省电';$enabled.Checked=$w.enabled;$enabled.SetBounds(18,15,370,26);$plan.Controls.Add($enabled)
    $plan.Controls.Add((New-ModernLabel '生效日期' 18 57 130))
    $schedule=New-WorkstationCombo $plan 165 55 253 @(@('ChineseWorkdays','国内法定工作日（含调休）'),@('Weekdays','周一至周五（不看调休）'),@('EveryDay','每天'),@('Weekends','周六、周日'),@('HolidayOnly','国内节假日休假安排')) $w.schedule
    $Script:DashboardTip.SetToolTip($schedule,'法定工作日和节假日需要本年度日历；每天、周一至周五及周末不依赖日历。')
    $plan.Controls.Add((New-ModernLabel '无输入后等待' 18 101 135))
    $awayChoices=@();foreach($minutes in @(1,5,10,15,20,30,45,60,90,120)){$awayChoices+=,@($minutes,"$minutes 分钟")}
    $away=New-WorkstationCombo $plan 230 99 188 $awayChoices $w.awayMinutes
    $plan.Controls.Add((New-ModernLabel '生效时段' 18 145 130))
    $allDay=New-Object Windows.Forms.CheckBox;$allDay.Text='全天生效';$allDay.Checked=($w.startMinute -eq 0 -and $w.endMinute -eq 1440);$allDay.SetBounds(165,141,253,26);$plan.Controls.Add($allDay)
    $plan.Controls.Add((New-ModernLabel '自定义时间' 18 179 130))
    $start=New-Object Windows.Forms.DateTimePicker;$start.Format='Custom';$start.CustomFormat='HH:mm';$start.ShowUpDown=$true;$start.Value=[DateTime]::Today.AddMinutes($w.startMinute);$start.SetBounds(165,177,113,27);$plan.Controls.Add($start)
    $plan.Controls.Add((New-ModernLabel '至' 282 179 26))
    $end=New-Object Windows.Forms.DateTimePicker;$end.Format='Custom';$end.CustomFormat='HH:mm';$end.ShowUpDown=$true;$end.Value=[DateTime]::Today.AddMinutes($w.endMinute);$end.SetBounds(309,177,109,27);$plan.Controls.Add($end)
    $Script:DashboardTip.SetToolTip($start,'点击小时或分钟直接输入，也可用上下箭头调整。')
    $Script:DashboardTip.SetToolTip($end,'直接输入小时和分钟；00:00 表示当天结束（24:00）。暂不支持跨午夜时段。')
    $plan.Controls.Add((New-ModernLabel 'CPU 上限' 18 221 130))
    $json=Read-AtomicJson $SettingsPath;$frequencyChoices=@()
    foreach($mhz in @(500,800,1000,1200,1400,1500,1600,1700,1800,1900,2000,2100,2200,2400,2600,2800,3000)){
        if($json.processorBaseMHz -gt 0 -and $mhz -lt $json.modes.Idle.freqMax -and [Math]::Floor(100*$mhz/$json.processorBaseMHz) -ge $json.modes.Idle.min+5){$frequencyChoices+=,@($mhz,"$mhz MHz")}
    }
    $frequency=New-WorkstationCombo $plan 230 219 188 $frequencyChoices $w.freqMax
    $plan.Controls.Add((New-ModernLabel '低负载持续确认' 18 263 160))
    $quiet=New-WorkstationCombo $plan 230 261 188 @(@(10,'至少 10 秒'),@(20,'至少 20 秒'),@(30,'至少 30 秒'),@(60,'至少 60 秒')) $w.quietConfirmSeconds
    $timeHint=New-ModernLabel '' 18 302 410;$timeHint.ForeColor=[Drawing.Color]::FromArgb(111,122,132);$plan.Controls.Add($timeHint)
    $y=330
    foreach($text in @('游戏、高负载和手动档位始终优先','保留 C-state 等稳定参数')){$plan.Controls.Add((New-ModernLabel $text 18 $y 410));$y+=26}
    $y=18
    foreach($text in @('运行规则 · 仅作说明','日常静音，确认游戏后进入游戏档','退出游戏：沿用原确认次数，回到静音','手动档位优先；均衡档仍可手动选择','附加省电：仅离开电脑且持续低负载时进入','游戏、应用负载或检查失败时阻止附加省电')){$smart.Controls.Add((New-ModernLabel $text 18 $y 410));$y+=34}
    $protection=New-ModernLabel '查看具体负载保护条件（悬停）' 18 228 410;$protection.ForeColor=[Drawing.Color]::FromArgb(91,107,118);$smart.Controls.Add($protection)
    $Script:DashboardTip.SetToolTip($protection,"游戏主体进程存在时阻止附加省电。`r`nCPU 总占用 ≥25%、单进程 ≥10%，或占满 ≥70% 一核算力时阻止。`r`n任一 GPU 引擎 ≥15% 时阻止；检查失败不进入，低负载需持续确认。`r`n保留 C-state 等稳定参数。")
    $saveStatus=New-ModernLabel '' 12 440 345;$saveStatus.Height=32;$saveStatus.ForeColor=[Drawing.Color]::FromArgb(174,63,66);$saveStatus.AutoEllipsis=$true;$form.Controls.Add($saveStatus)
    $form.Tag=@{Plan=@{Enabled=$enabled;Schedule=$schedule;Away=$away;AllDay=$allDay;Start=$start;End=$end;TimeHint=$timeHint;Frequency=$frequency;Quiet=$quiet};Toast=$toast;SettingsFile=[IO.Path]::GetFullPath($SettingsPath);Root=[IO.Path]::GetFullPath($ScriptDir);SaveStatus=$saveStatus;LastSaveError=''}
    $allDay.Add_CheckedChanged({param($sender,$eventArgs) Update-WorkstationTimeControls $sender.FindForm()})
    Update-WorkstationTimeControls $form
    $save=New-Object Windows.Forms.Button;$save.Text='保存';$save.SetBounds(368,440,100,30);$form.Controls.Add($save)
    $save.Add_Click({
        param($sender,$eventArgs)
        $settingsForm=$sender.FindForm()
        try {
            Save-ModernSettingsForm $settingsForm
        } catch {$settingsForm.Tag.LastSaveError=$_.Exception.Message;$settingsForm.Tag.SaveStatus.Text="未保存：$($_.Exception.Message)";$Script:DashboardTip.SetToolTip($settingsForm.Tag.SaveStatus,$_.Exception.Message);Write-ProfileEvent 'settings.save.failed' $_.Exception.Message 'ERROR' @{settingsPath=$settingsForm.Tag.SettingsFile;stack=$_.ScriptStackTrace;position=$_.InvocationInfo.PositionMessage}}
    })
    if($ReturnForm){return $form}
    [void]$form.ShowDialog();if($form.Icon){$form.Icon.Dispose()};$form.Dispose()
}
