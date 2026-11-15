. (Join-Path $PSScriptRoot 'PowerProfileCState.ps1')
. (Join-Path $PSScriptRoot 'PowerProfileUpdate.ps1')
function Get-ProfileUserRoot {if($SettingsPath){return Split-Path -Parent $SettingsPath};return $ScriptDir}
function Start-ProfileUpdateCheck([switch]$Manual){
    if($Script:UpdateCheckProcess -and -not $Script:UpdateCheckProcess.HasExited){return}
    $launchArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f (Join-Path $ScriptDir 'Check-PowerProfileUpdate.ps1')))
    if($Manual){$launchArgs+='-Manual'}
    $Script:UpdateCheckProcess=Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList $launchArgs
    if(-not $Script:UpdateNoticeTimer){
        $Script:UpdateNoticeTimer=New-Object Windows.Forms.Timer;$Script:UpdateNoticeTimer.Interval=2000
        $Script:UpdateNoticeTimer.Add_Tick({
            if($Script:UpdateCheckProcess -and $Script:UpdateCheckProcess.HasExited){
                $Script:UpdateNoticeTimer.Stop()
                try{$s=Read-ProfileUpdateState (Join-Path $ScriptDir '.updates\status.json');if($s.phase -eq 'ready' -and $Script:UpdateNotifiedVersion -ne $s.version -and $notify){$notify.ShowBalloonTip(8000,'PowerProfile 更新已就绪',$s.message,[Windows.Forms.ToolTipIcon]::Info);$Script:UpdateNotifiedVersion=$s.version}}catch{}
            }
        })
    }
    $Script:UpdateNoticeTimer.Start()
}
function Show-CStateProtection([switch]$ReturnForm){
    $root=Get-ProfileUserRoot;$options=Get-CStateOptions $root
    $form=New-Object Windows.Forms.Form;Initialize-ModernForm $form 'PowerProfile · C-state 稳定性保护' 560 400
    $title=New-ModernLabel '仅在确认 CPU 空闲切换导致不稳定时使用' 20 18 520;$title.Font=New-Object Drawing.Font 'Microsoft YaHei UI',11,([Drawing.FontStyle]::Bold);$form.Controls.Add($title)
    $body=New-ModernLabel "此保护开启后，将禁用当前电源计划的 CPU 空闲状态（AC/DC）。`r`n它不是性能增强开关；可能增加待机功耗、温度、风扇噪声和耗电。`r`n正常电脑建议保持关闭，沿用 Windows / 固件已有的 C-state 设置。`r`n关闭保护会恢复启用前记录的值；不会修改 BIOS。" 20 64 520;$body.Height=100;$form.Controls.Add($body)
    $current=New-ModernLabel '' 20 172 520
    try{$power=Read-CStatePower;$current.Text="系统读回：交流电空闲禁用=$($power.ac)，电池空闲禁用=$($power.dc)（1=禁用）"}catch{$current.Text=$_.Exception.Message};$form.Controls.Add($current)
    $enable=New-Object Windows.Forms.CheckBox;$enable.Text='启用 C-state 稳定性保护（禁用 CPU 空闲状态）';$enable.Checked=[bool]$options.enabled;$enable.SetBounds(20,214,520,28);$form.Controls.Add($enable)
    $ack=New-Object Windows.Forms.CheckBox;$ack.Text='我理解此选项的作用及功耗影响，并确认需要启用';$ack.SetBounds(20,251,520,28);$form.Controls.Add($ack)
    $status=New-ModernLabel '' 20 290 520;$status.Height=52;$status.ForeColor=[Drawing.Color]::Firebrick;$form.Controls.Add($status)
    $save=New-EnergyButton '应用' 430 350 110;$save.Enabled=-not $enable.Checked;$form.Controls.Add($save)
    $form.Tag=@{Root=$root;Enable=$enable;Ack=$ack;Save=$save;Status=$status;WasEnabled=[bool]$options.enabled}
    $change={param($sender,$eventArgs) $t=$sender.FindForm().Tag;$t.Save.Enabled=(-not $t.Enable.Checked -or $t.Ack.Checked)}
    $enable.Add_CheckedChanged($change);$ack.Add_CheckedChanged($change)
    $save.Add_Click({param($sender,$eventArgs) $f=$sender.FindForm();try{Set-CStateProtection $f.Tag.Root $f.Tag.Enable.Checked $f.Tag.Ack.Checked;$f.Close()}catch{$f.Tag.Status.Text=$_.Exception.Message}})
    if($ReturnForm){return $form};[void]$form.ShowDialog();$form.Icon.Dispose();$form.Dispose()
}
function Show-ProfileWelcome([switch]$ReturnForm){
    $root=Get-ProfileUserRoot;$form=New-Object Windows.Forms.Form;Initialize-ModernForm $form 'PowerProfile · 使用指南与更新' 660 570
    $tabs=New-Object Windows.Forms.TabControl;$tabs.SetBounds(14,14,632,492);$form.Controls.Add($tabs)
    $guide=New-Object Windows.Forms.TabPage;$guide.Text='开始使用';$updates=New-Object Windows.Forms.TabPage;$updates.Text='版本与更新'
    foreach($page in @($guide,$updates)){$page.BackColor=$form.BackColor;$tabs.TabPages.Add($page)}
    $intro=New-ModernLabel "先使用电源档位，再按需连接米家。没有插座也能正常使用。`r`n自动模式以游戏识别为准；手动档位优先。频率需按自己电脑调整。" 18 18 580;$intro.Height=55;$guide.Controls.Add($intro)
    $steps=@(
        @('1 · 检查性能档位','从保守配置开始；无需套用开发者电脑参数。','档位设置',{Show-Settings}),
        @('2 · 连接米家插座','电脑与插座同一局域网；准备 IP、32 位 Token 和电价。','插座与电价',{Show-EnergyConnection}),
        @('3 · 补录米家历史（可选）','先装 Python 3.10+ 并运行 Install-EnergyHistory.ps1，再扫码。','米家历史',{Show-CloudHistory}),
        @('4 · 其他设备与定时任务（可选）','云端登录后选择设备；保持状态需要电脑在线、唤醒。','设备中枢',{Show-DeviceHub})
    )
    $y=83
    foreach($step in $steps){
        $guide.Controls.Add((New-ModernLabel $step[0] 18 $y 420));$note=New-ModernLabel $step[1] 18 ($y+28) 435;$note.Height=40;$note.ForeColor=[Drawing.Color]::DimGray;$guide.Controls.Add($note)
        $b=New-EnergyButton $step[2] 462 ($y+10) 130;$b.Add_Click($step[3]);$guide.Controls.Add($b);$y+=82
    }
    $manual=New-EnergyButton '完整使用手册' 18 418 150;$manual.Add_Click({Start-Process (Join-Path $ScriptDir 'USER_GUIDE.md')});$guide.Controls.Add($manual)
    $safety=New-EnergyButton 'C-state 稳定性保护…' 188 418 218;$safety.Add_Click({Show-CStateProtection});$guide.Controls.Add($safety)
    $version=Get-ProfileVersionInfo $ScriptDir
    $updates.Controls.Add((New-ModernLabel "当前版本 v$($version.version) · $($version.distribution)" 18 22 580))
    $auto=New-Object Windows.Forms.CheckBox;$auto.Text='自动检查并下载稳定版更新（每 24 小时）';$auto.Checked=[bool](Get-ProfileUpdateOptions $root).enabled;$auto.SetBounds(18,70,580,28);$updates.Controls.Add($auto)
    $info=New-ModernLabel "更新下载并校验后，等下次启动托盘安装；不会在游戏中强制重启。`r`n保留配置、Token、设备任务和历史记录；失败时恢复程序备份。`r`n源码 / Git 工作目录默认不自动更新，也不会被 OTA 覆盖。`r`n私有仓库需获授权，并安装 GitHub CLI 后执行 gh auth login。" 18 119 580;$info.Height=115;$updates.Controls.Add($info)
    $status=New-ModernLabel '尚未检查更新' 18 253 580;$status.Height=75;$updates.Controls.Add($status)
    $check=New-EnergyButton '立即检查' 18 354 130;$check.Add_Click({Start-ProfileUpdateCheck -Manual});$updates.Controls.Add($check)
    $page=New-EnergyButton '查看 Release' 166 354 145;$page.Add_Click({Start-Process 'https://github.com/LumishadeVoyager/PowerProfile/releases/latest'});$updates.Controls.Add($page)
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=1500
    $form.Tag=@{Root=$root;Enable=$auto;Status=$status;Timer=$timer}
    $timer.Tag=$form;$timer.Add_Tick({param($sender,$eventArgs) try{$f=$sender.Tag;$s=Read-ProfileUpdateState (Join-Path $f.Tag.Root '.updates\status.json');if($s){$f.Tag.Status.Text=$s.message}}catch{$sender.Tag.Tag.Status.Text='更新状态暂不可读，请重新检查。'}});$timer.Start()
    $auto.Add_CheckedChanged({param($sender,$eventArgs) Write-AtomicJson (Join-Path $sender.FindForm().Tag.Root 'updates.settings.json') @{enabled=$sender.Checked}})
    $done=New-EnergyButton '完成' 524 522 122;$done.Add_Click({param($sender,$eventArgs) Write-AtomicJson (Join-Path $sender.FindForm().Tag.Root 'onboarding.json') @{completed=$true};$sender.FindForm().Close()});$form.Controls.Add($done)
    $form.Add_FormClosed({param($sender,$eventArgs) $sender.Tag.Timer.Stop();$sender.Tag.Timer.Dispose()})
    if($ReturnForm){return $form};[void]$form.ShowDialog();$form.Icon.Dispose();$form.Dispose()
}
function Initialize-ProfileDistribution {
    Confirm-ProfileUpdate $ScriptDir
    $Script:DistributionTimer=New-Object Windows.Forms.Timer;$Script:DistributionTimer.Interval=5000
    $Script:DistributionTimer.Add_Tick({
        $Script:DistributionTimer.Interval=3600000
        try {
            $root=Get-ProfileUserRoot
            if((Get-ProfileUpdateOptions $root).enabled){Start-ProfileUpdateCheck}
            if(-not $Script:WelcomeOffered){
                $Script:WelcomeOffered=$true
                if((Get-ProfileVersionInfo $ScriptDir).distribution -eq 'release' -and -not (Test-Path (Join-Path $root 'onboarding.json'))){Show-ProfileWelcome}
            }
        } catch {Write-ProfileEvent 'distribution.start.failed' $_.Exception.Message 'WARN'}
    });$Script:DistributionTimer.Start()
}
