Add-Type -Path (Join-Path $ScriptDir 'PowerProfileUI.cs') -ReferencedAssemblies System.Drawing,System.Windows.Forms
. (Join-Path $ScriptDir 'PowerProfileVersion.ps1')
$Script:ModernFont=New-Object Drawing.Font 'Microsoft YaHei UI',9
$Script:Dashboard=$null
$Script:TelemetryProcess=$null

function Get-ModernUIOptions {
    $o=@{toastEnabled=$true}
    try { $j=Get-Content $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json; if($j.ui.toastEnabled -is [bool]){$o.toastEnabled=$j.ui.toastEnabled} } catch {}
    return $o
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
}
function Invoke-TelemetrySample {
    if($Script:TelemetryProcess -and -not $Script:TelemetryProcess.HasExited){return}
    $Script:TelemetryProcess=Start-HiddenPowerShell @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f (Join-Path $ScriptDir 'Read-SystemStatus.ps1')))
}
function Update-ModernDashboard {
    if(-not $Script:Dashboard -or $Script:Dashboard.IsDisposed){return}
    $fields=$Script:Dashboard.Tag.Fields
    $mode=Get-CurrentMode
    $fields.mode.Text="$(if($Script:Settings.modes.ContainsKey($mode)){$Script:Settings.modes[$mode].name}else{$mode}) · $(if(Get-AutoEnabled){'自动'}else{'手动锁定'})"
    $d=Read-GameDetectionState
    $fields.reason.Text=if($d.Fresh){$d.Reason}else{'检测结果暂不可用，保持原有控制逻辑'}
    $fields.idle.Text="$(Get-UserActivityIdleSeconds) 秒（含远程输入）"
    $fields.limit.Text=if($Script:Settings.modes.ContainsKey($mode)){Format-Freq $Script:Settings.modes[$mode].freqMax}else{'--'}
    $fields.plan.Text='附加省电未启用 · 频率与保护名单待确认'
    try {
        $j=Get-Content (Join-Path $ScriptDir 'system_status.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        $age=([DateTime]::UtcNow-([DateTime]$j.observedAt).ToUniversalTime()).TotalSeconds
        foreach($pair in @(@('cpu','cpu'),@('gpu','gpu3d'),@('video','videoEncode'),@('compute','compute'),@('memory','memoryPercent'))) {
            $v=$j.($pair[1]);$fields[$pair[0]].Text=if($age -le 20 -and $null -ne $v){"$v%"}else{'暂不可用'}
        }
        if($age -le 20 -and $null -ne $j.memoryUsedGB){$fields.memory.Text+="  ($($j.memoryUsedGB)/$($j.memoryTotalGB) GB)"}
        $fields.updated.Text=if($age -le 20){'实时采样 · 每 5 秒刷新'}else{'采样过期，等待下一次更新'}
    } catch { $fields.updated.Text='正在读取系统信息...' }
}
function Show-ModernDashboard {
    if($Script:Dashboard -and -not $Script:Dashboard.IsDisposed){$Script:Dashboard.Activate();return}
    $form=New-Object Windows.Forms.Form
    Initialize-ModernForm $form 'PowerProfile · 运行状态' 460 460
    $fields=@{}
    $fields.mode=New-ModernLabel '' 18 18 425
    $fields.mode.Font=New-Object Drawing.Font 'Microsoft YaHei UI',10,([Drawing.FontStyle]::Bold)
    $fields.reason=New-ModernLabel '' 18 48 425;$fields.reason.Height=42
    $form.Controls.Add($fields.mode);$form.Controls.Add($fields.reason)
    $y=98
    foreach($row in @(@('CPU 占用','cpu'),@('GPU 3D','gpu'),@('视频编码','video'),@('GPU 计算','compute'),@('内存','memory'),@('CPU 频率上限','limit'),@('无输入时长','idle'))) {
        $label=New-ModernLabel $row[0] 18 $y 130
        $value=New-ModernLabel '--' 148 $y 294;$value.TextAlign='TopRight'
        $form.Controls.Add($label);$form.Controls.Add($value);$fields[$row[1]]=$value;$y+=32
    }
    $fields.plan=New-ModernLabel '' 18 332 425;$form.Controls.Add($fields.plan)
    $stable=New-ModernLabel '稳定参数沿用原配置 · 不修改 C-state' 18 362 425
    $stable.ForeColor=[Drawing.Color]::FromArgb(36,124,112);$form.Controls.Add($stable)
    $fields.updated=New-ModernLabel '' 18 414 280;$form.Controls.Add($fields.updated)
    $close=New-Object Windows.Forms.Button;$close.Text='关闭';$close.SetBounds(356,404,85,30);$form.Controls.Add($close)
    $close.Add_Click({$Script:Dashboard.Close()})
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=5000
    $timer.Add_Tick({Invoke-TelemetrySample;Update-ModernDashboard})
    $form.Tag=@{Fields=$fields;Timer=$timer}
    $form.Add_FormClosed({
        param($sender,$eventArgs)
        $sender.Tag.Timer.Stop();$sender.Tag.Timer.Dispose()
        if($sender.Icon){$sender.Icon.Dispose()}
        $Script:Dashboard=$null
    })
    $Script:Dashboard=$form;Invoke-TelemetrySample;Update-ModernDashboard
    $timer.Start();$form.Show()
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
    $y=18
    foreach($text in @('附加省电：未启用，等待参数确认','日历：国内法定工作日（含调休）','北京时间：10:00–18:00','本机离开：20 分钟','18:00 撤销附加参数，不覆盖游戏或手动档位','不改变睡眠、C-state 或画面输出')) {
        $plan.Controls.Add((New-ModernLabel $text 18 $y 410));$y+=38
    }
    $y=18
    foreach($text in @('待启用规则：','游戏主体进程存在时，禁止附加省电','保护软件只要打开，就禁止附加省电','其他高负载任务出现时，撤销附加省电','检测数据不可信时，保留原参数','保护软件名单与阈值仍待确认')) {
        $protect.Controls.Add((New-ModernLabel $text 18 $y 410));$y+=38
    }
    $save=New-Object Windows.Forms.Button;$save.Text='保存';$save.SetBounds(368,350,100,30);$form.Controls.Add($save)
    $save.Add_Click({
        try {
            $json=if(Test-Path $SettingsPath){Get-Content $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json}else{[PSCustomObject]@{}}
            $ui=if($json.ui){$json.ui}else{[PSCustomObject]@{}}
            $ui | Add-Member -NotePropertyName toastEnabled -NotePropertyValue $toast.Checked -Force
            $json | Add-Member -NotePropertyName ui -NotePropertyValue $ui -Force
            Write-AtomicJson $SettingsPath $json -Pretty
            $form.Close()
        } catch {[void][Windows.Forms.MessageBox]::Show("保存失败: $_")}
    }.GetNewClosure())
    if($ReturnForm){return $form}
    [void]$form.ShowDialog();if($form.Icon){$form.Icon.Dispose()};$form.Dispose()
}
