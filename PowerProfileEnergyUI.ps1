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
    $Script:EnergyService=New-Object ProfileEnergyService $ScriptDir
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
    $f.today.Text=Format-EnergyAmount $state.TodayKWh 'kWh';$f.month.Text=Format-EnergyAmount $state.MonthKWh 'kWh';$f.fee.Text=Format-EnergyCost $state.MonthKWh $state.Price
    $f.price.Text=if($null -ne $state.Price){'{0:N3} 元 / 度' -f $state.Price}else{'待设置电价'}
    $f.dayFee.Text=Format-EnergyCost $state.TodayKWh $state.Price
    $f.hint.Text=if($state.Configured){$state.Status}else{'尚未连接 · 点击“连接与电价”设置插座'}
    $Script:DashboardTip.SetToolTip($f.hint,$state.Status)
    $f.coverage.Text=('已采集 {0:N0} 分钟 · 用电量与电费为采样估算' -f ($state.TodaySeconds/60))
    $f.updated.Text=if($state.ObservedAt -ne [DateTime]::MinValue){"采样 $($state.ObservedAt.ToLocalTime().ToString('HH:mm:ss')) · 每分钟更新"}else{'连接后开始累计，无接入前历史数据'}
    $f.switch.Enabled=$fresh -and $null -ne $state.On -and -not $state.Busy
    $f.switch.Text=if($state.On -eq $false){'开启插座'}else{'关闭插座'};$f.refresh.Enabled=$state.Configured -and -not $state.Busy
    $Script:EnergyDetails.Tag.Chart.Points=$state.Points;$Script:EnergyDetails.Tag.Chart.Invalidate()
    Update-EnergySummary
}
function Show-EnergyDetails {
    Initialize-EnergyService
    if($Script:EnergyDetails -and -not $Script:EnergyDetails.IsDisposed){$Script:EnergyDetails.Show();[ProfileVisual]::ActivateDashboard($Script:EnergyDetails.Handle);return}
    $form=New-Object Windows.Forms.Form;Initialize-ModernForm $form 'PowerProfile · 电脑用电' 500 660
    $fields=@{}
    $title=New-ModernLabel '电脑用电' 20 16 260;$title.Font=New-Object Drawing.Font 'Microsoft YaHei UI',14,([Drawing.FontStyle]::Bold);$title.Height=36;$form.Controls.Add($title)
    $fields.status=New-ModernLabel '未连接' 302 23 177;$fields.status.TextAlign='TopRight';$fields.status.ForeColor=[Drawing.Color]::FromArgb(36,124,112);$form.Controls.Add($fields.status)
    $form.Controls.Add((New-ModernLabel '米家智能插座 3 · 仅为电脑供电' 20 54 460))
    $card=New-Object Windows.Forms.Panel;$card.BackColor=[Drawing.Color]::White;$card.SetBounds(12,92,476,176);$form.Controls.Add($card)
    $card.Controls.Add((New-ModernLabel '电源输入功率' 16 10 210));$fields.watts=New-ModernLabel '-- W' 16 34 240;$fields.watts.Font=New-Object Drawing.Font 'Segoe UI',24,([Drawing.FontStyle]::Bold);$fields.watts.Height=47;$fields.watts.ForeColor=[Drawing.Color]::FromArgb(39,106,159);$card.Controls.Add($fields.watts)
    $meaning=New-ModernLabel '电脑 + 适配器 + 电池充电' 245 34 215;$meaning.ForeColor=[Drawing.Color]::FromArgb(111,122,132);$card.Controls.Add($meaning)
    foreach($row in @(@('今日估算用电','today',16),@('本月估算用电','month',170),@('本月估算电费','fee',324))){
        $caption=New-ModernLabel $row[0] $row[2] 101 144;$caption.ForeColor=[Drawing.Color]::FromArgb(111,122,132);$card.Controls.Add($caption)
        $value=New-ModernLabel '等待累计' $row[2] 131 144;$value.Font=New-Object Drawing.Font 'Segoe UI',12,([Drawing.FontStyle]::Bold);$card.Controls.Add($value);$fields[$row[1]]=$value
    }
    $curve=New-Object Windows.Forms.Panel;$curve.BackColor=[Drawing.Color]::White;$curve.SetBounds(12,280,476,188);$form.Controls.Add($curve)
    $curve.Controls.Add((New-ModernLabel '功率变化' 16 12 180));$chart=New-Object ProfileEnergyChart;$chart.Font=$Script:ModernFont;$chart.SetBounds(10,47,456,131);$curve.Controls.Add($chart)
    $hour=New-EnergyButton '近 1 小时' 287 9 91;$today=New-EnergyButton '今日' 385 9 74;$curve.Controls.Add($hour);$curve.Controls.Add($today)
    $hour.Add_Click({$Script:EnergyDetails.Tag.Chart.Today=$false;$Script:EnergyDetails.Tag.Chart.Invalidate()});$today.Add_Click({$Script:EnergyDetails.Tag.Chart.Today=$true;$Script:EnergyDetails.Tag.Chart.Invalidate()})
    $details=New-Object Windows.Forms.Panel;$details.BackColor=[Drawing.Color]::White;$details.SetBounds(12,480,476,120);$form.Controls.Add($details)
    $details.Controls.Add((New-ModernLabel '固定电价' 16 13 160));$fields.price=New-ModernLabel '' 200 13 257;$fields.price.TextAlign='TopRight';$details.Controls.Add($fields.price)
    $details.Controls.Add((New-ModernLabel '今日估算电费' 16 43 160));$fields.dayFee=New-ModernLabel '' 200 43 257;$fields.dayFee.TextAlign='TopRight';$details.Controls.Add($fields.dayFee)
    $fields.switch=New-EnergyButton '关闭插座' 350 79 109;$details.Controls.Add($fields.switch)
    $fields.switch.Add_Click({
        $state=$Script:EnergyService.GetSnapshot();if(-not $state.Configured -or $state.Busy -or $null -eq $state.On){return}
        $on=-not $state.On
        $message=if($on){'确认开启电脑插座？'}else{'确认关闭电脑插座？这会切断适配器供电，电脑将转为电池供电。不会触发自动休眠。请确认电池可用，避免远程连接中断。'}
        if([Windows.Forms.MessageBox]::Show($message,'插座控制','YesNo','Question','Button2') -eq 'Yes'){$Script:EnergyService.SetSwitch($on);Update-EnergyDetails}
    })
    $setup=New-EnergyButton '连接与电价' 16 79 128;$details.Controls.Add($setup);$setup.Add_Click({Show-EnergyConnection;Update-EnergyDetails})
    $fields.refresh=New-EnergyButton '刷新' 246 79 92;$details.Controls.Add($fields.refresh);$fields.refresh.Add_Click({$Script:EnergyService.Refresh();Update-EnergyDetails})
    $fields.coverage=New-ModernLabel '' 18 609 460;$fields.coverage.ForeColor=[Drawing.Color]::FromArgb(111,122,132);$form.Controls.Add($fields.coverage)
    $fields.updated=New-ModernLabel '' 18 635 280;$fields.updated.Font=New-Object Drawing.Font 'Microsoft YaHei UI',8;$form.Controls.Add($fields.updated)
    $fields.hint=New-ModernLabel '' 258 70 215;$fields.hint.AutoEllipsis=$true;$form.Controls.Add($fields.hint)
    $close=New-EnergyButton '关闭' 390 627 92;$form.Controls.Add($close);$close.Add_Click({$Script:EnergyDetails.Close()})
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=1000;$timer.Add_Tick({try{Update-EnergyDetails}catch{Write-ProfileEvent 'ui.energy.refresh.failed' $_.Exception.Message 'ERROR'}})
    $form.Tag=@{Fields=$fields;Chart=$chart;Timer=$timer};$Script:EnergyDetails=$form
    $form.Add_FormClosed({param($sender,$args) $sender.Tag.Timer.Stop();$sender.Tag.Timer.Dispose();if($sender.Icon){$sender.Icon.Dispose()};$Script:EnergyDetails=$null})
    Update-EnergyDetails;$timer.Start();$form.Show();[ProfileVisual]::ActivateDashboard($form.Handle)
}
