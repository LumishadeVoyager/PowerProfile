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
    if($Script:TelemetryProcess -and -not $Script:TelemetryProcess.HasExited){
        if(([DateTime]::UtcNow-$Script:TelemetryStarted).TotalSeconds -lt 15){return}
        $Script:TelemetryProcess.Kill()
        Write-ProfileEvent 'telemetry.timeout' '只读采样超过 15 秒，已终止并重新采样' 'WARN'
    }
    if($Script:TelemetryProcess -and $Script:TelemetryProcess.HasExited -and $Script:TelemetryProcess.ExitCode -ne 0){Write-ProfileEvent 'telemetry.failed' '只读采样进程失败，将重试；请按关联操作查阅具体异常' 'WARN' @{exitCode=$Script:TelemetryProcess.ExitCode;childOperationId=$Script:TelemetryOperationId}}
    if($Script:TelemetryProcess){$Script:TelemetryProcess.Dispose()}
    $Script:TelemetryStarted=[DateTime]::UtcNow
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
    $fields.limit.Text=if($Script:Settings.modes.ContainsKey($mode)){Format-Freq $Script:Settings.modes[$mode].freqMax}else{'--'}
    $fields.plan.Text='附加省电：等待检测'
    try{
        $ws=Read-AtomicJson (Join-Path $ScriptDir 'workstation_state.json')
        $age=([DateTime]::UtcNow-([DateTime]$ws.observedAt).ToUniversalTime()).TotalSeconds
        $fields.plan.Text=if($age -gt 45){'附加省电：检测过期，等待恢复检查'}else{"附加省电：$(if($ws.active){'已生效'}else{'未生效'}) · $($ws.reason)"}
        if($ws.active){$fields.limit.Text="$($ws.freqMax) MHz（附加限制）"}
    }catch{}
    $Script:DashboardTip.SetToolTip($fields.plan,$fields.plan.Text)
    $j=$null
    try {
        $j=Read-AtomicJson (Join-Path $ScriptDir 'system_status.json')
        $age=([DateTime]::UtcNow-([DateTime]$j.observedAt).ToUniversalTime()).TotalSeconds
    } catch {$age=999999}
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
    if($null -ne $j.memoryUsedGB -and $age -le 60){$fields.memory.Text+=" · $($j.memoryUsedGB) GB";$Script:DashboardTip.SetToolTip($fields.memory,"已用 $($j.memoryUsedGB) GB / 总计 $($j.memoryTotalGB) GB")}
    $fields.updated.Text=if($age -le 15){"更新 $(([DateTime]$j.observedAt).ToLocalTime().ToString('HH:mm:ss'))$(if($j.stage -eq 'gpu-loading'){' · GPU 刷新中'}elseif($degraded){' · 部分指标有说明'})"}else{'采样延迟 · 正在自动重试'}
}
function Show-ModernDashboard {
    if($Script:Dashboard -and -not $Script:Dashboard.IsDisposed){$Script:Dashboard.WindowState='Normal';$Script:Dashboard.Show();[ProfileVisual]::ActivateDashboard($Script:Dashboard.Handle);$Script:Dashboard.Activate();return}
    $form=New-Object Windows.Forms.Form
    Initialize-ModernForm $form 'PowerProfile · 运行状态' 480 524
    $form.ShowInTaskbar=$true
    $fields=@{};$bars=@{}
    $accent=New-Object Windows.Forms.Panel;$accent.BackColor=[Drawing.Color]::FromArgb(39,106,159);$accent.SetBounds(18,20,4,49);$form.Controls.Add($accent)
    $fields.mode=New-ModernLabel '' 34 17 425
    $fields.mode.Height=32;$fields.mode.Font=New-Object Drawing.Font 'Microsoft YaHei UI',14,([Drawing.FontStyle]::Bold)
    $subtitle=New-ModernLabel '运行状态 · 按需系统监测' 34 51 410;$subtitle.ForeColor=[Drawing.Color]::FromArgb(111,122,132)
    $fields.reason=New-ModernLabel '' 18 82 443;$fields.reason.AutoEllipsis=$true
    $form.Controls.Add($fields.mode);$form.Controls.Add($subtitle);$form.Controls.Add($fields.reason)
    $card=New-Object Windows.Forms.Panel;$card.BackColor=[Drawing.Color]::White;$card.SetBounds(12,116,456,195);$form.Controls.Add($card)
    $y=12
    foreach($row in @(@('CPU','cpu'),@('GPU 3D','gpu'),@('视频编码','video'),@('GPU 计算','compute'),@('内存','memory'))){
        $caption=New-ModernLabel $row[0] 14 $y 87;$caption.ForeColor=[Drawing.Color]::FromArgb(91,107,118)
        $bar=New-Object ProfileMetricBar;$bar.SetBounds(107,($y+5),185,10);$bar.ForeColor=[Drawing.Color]::FromArgb(39,106,159)
        $value=New-ModernLabel '--' 299 $y 141;$value.TextAlign='TopRight'
        $card.Controls.Add($caption);$card.Controls.Add($bar);$card.Controls.Add($value)
        $fields[$row[1]]=$value;$bars[$row[1]]=$bar;$y+=36
    }
    $details=New-Object Windows.Forms.Panel;$details.BackColor=[Drawing.Color]::White;$details.SetBounds(12,325,456,151);$form.Controls.Add($details)
    foreach($row in @(@('CPU 频率上限','limit',13),@('无输入时长','idle',47))){
        $caption=New-ModernLabel $row[0] 14 $row[2] 120;$caption.ForeColor=[Drawing.Color]::FromArgb(91,107,118)
        $value=New-ModernLabel '--' 135 $row[2] 305;$value.TextAlign='TopRight'
        $details.Controls.Add($caption);$details.Controls.Add($value);$fields[$row[1]]=$value
    }
    $fields.plan=New-ModernLabel '' 14 83 428;$fields.plan.Height=38;$fields.plan.AutoEllipsis=$true;$details.Controls.Add($fields.plan)
    $stable=New-ModernLabel '稳定参数保留 · C-state 不作更改' 14 124 428;$stable.ForeColor=[Drawing.Color]::FromArgb(36,124,112);$details.Controls.Add($stable)
    $fields.updated=New-ModernLabel '' 18 492 273;$fields.updated.ForeColor=[Drawing.Color]::FromArgb(111,122,132);$form.Controls.Add($fields.updated)
    $log=New-Object Windows.Forms.Button;$log.Text='查看日志';$log.SetBounds(292,485,82,29);$log.FlatStyle='Flat';$log.FlatAppearance.BorderColor=[Drawing.Color]::FromArgb(217,225,231);$form.Controls.Add($log);$log.Add_Click({Show-ModernLogViewer})
    $close=New-Object Windows.Forms.Button;$close.Text='关闭';$close.SetBounds(384,485,78,29);$close.FlatStyle='Flat';$close.FlatAppearance.BorderColor=[Drawing.Color]::FromArgb(217,225,231);$form.Controls.Add($close)
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
    $general.Controls.Add((New-ModernLabel '关闭状态窗口后，系统采样停止。' 18 90 405))
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
