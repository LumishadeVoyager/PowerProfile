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

function Get-ModernUIOptions {
    $o=@{toastEnabled=$true}
    try { $j=Read-AtomicJson $SettingsPath; if($j.ui.toastEnabled -is [bool]){$o.toastEnabled=$j.ui.toastEnabled} } catch {}
    return $o
}
function Save-WorkstationOptions {
    param([bool]$Enabled,[int]$Frequency,[string]$PausedUntil='')
    $json=Read-AtomicJson $SettingsPath
    $minimum=[int]$json.modes.Idle.min
    $base=[int]$json.processorBaseMHz
    if($Enabled -and ($base -le 0 -or $Frequency -lt 500 -or $Frequency -ge $json.modes.Idle.freqMax -or [Math]::Floor(100*$Frequency/$base) -lt $minimum+5)){throw '频率必须低于静音档，且保持原最低处理器比例；请先校准基频。'}
    $w=if($json.workstation){$json.workstation}else{[PSCustomObject]@{}}
    foreach($pair in @(@('enabled',$Enabled),@('freqMax',$Frequency),@('awayMinutes',20),@('pausedUntil',$PausedUntil))){$w | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] -Force}
    $json | Add-Member -NotePropertyName workstation -NotePropertyValue $w -Force
    Write-AtomicJson $SettingsPath $json -Pretty
    $Script:ProfileSettingsHash=Get-ProfileFileHash $SettingsPath
    Write-ProfileEvent 'settings.workstation.saved' '保存附加省电配置' -Data @{enabled=$Enabled;freqMax=$Frequency;awayMinutes=20;pausedUntil=$PausedUntil}
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
function Initialize-ModernForm {
    param($Form,[string]$Title,[int]$Width,[int]$Height)
    $Form.Text=$Title;$Form.Font=$Script:ModernFont
    $Form.ClientSize=New-Object Drawing.Size $Width,$Height
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
    Initialize-ModernForm $form 'PowerProfile · 运行状态' 500 740
    $form.ShowInTaskbar=$true
    $fields=@{};$bars=@{}
    $accent=New-Object Windows.Forms.Panel;$accent.BackColor=[Drawing.Color]::FromArgb(39,106,159);$accent.SetBounds(18,20,4,49);$form.Controls.Add($accent)
    $fields.mode=New-ModernLabel '' 34 17 425
    $fields.mode.Height=32;$fields.mode.Font=New-Object Drawing.Font 'Microsoft YaHei UI',14,([Drawing.FontStyle]::Bold)
    $subtitle=New-ModernLabel '运行状态 · 按需系统监测' 34 51 445;$subtitle.ForeColor=[Drawing.Color]::FromArgb(111,122,132);$subtitle.AutoEllipsis=$true;$fields.hardware=$subtitle
    $fields.reason=New-ModernLabel '' 18 82 443;$fields.reason.AutoEllipsis=$true
    $form.Controls.Add($fields.mode);$form.Controls.Add($subtitle);$form.Controls.Add($fields.reason)
    $card=New-Object Windows.Forms.Panel;$card.BackColor=[Drawing.Color]::White;$card.SetBounds(12,116,476,235);$form.Controls.Add($card)
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
    $energy=New-Object Windows.Forms.Panel;$energy.BackColor=[Drawing.Color]::White;$energy.SetBounds(12,365,476,124);$form.Controls.Add($energy)
    $energy.Controls.Add((New-ModernLabel '电脑用电' 14 11 170))
    $fields.energyStatus=New-ModernLabel '未连接' 250 11 210;$fields.energyStatus.TextAlign='TopRight';$fields.energyStatus.ForeColor=[Drawing.Color]::FromArgb(36,124,112);$energy.Controls.Add($fields.energyStatus)
    foreach($row in @(@('当前功率','watts',14),@('今日估算用电','energyToday',167),@('今日估算电费','energyFee',320))){
        $caption=New-ModernLabel $row[0] $row[2] 43 143;$caption.ForeColor=[Drawing.Color]::FromArgb(111,122,132);$energy.Controls.Add($caption)
        $value=New-ModernLabel '--' $row[2] 68 143;$value.Font=New-Object Drawing.Font 'Microsoft YaHei UI',11,([Drawing.FontStyle]::Bold);$energy.Controls.Add($value);$fields[$row[1]]=$value
    }
    $source=New-ModernLabel '米家智能插座 3 · 连接后实际采样' 14 99 280;$source.ForeColor=[Drawing.Color]::FromArgb(111,122,132);$source.Font=New-Object Drawing.Font 'Microsoft YaHei UI',8;$energy.Controls.Add($source)
    $energyLink=New-Object Windows.Forms.LinkLabel;$energyLink.Text='用电详情 →';$energyLink.Font=$Script:ModernFont;$energyLink.SetBounds(352,97,110,25);$energyLink.LinkColor=[Drawing.Color]::FromArgb(39,106,159);$energy.Controls.Add($energyLink);$energyLink.Add_LinkClicked({try{Show-EnergyDetails}catch{Write-ProfileEvent 'ui.energy.open.failed' $_.Exception.GetBaseException().Message 'ERROR';[void][Windows.Forms.MessageBox]::Show('用电详情暂时无法打开，请查看日志。','PowerProfile')}})
    $details=New-Object Windows.Forms.Panel;$details.BackColor=[Drawing.Color]::White;$details.SetBounds(12,501,476,193);$form.Controls.Add($details)
    foreach($row in @(@('配置频率上限','limit',13),@('键鼠未输入','idle',41),@('供电状态','power',69),@('连续运行','uptime',97))){
        $caption=New-ModernLabel $row[0] 14 $row[2] 120;$caption.ForeColor=[Drawing.Color]::FromArgb(91,107,118)
        $value=New-ModernLabel '--' 135 $row[2] 325;$value.TextAlign='TopRight'
        $details.Controls.Add($caption);$details.Controls.Add($value);$fields[$row[1]]=$value
    }
    $fields.plan=New-ModernLabel '' 14 125 448;$fields.plan.Height=35;$fields.plan.AutoEllipsis=$true;$details.Controls.Add($fields.plan)
    $stable=New-ModernLabel '稳定参数保留 · C-state 不作更改' 14 163 448;$stable.ForeColor=[Drawing.Color]::FromArgb(36,124,112);$details.Controls.Add($stable)
    $fields.updated=New-ModernLabel '' 18 712 273;$fields.updated.ForeColor=[Drawing.Color]::FromArgb(111,122,132);$form.Controls.Add($fields.updated)
    $log=New-Object Windows.Forms.Button;$log.Text='查看日志';$log.SetBounds(312,704,82,29);$log.FlatStyle='Flat';$log.FlatAppearance.BorderColor=[Drawing.Color]::FromArgb(217,225,231);$form.Controls.Add($log);$log.Add_Click({Show-ModernLogViewer})
    $close=New-Object Windows.Forms.Button;$close.Text='关闭';$close.SetBounds(404,704,78,29);$close.FlatStyle='Flat';$close.FlatAppearance.BorderColor=[Drawing.Color]::FromArgb(217,225,231);$form.Controls.Add($close)
    $close.Add_Click({$Script:Dashboard.Close()})
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=5000
    $timer.Add_Tick({try{Invoke-TelemetrySample;Update-ModernDashboard}catch{Write-ProfileEvent 'ui.dashboard.refresh.failed' $_.Exception.Message 'ERROR' @{stack=$_.ScriptStackTrace}}})
    $form.Tag=@{Fields=$fields;Bars=$bars;Timer=$timer}
    $form.Add_FormClosed({
        param($sender,$eventArgs)
        $sender.Tag.Timer.Stop();$sender.Tag.Timer.Dispose()
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

function Show-ModernSettings {
    param([switch]$ReturnForm)
    $form=New-Object Windows.Forms.Form
    Initialize-ModernForm $form 'PowerProfile · 设置' 480 395
    $tabs=New-Object Windows.Forms.TabControl;$tabs.SetBounds(12,12,456,326)
    $general=New-Object Windows.Forms.TabPage;$general.Text='常规'
    $plan=New-Object Windows.Forms.TabPage;$plan.Text='省电计划'
    $protect=New-Object Windows.Forms.TabPage;$protect.Text='应用保护'
    foreach($page in @($general,$plan,$protect)){$page.BackColor=$form.BackColor;$tabs.TabPages.Add($page)}
    $form.Controls.Add($tabs)
    $toast=New-Object Windows.Forms.CheckBox;$toast.Text='切换时显示简短提示';$toast.Checked=(Get-ModernUIOptions).toastEnabled;$toast.SetBounds(18,18,350,26);$general.Controls.Add($toast)
    $general.Controls.Add((New-ModernLabel '托盘左键：运行状态；右键：快捷菜单' 18 58 405))
    $general.Controls.Add((New-ModernLabel '关闭窗口停止 CPU/GPU 采样；已连接插座继续累计。' 18 90 405))
    $advanced=New-Object Windows.Forms.Button;$advanced.Text='档位与自动检测设置...';$advanced.SetBounds(18,132,240,32);$general.Controls.Add($advanced)
    $advanced.Add_Click({Show-Settings})
    $legacy=New-Object Windows.Forms.Button;$legacy.Text='切换为旧版';$legacy.SetBounds(18,181,180,32);$general.Controls.Add($legacy)
    $legacy.Add_Click({Start-TrayVersionSwitch $ScriptDir 'Legacy'})
    $general.Controls.Add((New-ModernLabel '旧版代码与上线前配置独立保存，可随时返回。' 18 232 410))
    $w=Get-WorkstationOptions (Read-AtomicJson $SettingsPath)
    $enabled=New-Object Windows.Forms.CheckBox;$enabled.Text='启用工作时段附加省电';$enabled.Checked=$w.enabled;$enabled.SetBounds(18,15,370,26);$plan.Controls.Add($enabled)
    $plan.Controls.Add((New-ModernLabel 'CPU 上限（MHz）' 18 55 180))
    $frequency=New-Object Windows.Forms.NumericUpDown;$frequency.Minimum=500;$frequency.Maximum=10000;$frequency.Increment=100;$frequency.Value=$w.freqMax;$frequency.SetBounds(230,55,140,26);$plan.Controls.Add($frequency)
    $y=98
    foreach($text in @('国内法定工作日（含调休） · 10:00–18:00','本机或远程输入后，重新等待 20 分钟','18:00 撤销附加参数，游戏及手动档位优先','只修改交流电 CPU 上限；保留稳定参数','频率过低或本年度日历缺失时不生效')) {
        $plan.Controls.Add((New-ModernLabel $text 18 $y 410));$y+=38
    }
    $y=18
    foreach($text in @('游戏主体进程存在时，禁止附加省电','暂不添加剪辑、建模软件进程名单','CPU 总占用 ≥25% 或单进程 ≥10% 阻止','单进程占用 ≥70% 的一核算力也阻止','任一 GPU 引擎 ≥15% 时阻止','检查失败不进入；低负载需连续两次确认')) {
        $protect.Controls.Add((New-ModernLabel $text 18 $y 410));$y+=38
    }
    $save=New-Object Windows.Forms.Button;$save.Text='保存';$save.SetBounds(368,350,100,30);$form.Controls.Add($save)
    $save.Add_Click({
        try {
            $json=if(Test-Path $SettingsPath){Read-AtomicJson $SettingsPath}else{[PSCustomObject]@{}}
            $ui=if($json.ui){$json.ui}else{[PSCustomObject]@{}}
            $ui | Add-Member -NotePropertyName toastEnabled -NotePropertyValue $toast.Checked -Force
            $json | Add-Member -NotePropertyName ui -NotePropertyValue $ui -Force
            Write-AtomicJson $SettingsPath $json -Pretty
            Save-WorkstationOptions $enabled.Checked ([int]$frequency.Value) ''
            if(Get-Command Invoke-WorkstationWorker -ErrorAction SilentlyContinue){Invoke-WorkstationWorker -Restore}
            $form.Close()
        } catch {[void][Windows.Forms.MessageBox]::Show("保存失败: $_")}
    }.GetNewClosure())
    if($ReturnForm){return $form}
    [void]$form.ShowDialog();if($form.Icon){$form.Icon.Dispose()};$form.Dispose()
}
