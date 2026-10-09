$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'PowerProfileVersion.ps1')
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
function Assert-Equal($Name,$Actual,$Expected){if($Actual -ne $Expected){throw "$Name expected $Expected got $Actual"};Write-Host "PASS $Name"}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('PowerProfileUITests-'+[Guid]::NewGuid())
[void](New-Item -ItemType Directory $testRoot)
try {
    Assert-Equal 'new installs select modern' (Get-SelectedTrayVersion $testRoot) 'Modern'
    'Legacy' | Set-Content (Join-Path $testRoot 'tray_version.txt')
    Assert-Equal 'legacy selection survives restart' (Get-SelectedTrayVersion $testRoot) 'Legacy'
    'corrupt' | Set-Content (Join-Path $testRoot 'tray_version.txt')
    Assert-Equal 'invalid selector fails to known version' (Get-SelectedTrayVersion $testRoot) 'Modern'
    Assert-Equal 'legacy path is independent' (Get-TrayVersionPath $project Legacy) (Join-Path $project 'legacy\PowerProfileTray.ps1')
    $legacyHashes=@{'PowerProfile.ps1'='EB027A874BB108818278CF186398C7E6D2C359FD3E53E2B8667B0891EF30A2CC';'PowerProfileLogic.ps1'='CB77219C7FBC41807DB823D9DFD237D1FFBC73C73E0531C4891FB8260D8FBE0F';'PowerProfileDetection.ps1'='764BE1BDAFD2064189EAD87FC3ED11C1D124A8EF48C44B45D7759024F261219D'}
    foreach($file in $legacyHashes.Keys) {
        Assert-Equal "legacy core preserved: $file" (Get-FileHash (Join-Path $project ('legacy\'+$file))).Hash $legacyHashes[$file]
    }
    $ScriptDir=$project;$SettingsPath=Join-Path $testRoot 'settings.json'
    Copy-Item (Join-Path $project 'settings.example.json') $SettingsPath
    $Script:Settings=@{modes=@{Idle=@{name='静音';freqMax=1800};Balanced=@{name='均衡';freqMax=3500};Game=@{name='游戏';freqMax=4500}}}
    function Get-CurrentMode{return 'Idle'}
    function Get-AutoEnabled{return $true}
    function Read-GameDetectionState{return @{Fresh=$true;Reason='fixture game detection'}}
    function Get-UserActivityIdleSeconds{return 90}
    function Format-Freq($MHz){return "$MHz MHz"}
    . (Join-Path $project 'PowerProfileModernUI.ps1')
    $realSampler=${function:Invoke-TelemetrySample}
    # Stub only data sampling; all native controls and window lifetime are real.
    function Invoke-TelemetrySample{}
    foreach($mode in @('Idle','Balanced','Game')) {
        $icon=[ProfileVisual]::CreateIcon($mode)
        Assert-Equal "native icon created $mode" ($icon.Width -gt 0) $true
        $icon.Dispose()
    }
    Show-ModernDashboard
    Assert-Equal 'dashboard visible with taskbar entry' ($Script:Dashboard.Visible -and $Script:Dashboard.ShowInTaskbar) $true
    Assert-Equal 'native Windows visibility confirms dashboard' ([ProfileVisual]::IsWindowVisible($Script:Dashboard.Handle)) $true
    $Script:Dashboard.Hide()
    Show-ModernDashboard
    Assert-Equal 'second click restores hidden dashboard' $Script:Dashboard.Visible $true
    Assert-Equal 'dashboard displays actual mode source' $Script:Dashboard.Tag.Fields.mode.Text '静音 · 自动'
    Assert-Equal 'dashboard displays detection reason' $Script:Dashboard.Tag.Fields.reason.Text 'fixture game detection'
    $dashboardInvoked=New-Object 'System.Collections.Generic.List[string]'
    $Script:DashboardActions=@{}
    foreach($key in @('Auto','Idle','Balanced','Game','Settings','Logs','Workstation','PauseWorkstation','Legacy','Exit')){
        $item=New-Object Windows.Forms.ToolStripMenuItem $key;$item.Tag=@{Key=$key;Invoked=$dashboardInvoked}
        $item.Add_Click({param($sender,$eventArgs) $sender.Tag.Invoked.Add($sender.Tag.Key)})
        $Script:DashboardActions[$key]=$item
    }
    foreach($key in @('Auto','Idle','Balanced','Game','Settings','Logs')){$Script:Dashboard.Tag.Actions[$key].PerformClick()}
    foreach($item in $Script:Dashboard.Tag.MoreMenu.Items){$item.PerformClick()}
    Assert-Equal 'main window routes all actions to shared tray handlers' ($dashboardInvoked -join ',') 'Auto,Idle,Balanced,Game,Settings,Logs,Workstation,PauseWorkstation,Legacy,Exit'
    Assert-Equal 'auto state is visible on main button' $Script:Dashboard.Tag.Actions.Auto.Text '自动切换 · 开'
    Assert-Equal 'main controls fit client area' (@($Script:Dashboard.Controls | Where-Object {$_.Bottom -gt $Script:Dashboard.ClientSize.Height -or $_.Right -gt $Script:Dashboard.ClientSize.Width}).Count) 0
    Assert-Equal 'merged energy card exists' ($Script:Dashboard.Tag.Fields.ContainsKey('watts')) $true
    Assert-Equal 'unconfigured energy never displays demo watts' $Script:Dashboard.Tag.Fields.watts.Text '-- W'
    Show-EnergyDetails
    Assert-Equal 'energy details visible' $Script:EnergyDetails.Visible $true
    Assert-Equal 'unconfigured switch is disabled' $Script:EnergyDetails.Tag.Fields.switch.Enabled $false
    Assert-Equal 'unconfigured chart has no fake data points' $Script:EnergyDetails.Tag.Chart.Points.Count 0
    $Script:EnergyDetails.Close()
    Assert-Equal 'closing details releases window only' ($null -eq $Script:EnergyDetails -and $null -ne $Script:EnergyService) $true
    # Render each actual mode and overlay state with isolated telemetry, without changing power.
    $ScriptDir=$testRoot
    $stamp=[DateTime]::UtcNow.ToString('o')
    Write-AtomicJson (Join-Path $testRoot 'system_status.json') @{observedAt=$stamp;cpu=12;cpuFrequencyMHz=2350;memoryPercent=51;memoryUsedGB=16.2;memoryTotalGB=31.7;hardware=@{cpuName='Fixture CPU';cores=14;logicalProcessors=20};fieldStates=@{cpuFrequencyMHz=@{state='fresh';observedAt=$stamp}}}
    Write-AtomicJson (Join-Path $testRoot 'workstation_state.json') @{active=$false;observedAt=$stamp;reason='等待离开 20 分钟'}
    Update-ModernDashboard
    Assert-Equal 'current frequency is distinct from configured limit' $Script:Dashboard.Tag.Fields.frequency.Text '2.35 GHz'
    Assert-Equal 'dashboard shows configured quiet limit' $Script:Dashboard.Tag.Fields.limit.Text '1.80 GHz'
    Assert-Equal 'dashboard shows used and total memory' ($Script:Dashboard.Tag.Fields.memory.Text.Contains('16.2 / 31.7 GB')) $true
    Assert-Equal 'dashboard shows CPU identity' $Script:Dashboard.Tag.Fields.hardware.Text 'Fixture CPU'
    Assert-Equal 'dashboard shows power and uptime' ([bool]$Script:Dashboard.Tag.Fields.power.Text -and [bool]$Script:Dashboard.Tag.Fields.uptime.Text) $true
    Write-AtomicJson (Join-Path $testRoot 'workstation_state.json') @{active=$true;observedAt=$stamp;freqMax=1500;reason='满足省电条件'}
    Update-ModernDashboard
    Assert-Equal 'active overlay gets prominent mode name' $Script:Dashboard.Tag.Fields.mode.Text '工作站省电 · 自动'
    Assert-Equal 'active overlay displays its own limit' $Script:Dashboard.Tag.Fields.limit.Text '1.50 GHz · 工作站附加上限'
    Assert-Equal 'active overlay explains its base profile' ($Script:Dashboard.Tag.Fields.plan.Text.Contains('基础档位：静音')) $true
    function Get-CurrentMode{return 'Game'}
    $Script:Settings.modes.Game.freqMax=0
    Update-ModernDashboard
    Assert-Equal 'game profile wins over incompatible overlay snapshot' $Script:Dashboard.Tag.Fields.mode.Text '游戏 · 自动'
    Assert-Equal 'zero configured limit is explained rather than shown as zero GHz' $Script:Dashboard.Tag.Fields.limit.Text '不设额外频率上限'
    function Get-CurrentMode{return 'Balanced'}
    Update-ModernDashboard
    Assert-Equal 'balanced profile is clearly identified' $Script:Dashboard.Tag.Fields.mode.Text '均衡 · 自动'
    $expired=[DateTime]::UtcNow.AddMinutes(-2).ToString('o')
    Write-AtomicJson (Join-Path $testRoot 'system_status.json') @{observedAt=$stamp;cpuFrequencyMHz=2350;fieldStates=@{cpuFrequencyMHz=@{state='stale';observedAt=$expired}}}
    Update-ModernDashboard
    Assert-Equal 'expired frequency is not shown as current' $Script:Dashboard.Tag.Fields.frequency.Text '等待采样'
    $logger=${function:Write-ProfileEvent}
    $Script:watchEvents=@();$Script:fixtureKills=0
    function Write-ProfileEvent {param($Event,$Message,$Level,$Data) $Script:watchEvents+=@($Event)}
    function Start-HiddenPowerShell {param($Arguments) return $null}
    $Script:TelemetryOperationId='fixture-progress'
    $Script:TelemetryStarted=[DateTime]::UtcNow.AddSeconds(-35)
    $Script:TelemetryProgressAt=$Script:TelemetryStarted
    $Script:TelemetryProcess=[PSCustomObject]@{HasExited=$false;ExitCode=-1}
    $Script:TelemetryProcess | Add-Member ScriptMethod Kill {$this.HasExited=$true;$Script:fixtureKills++}
    $Script:TelemetryProcess | Add-Member ScriptMethod Dispose {}
    Write-AtomicJson (Join-Path $testRoot 'system_status.json') @{observedAt=[DateTime]::UtcNow.ToString('o');operationId='fixture-progress';stage='gpu-loading'}
    & $realSampler
    Assert-Equal 'recent partial progress keeps active sampler alive' $Script:fixtureKills 0
    $Script:TelemetryStarted=[DateTime]::UtcNow.AddSeconds(-50)
    & $realSampler
    Assert-Equal 'hard deadline terminates only owned sampler' $Script:fixtureKills 1
    Assert-Equal 'watchdog timeout records one warning rather than duplicate failure' ($Script:watchEvents -join ',') 'telemetry.timeout'
    ${function:Write-ProfileEvent}=$logger
    function Get-CurrentMode{return 'Idle'}
    $ScriptDir=$project
    $timer=$Script:Dashboard.Tag.Timer
    $form=$Script:Dashboard
    $form.Close();[Windows.Forms.Application]::DoEvents()
    Assert-Equal 'closing dashboard stops refresh timer' $timer.Enabled $false
    Assert-Equal 'closing dashboard releases form reference' ($null -eq $Script:Dashboard) $true
    Assert-Equal 'UI loading leaves settings unchanged' (Get-FileHash $SettingsPath).Hash (Get-FileHash (Join-Path $project 'settings.example.json')).Hash
    . (Join-Path $project 'PowerProfileDetection.ps1')
    $before=Get-Content $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    function Invoke-WorkstationWorker {param([switch]$Restore) $Script:fixtureRestorePath=Join-Path $ScriptDir 'PowerProfile.ps1'}
    $Script:DashboardActions.Settings.Add_Click({$Script:routedSettingsForm=Show-ModernSettings -ReturnForm})
    Invoke-DashboardAction Settings
    $settingsForm=$Script:routedSettingsForm
    $settingsForm.Show();[Windows.Forms.Application]::DoEvents()
    $plan=$settingsForm.Tag.Plan
    Assert-Equal 'schedule dropdown defaults to statutory working days' $plan.Schedule.SelectedItem.Value 'ChineseWorkdays'
    Assert-Equal 'wait dropdown keeps twenty minute default' $plan.Away.SelectedItem.Value 20
    Assert-Equal 'all plan selectors are true dropdowns' (@($plan.Schedule,$plan.Away,$plan.Start,$plan.End,$plan.Frequency,$plan.Quiet | Where-Object {$_.DropDownStyle -ne 'DropDownList'}).Count) 0
    foreach($pair in @(@('Schedule','EveryDay'),@('Away',5),@('Start',0),@('End',1440),@('Quiet',30))){
        $combo=$plan[$pair[0]]
        for($i=0;$i -lt $combo.Items.Count;$i++){if([string]$combo.Items[$i].Value -eq [string]$pair[1]){$combo.SelectedIndex=$i;break}}
    }
    $saveButton=@($settingsForm.Controls | Where-Object { $_ -is [Windows.Forms.Button] -and $_.Text -eq '保存' })[0]
    $saveButton.PerformClick()
    Assert-Equal 'overview settings save restores overlay with valid worker path' $Script:fixtureRestorePath (Join-Path $project 'PowerProfile.ps1')
    Assert-Equal 'successful save closes settings window' $settingsForm.Visible $false
    $after=Get-Content $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach($mode in @('Idle','Balanced','Game')) {
        Assert-Equal "modern UI save preserves CPU $mode" ($after.modes.$mode | ConvertTo-Json -Compress) ($before.modes.$mode | ConvertTo-Json -Compress)
    }
    Assert-Equal 'modern UI save changes only UI option' $after.ui.toastEnabled $true
    Assert-Equal 'daily dropdown saved' $after.workstation.schedule 'EveryDay'
    Assert-Equal 'wait dropdown saved' $after.workstation.awayMinutes 5
    Assert-Equal 'all-day interval saved' ($after.workstation.startMinute -eq 0 -and $after.workstation.endMinute -eq 1440) $true
    Assert-Equal 'quiet confirmation saved' $after.workstation.quietConfirmSeconds 30
    Save-WorkstationOptions $false ([int]$after.workstation.freqMax) '2026-10-11T00:00:00'
    $toggled=Read-AtomicJson $SettingsPath
    Assert-Equal 'tray enable/pause preserves chosen wait' $toggled.workstation.awayMinutes 5
    Assert-Equal 'tray enable/pause preserves chosen date policy' $toggled.workstation.schedule 'EveryDay'
    Assert-Equal 'tray enable/pause preserves chosen interval' $toggled.workstation.endMinute 1440
    if($settingsForm.Icon){$settingsForm.Icon.Dispose()};$settingsForm.Dispose()
    $directForm=Show-ModernSettings -ReturnForm;$directForm.Show();[Windows.Forms.Application]::DoEvents()
    $Script:fixtureRestorePath=$null
    @($directForm.Controls | Where-Object {$_ -is [Windows.Forms.Button] -and $_.Text -eq '保存'})[0].PerformClick()
    Assert-Equal 'direct tray settings save retains installation path' $Script:fixtureRestorePath (Join-Path $project 'PowerProfile.ps1')
    Assert-Equal 'direct settings save closes window' $directForm.Visible $false
    if($directForm.Icon){$directForm.Icon.Dispose()};$directForm.Dispose()
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\PowerProfileUITests-'
    if(-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected cleanup target'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host 'All UI/version regression tests passed.'
