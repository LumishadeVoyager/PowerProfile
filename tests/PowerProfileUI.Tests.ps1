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
    $legacyHashes=@{'PowerProfile.ps1'='C20E87B2D7D7ED078549737F18C83553C0FA24A6E19DD82968D931E84D1A6047';'PowerProfileLogic.ps1'='CB77219C7FBC41807DB823D9DFD237D1FFBC73C73E0531C4891FB8260D8FBE0F';'PowerProfileDetection.ps1'='764BE1BDAFD2064189EAD87FC3ED11C1D124A8EF48C44B45D7759024F261219D'}
    foreach($file in $legacyHashes.Keys) {
        # Git checkouts may use LF or CRLF; preserve the code hash independent of that setting.
        $bytes=[IO.File]::ReadAllBytes((Join-Path $project ('legacy\'+$file)))
        $canonical=[Text.Encoding]::UTF8.GetBytes(([Text.Encoding]::UTF8.GetString($bytes)).Replace("`r`n","`n"))
        $hash=[Security.Cryptography.SHA256]::Create()
        try{$actual=[BitConverter]::ToString($hash.ComputeHash($canonical)).Replace('-','')}finally{$hash.Dispose()}
        Assert-Equal "legacy core preserved: $file" $actual $legacyHashes[$file]
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
    Assert-Equal 'main controls fit accessible scroll canvas' (@($Script:Dashboard.Controls | Where-Object {$_.Bottom -gt $Script:Dashboard.DisplayRectangle.Height -or $_.Right -gt $Script:Dashboard.DisplayRectangle.Width}).Count) 0
    Assert-Equal 'dashboard remains accessible on short screens' ($Script:Dashboard.AutoScroll -and $Script:Dashboard.AutoScrollMinSize.Height -ge 804) $true
    $dashboardSize=$Script:Dashboard.ClientSize
    $Script:Dashboard.ClientSize=New-Object Drawing.Size 500,540
    [Windows.Forms.Application]::DoEvents()
    Assert-Equal 'short-screen dashboard exposes a scroll range for all controls' ($Script:Dashboard.VerticalScroll.Visible -and $Script:Dashboard.VerticalScroll.Maximum -ge $Script:Dashboard.AutoScrollMinSize.Height-1) $true
    $Script:Dashboard.AutoScrollPosition=New-Object Drawing.Point 0,0;$Script:Dashboard.ClientSize=$dashboardSize
    Assert-Equal 'merged energy card exists' ($Script:Dashboard.Tag.Fields.ContainsKey('watts')) $true
    Assert-Equal 'unconfigured energy never displays demo watts' $Script:Dashboard.Tag.Fields.watts.Text '-- W'
    Show-EnergyDetails
    Assert-Equal 'energy details visible' $Script:EnergyDetails.Visible $true
    $cloudForm=Show-CloudHistory -ReturnForm
    Assert-Equal 'cloud history opens without starting a background job' ($null -eq $cloudForm.Tag.Process) $true
    Assert-Equal 'cloud import requires actual queried data' $cloudForm.Tag.Import.Enabled $false
    $qrPath=Join-Path $testRoot 'qr.png';$statusPath=Join-Path $testRoot 'qr-status.json'
    $bitmap=New-Object Drawing.Bitmap 20,20;$bitmap.Save($qrPath,[Drawing.Imaging.ImageFormat]::Png);$bitmap.Dispose()
    @{phase='scan';message='scan fixture';image=$qrPath}|ConvertTo-Json|Set-Content $statusPath -Encoding UTF8
    Update-CloudHistoryStatus $cloudForm $statusPath
    Assert-Equal 'QR displayed from status' ($null -ne $cloudForm.Tag.Picture.Image) $true
    $writer=[IO.File]::Open($qrPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$writer.Dispose()
    Assert-Equal 'displayed QR releases source file for refresh' $true $true
    $cloudForm.Tag.LastStatus=''
    $held=[IO.File]::Open($qrPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{Update-CloudHistoryStatus $cloudForm $statusPath;Assert-Equal 'failed image read remains retryable' $cloudForm.Tag.LastStatus ''}finally{$held.Dispose()}
    Update-CloudHistoryStatus $cloudForm $statusPath
    Assert-Equal 'transient image lock recovers on next update' ($cloudForm.Tag.LastStatus -ne '') $true
    @{phase='error';message='二维码已过期，请重新申请'}|ConvertTo-Json|Set-Content $statusPath -Encoding UTF8
    Update-CloudHistoryStatus $cloudForm $statusPath
    Assert-Equal 'expired QR is removed with readable status' ($null -eq $cloudForm.Tag.Picture.Image -and $cloudForm.Tag.Status.Text -like '*过期*') $true
    foreach($control in $cloudForm.Controls){if($control.Right -gt $cloudForm.ClientSize.Width -or $control.Bottom -gt $cloudForm.ClientSize.Height){throw 'Cloud history control outside window'}}
    $cloudForm.Tag.Timer.Dispose();$cloudForm.Dispose()
    Assert-Equal 'unconfigured switch is disabled' $Script:EnergyDetails.Tag.Fields.switch.Enabled $false
    Assert-Equal 'unconfigured chart has no fake data points' $Script:EnergyDetails.Tag.Chart.Points.Count 0
    Assert-Equal 'daily table defaults to thirty dates' $Script:EnergyDetails.Tag.DailyGrid.Rows.Count 30
    Assert-Equal 'uncollected daily rows are labeled rather than zero billed' $Script:EnergyDetails.Tag.DailyGrid.Rows[0].Cells[1].Value '未采集'
    Assert-Equal 'weekly total is displayed without invented readings' $Script:EnergyDetails.Tag.Fields.week.Text '等待累计'
    $Script:EnergyDetails.Tag.Range.SelectedIndex=0
    Assert-Equal 'daily range can switch to seven days' $Script:EnergyDetails.Tag.DailyGrid.Rows.Count 7
    $dailyFixture=New-Object ProfileEnergyHistory;$dailyFixture.Days=New-Object 'Collections.Generic.Dictionary[string,ProfileEnergyDay]'
    $localDay=[TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow,[TimeZoneInfo]::FindSystemTimeZoneById('China Standard Time')).ToString('yyyy-MM-dd')
    $dailyFixture.Days[$localDay]=New-Object ProfileEnergyDay;$dailyFixture.Days[$localDay].Seconds=3600
    $dailyState=[ProfileEnergyService]::Summarize($dailyFixture,[decimal]0.7,[DateTime]::UtcNow)
    Update-EnergyDailyRows $dailyState
    Assert-Equal 'recorded zero remains distinct from uncollected date in table' $Script:EnergyDetails.Tag.DailyGrid.Rows[0].Cells[1].Value '0.000'
    Assert-Equal 'zero energy yields zero cost at configured tariff' $Script:EnergyDetails.Tag.DailyGrid.Rows[0].Cells[2].Value '¥0.00'
    $Script:EnergyDetails.Tag.Group.SelectedIndex=1
    Assert-Equal 'weekly history exposes eight calendar weeks' $Script:EnergyDetails.Tag.DailyGrid.Rows.Count 8
    Update-EnergyDailyRows $dailyState
    Assert-Equal 'weekly history aggregates daily energy and price' $Script:EnergyDetails.Tag.DailyGrid.Rows[0].Cells[2].Value '¥0.00'
    $Script:EnergyDetails.Tag.Group.SelectedIndex=2
    Assert-Equal 'monthly history exposes six calendar months' $Script:EnergyDetails.Tag.DailyGrid.Rows.Count 6
    Assert-Equal 'monthly row uses current China calendar month' $Script:EnergyDetails.Tag.DailyGrid.Rows[0].Cells[0].Value $localDay.Substring(0,7)
    $Script:EnergyDetails.Tag.Group.SelectedIndex=0
    $dailyFixture.Days[$localDay].KWh=0.5
    $dailyFixture.Days[$localDay].HighPowerSeconds=600;$dailyFixture.Days[$localDay].HighPowerCoverageSeconds=1800
    $dailyFixture.Days[$localDay].GameSeconds=1200;$dailyFixture.Days[$localDay].GameCoverageSeconds=2400
    $previousDay=([DateTime]::ParseExact($localDay,'yyyy-MM-dd',$null)).AddDays(-1).ToString('yyyy-MM-dd')
    $dailyFixture.Days[$previousDay]=New-Object ProfileEnergyDay
    $dailyFixture.Days[$previousDay].KWh=1.5;$dailyFixture.Days[$previousDay].Source='MiHome'
    $displayState=[ProfileEnergyService]::Summarize($dailyFixture,[decimal]0.7,[DateTime]::UtcNow)
    $displayState.Configured=$true;$displayState.Status='已连接';$displayState.On=$true;$displayState.Watts=140;$displayState.ObservedAt=[DateTime]::UtcNow
    for($i=0;$i -lt 60;$i++){
        $point=New-Object ProfileEnergyPoint;$point.Time=[DateTime]::UtcNow.AddMinutes(-59+$i);$point.Watts=60+($i%12)*9;$point.BreakBefore=($i -eq 30);$displayState.Points.Add($point)
    }
    Update-EnergyDetails $displayState
    Assert-Equal 'expense overview leads with measured period cost' $Script:EnergyDetails.Tag.Fields.dayFee.Text '¥0.35'
    Assert-Equal 'expense overview retains energy alongside cost' $Script:EnergyDetails.Tag.Fields.today.Text '0.500 kWh'
    Assert-Equal 'local coverage remains explicit' ($Script:EnergyDetails.Tag.Fields.dayCoverage.Text -like '*1.0 小时*') $true
    Assert-Equal 'cloud and local coverage are distinguished' ((Get-EnergyPeriodCoverage $displayState $previousDay) -like '*米家 1 天*估算*') $true
    Assert-Equal 'hourly reference uses current watts and fixed tariff' ($Script:EnergyDetails.Tag.Fields.hourCost.Text -like '*0.098*') $true
    Assert-Equal 'usage column displays monitored awake hours' $Script:EnergyDetails.Tag.DailyGrid.Rows[0].Cells[4].Value '1 小时 00 分'
    Assert-Equal 'high-power column uses 150W segment duration' $Script:EnergyDetails.Tag.DailyGrid.Rows[0].Cells[5].Value '10 分钟 *'
    Assert-Equal 'legacy high-power duration stays unknown' $Script:EnergyDetails.Tag.DailyGrid.Rows[1].Cells[5].Value '未统计'
    Assert-Equal 'game duration is readable and discloses partial coverage' $Script:EnergyDetails.Tag.DailyGrid.Rows[0].Cells[6].Value '20 分钟 *'
    Assert-Equal 'legacy gaming remains unknown rather than zero' $Script:EnergyDetails.Tag.DailyGrid.Rows[1].Cells[6].Value '未统计'
    Assert-Equal 'record hint explains game detection coverage' ($Script:EnergyDetails.Tag.Fields.recordHint.Text -like '*游戏识别覆盖 40 分钟*') $true
    Assert-Equal 'ledger shows at least six full rows' (($Script:EnergyDetails.Tag.DailyGrid.Height-$Script:EnergyDetails.Tag.DailyGrid.ColumnHeadersHeight) -ge 6*$Script:EnergyDetails.Tag.DailyGrid.RowTemplate.Height) $true
    Assert-Equal 'short measured durations are not rounded down to zero' (Format-EnergyDuration 30) '<1 分钟'
    $latestPeriod=$Script:EnergyDetails.Tag.Timeline.Periods[$Script:EnergyDetails.Tag.Timeline.Periods.Count-1]
    Assert-Equal 'combined timeline retains cost and two independent hour series' ($latestPeriod.Cost -eq 0.35 -and $latestPeriod.UsageHours -eq 1 -and [Math]::Abs($latestPeriod.HighHours-1.0/6) -lt 0.00001) $true
    Assert-Equal 'partial high-power coverage remains disclosed' $latestPeriod.HighCoverageHours 0.5
    Assert-Equal 'game duration is included in the combined timeline' ([Math]::Abs($latestPeriod.GameHours-1.0/3) -lt 0.00001) $true
    $Script:EnergyDetails.Tag.Group.SelectedIndex=1;Update-EnergyDetails $displayState
    Assert-Equal 'weekly ledger includes game duration' $Script:EnergyDetails.Tag.DailyGrid.Rows[0].Cells[6].Value '20 分钟 *'
    $Script:EnergyDetails.Tag.Group.SelectedIndex=2;Update-EnergyDetails $displayState
    Assert-Equal 'monthly ledger includes game duration' $Script:EnergyDetails.Tag.DailyGrid.Rows[0].Cells[6].Value '20 分钟 *'
    $Script:EnergyDetails.Tag.Group.SelectedIndex=0;Update-EnergyDetails $displayState
    $Script:EnergyDetails.Tag.DailyGrid.FirstDisplayedScrollingRowIndex=5;$displayState.ObservedAt=[DateTime]::UtcNow.AddMilliseconds(-1);Update-EnergyDetails $displayState
    Assert-Equal 'refresh preserves ledger scroll position' $Script:EnergyDetails.Tag.DailyGrid.FirstDisplayedScrollingRowIndex 5
    $Script:EnergyDetails.Tag.DailyGrid.FirstDisplayedScrollingRowIndex=0
    $Script:EnergyDetails.Tag.DailyGrid.CurrentCell=$Script:EnergyDetails.Tag.DailyGrid.Rows[1].Cells[0]
    Assert-Equal 'selection changes record coverage explanation' ($Script:EnergyDetails.Tag.Fields.recordHint.Text -like '*不能反推*') $true
    $logsOnly=New-Object ProfileEnergySnapshot;$logsOnly.LocalDay=$displayState.LocalDay;$logsOnly.WeekStart=$displayState.WeekStart;$logsOnly.MonthStart=$displayState.MonthStart;$logsOnly.UsageUpdatedAt=[DateTime]::UtcNow
    $usageOnly=New-Object ProfileEnergyDay;$usageOnly.Seconds=7200;$usageOnly.GameSeconds=3600;$usageOnly.GameCoverageSeconds=7200;$usageOnly.UsageSource='日志估算';$logsOnly.UsageDays[$localDay]=$usageOnly
    Update-EnergyDailyRows $logsOnly
    Assert-Equal 'log-derived usage appears even when energy is unavailable' ($Script:EnergyDetails.Tag.DailyGrid.Rows[0].Cells[1].Value -eq '未采集' -and $Script:EnergyDetails.Tag.DailyGrid.Rows[0].Cells[4].Value -eq '2 小时 00 分' -and $Script:EnergyDetails.Tag.DailyGrid.Rows[0].Cells[6].Value -eq '1 小时 00 分') $true
    Update-EnergyDetails $displayState
    $Script:EnergyDetails.Tag.DailyGrid.CurrentCell=$Script:EnergyDetails.Tag.DailyGrid.Rows[0].Cells[0]
    $Script:EnergyDetails.Tag.ChartMode.SelectedIndex=1
    Assert-Equal 'power view remains available alongside billing timeline' ($Script:EnergyDetails.Tag.Chart.Visible -and -not $Script:EnergyDetails.Tag.Timeline.Visible) $true
    $Script:EnergyDetails.Tag.ChartMode.SelectedIndex=0
    Set-EnergyChartRange $true
    Assert-Equal 'chart period selection changes displayed range' $Script:EnergyDetails.Tag.Chart.Today $true
    Set-EnergyChartRange $false
    if($env:POWERPROFILE_UI_PREVIEW){
        $bitmap=New-Object Drawing.Bitmap $Script:EnergyDetails.Width,$Script:EnergyDetails.Height
        try{$Script:EnergyDetails.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle 0,0,$bitmap.Width,$bitmap.Height));$bitmap.Save($env:POWERPROFILE_UI_PREVIEW)}finally{$bitmap.Dispose()}
    }
    $displayState.ObservedAt=[DateTime]::UtcNow.AddMinutes(-2)
    Update-EnergyDetails $displayState
    Assert-Equal 'stale readings do not appear as current power' $Script:EnergyDetails.Tag.Fields.watts.Text '-- W'
    Assert-Equal 'stale readings do not produce hourly fee references' ($Script:EnergyDetails.Tag.Fields.hourCost.Text -notlike '*0.098*') $true
    Assert-Equal 'stored period cost survives stale live readings' $Script:EnergyDetails.Tag.Fields.dayFee.Text '¥0.35'
    $energyForm=$Script:EnergyDetails
    foreach($parent in @($energyForm)+@($energyForm.Controls | Where-Object {$_ -is [Windows.Forms.Panel]})){
        Assert-Equal 'energy controls fit accessible parent canvas' (@($parent.Controls | Where-Object {$_.Bottom -gt $parent.DisplayRectangle.Height -or $_.Right -gt $parent.DisplayRectangle.Width}).Count) 0
        $controls=@($parent.Controls | Where-Object {$_.Visible})
        for($a=0;$a -lt $controls.Count;$a++){for($b=$a+1;$b -lt $controls.Count;$b++){if($controls[$a].Bounds.IntersectsWith($controls[$b].Bounds)){throw "Overlapping energy controls: $($controls[$a].Text) / $($controls[$b].Text)"}}}
    }
    Write-Host 'PASS energy sibling controls do not overlap'
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
    function Invoke-WorkstationWorker {param([switch]$Restore,[string]$WorkerPath) $Script:fixtureRestorePath=$WorkerPath}
    $Script:DashboardActions.Settings.Add_Click({$Script:routedSettingsForm=Show-ModernSettings -ReturnForm})
    Invoke-DashboardAction Settings
    $settingsForm=$Script:routedSettingsForm
    $settingsForm.Show();[Windows.Forms.Application]::DoEvents()
    $plan=$settingsForm.Tag.Plan
    $settingsTabs=@($settingsForm.Controls | Where-Object {$_ -is [Windows.Forms.TabControl]})[0]
    Assert-Equal 'settings consolidate explanatory pages into three tabs' $settingsTabs.TabPages.Count 3
    $policyTab=$settingsTabs.TabPages | Where-Object {$_.Text -eq '高级与规则'}
    Assert-Equal 'original policy removes automatic workload threshold controls' (@($policyTab.Controls | Where-Object {$_ -is [Windows.Forms.ComboBox]}).Count) 0
    Assert-Equal 'policy page explains quiet default' (@($policyTab.Controls | Where-Object {$_.Text -like '日常静音*'}).Count) 1
    Assert-Equal 'schedule dropdown defaults to statutory working days' $plan.Schedule.SelectedItem.Value 'ChineseWorkdays'
    Assert-Equal 'wait dropdown keeps twenty minute default' $plan.Away.SelectedItem.Value 20
    Assert-Equal 'categorical selectors remain compact dropdowns' (@($plan.Schedule,$plan.Away,$plan.Frequency,$plan.Quiet | Where-Object {$_.DropDownStyle -ne 'DropDownList'}).Count) 0
    Assert-Equal 'time uses editable native clock controls' ($plan.Start -is [Windows.Forms.DateTimePicker] -and $plan.End -is [Windows.Forms.DateTimePicker] -and $plan.Start.ShowUpDown -and $plan.End.ShowUpDown) $true
    foreach($pair in @(@('Schedule','EveryDay'),@('Away',5),@('Quiet',30))){
        $combo=$plan[$pair[0]]
        for($i=0;$i -lt $combo.Items.Count;$i++){if([string]$combo.Items[$i].Value -eq [string]$pair[1]){$combo.SelectedIndex=$i;break}}
    }
    $plan.AllDay.Checked=$true
    Assert-Equal 'all day disables custom clock fields' (-not $plan.Start.Enabled -and -not $plan.End.Enabled) $true
    $saveButton=@($settingsForm.Controls | Where-Object { $_ -is [Windows.Forms.Button] -and $_.Text -eq '保存' })[0]
    $fixtureSettingsPath=$SettingsPath;$SettingsPath=$null
    $saveButton.PerformClick()
    $SettingsPath=$fixtureSettingsPath
    Assert-Equal 'save succeeds without ambient settings path' $settingsForm.Tag.LastSaveError ''
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
    Assert-Equal 'settings save does not reinstate workload switching policy' ($after.autoLoad | ConvertTo-Json -Compress) ($before.autoLoad | ConvertTo-Json -Compress)
    Save-WorkstationOptions $false ([int]$after.workstation.freqMax) '2026-10-11T00:00:00'
    $toggled=Read-AtomicJson $SettingsPath
    Assert-Equal 'tray enable/pause preserves chosen wait' $toggled.workstation.awayMinutes 5
    Assert-Equal 'tray enable/pause preserves chosen date policy' $toggled.workstation.schedule 'EveryDay'
    Assert-Equal 'tray enable/pause preserves chosen interval' $toggled.workstation.endMinute 1440
    if($settingsForm.Icon){$settingsForm.Icon.Dispose()};$settingsForm.Dispose()
    $directForm=Show-ModernSettings -ReturnForm
    $Script:fixtureRestorePath=$null
    $modalTimer=New-Object Windows.Forms.Timer;$modalTimer.Interval=50
    $modalTimer | Add-Member NoteProperty SettingsForm $directForm
    $modalTimer.Add_Tick({param($sender,$eventArgs) $sender.Stop();$dialog=$sender.SettingsForm;@($dialog.Controls | Where-Object {$_ -is [Windows.Forms.Button] -and $_.Text -eq '保存'})[0].PerformClick();if($dialog.Tag.LastSaveError){$dialog.Close()}})
    $SettingsPath=$null;$fixtureScriptDir=$ScriptDir;$ScriptDir=$null
    $modalTimer.Start();[void]$directForm.ShowDialog();$modalTimer.Dispose()
    $SettingsPath=$fixtureSettingsPath;$ScriptDir=$fixtureScriptDir
    Assert-Equal 'real modal event-loop save has no path error' $directForm.Tag.LastSaveError ''
    Assert-Equal 'direct tray settings save retains installation path' $Script:fixtureRestorePath (Join-Path $project 'PowerProfile.ps1')
    Assert-Equal 'direct settings save closes window' $directForm.Visible $false
    if($directForm.Icon){$directForm.Icon.Dispose()};$directForm.Dispose()
    $customForm=Show-ModernSettings -ReturnForm;$customForm.Show();[Windows.Forms.Application]::DoEvents()
    $clock=$customForm.Tag.Plan;$clock.AllDay.Checked=$false
    $clock.Start.Value=[DateTime]::Today.AddHours(22);$clock.End.Value=[DateTime]::Today.AddHours(6)
    $beforeInvalid=(Get-FileHash $SettingsPath).Hash
    $clockSave=@($customForm.Controls | Where-Object {$_ -is [Windows.Forms.Button] -and $_.Text -eq '保存'})[0];$clockSave.PerformClick()
    Assert-Equal 'invalid clock range gives readable inline feedback' ($customForm.Tag.LastSaveError -like '结束时间*' -and $customForm.Visible) $true
    Assert-Equal 'invalid clock range never partially saves' (Get-FileHash $SettingsPath).Hash $beforeInvalid
    $clock.Start.Value=[DateTime]::Today.AddHours(9).AddMinutes(17);$clock.End.Value=[DateTime]::Today.AddHours(18).AddMinutes(43)
    $clockSave.PerformClick();$custom=Read-AtomicJson $SettingsPath
    Assert-Equal 'custom start supports minute precision' $custom.workstation.startMinute 557
    Assert-Equal 'custom end supports minute precision' $custom.workstation.endMinute 1123
    $reopened=Show-ModernSettings -ReturnForm
    Assert-Equal 'custom clock survives reopening' ($reopened.Tag.Plan.Start.Value.ToString('HH:mm')+'–'+$reopened.Tag.Plan.End.Value.ToString('HH:mm')) '09:17–18:43'
    Assert-Equal 'custom period is not mislabeled as all day' $reopened.Tag.Plan.AllDay.Checked $false
    $reopened.Dispose();$customForm.Dispose()
    $realistic=Read-AtomicJson $SettingsPath;$realistic.modes.Idle.freqMax=2200;$realistic.modes.Idle.min=50;$realistic.processorBaseMHz=2600;$realistic.workstation.enabled=$true
    Write-AtomicJson $SettingsPath $realistic
    $enabledForm=Show-ModernSettings -ReturnForm;$enabledForm.Show();[Windows.Forms.Application]::DoEvents()
    @($enabledForm.Controls | Where-Object {$_ -is [Windows.Forms.Button] -and $_.Text -eq '保存'})[0].PerformClick()
    Assert-Equal 'enabled plan saves with calibrated real-world CPU parameters' $enabledForm.Tag.LastSaveError ''
    Assert-Equal 'enabled plan remains enabled after save' (Read-AtomicJson $SettingsPath).workstation.enabled $true
    $enabledForm.Dispose()
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\PowerProfileUITests-'
    if(-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected cleanup target'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host 'All UI/version regression tests passed.'
