$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$project=Split-Path -Parent $PSScriptRoot
$root=Join-Path $env:TEMP ('ProfileWorkspaceTests-'+[Guid]::NewGuid());[void][IO.Directory]::CreateDirectory($root)
$ScriptDir=$project;$SettingsPath=Join-Path $root 'settings.json';Copy-Item (Join-Path $project 'settings.example.json') $SettingsPath
function Assert($Name,$Value){if(-not $Value){throw $Name};Write-Host "PASS $Name"}
function Get-CurrentMode{return 'Idle'}
function Get-AutoEnabled{return $true}
function Read-GameDetectionState{return @{Fresh=$true;Reason='fixture game decision'}}
try{
    . (Join-Path $project 'PowerProfileModernUI.ps1')
    $realService=$Script:EnergyService;$realService.Dispose();$Script:EnergyLogTimer.Stop()
    function Start-DeviceHubWorker{}
    $today=[TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow,[TimeZoneInfo]::FindSystemTimeZoneById('China Standard Time')).Date
    $Script:fixture=New-Object ProfileEnergySnapshot;$Script:fixture.LocalDay=$today.ToString('yyyy-MM-dd');$Script:fixture.WeekStart=$today.AddDays(-(([int]$today.DayOfWeek+6)%7)).ToString('yyyy-MM-dd');$Script:fixture.MonthStart=$today.ToString('yyyy-MM')+'-01'
    $Script:fixture.Price=[decimal]0.7;$Script:fixture.Configured=$true;$Script:fixture.Status='已连接';$Script:fixture.ObservedAt=[DateTime]::UtcNow;$Script:fixture.UsageUpdatedAt=[DateTime]::UtcNow;$Script:fixture.Watts=82;$Script:fixture.On=$true;$Script:fixture.TodayKWh=0.5;$Script:fixture.MonthKWh=1.5
    for($i=0;$i -lt 2;$i++){
        $key=$today.AddDays(-$i).ToString('yyyy-MM-dd');$day=New-Object ProfileEnergyDay;$day.KWh=0.5;$day.Source=if($i -eq 0){'Local'}else{'MiHome'};$day.Seconds=7200;$Script:fixture.Days.Add($key,$day)
        $u=New-Object ProfileEnergyDay;$u.Seconds=7200;$u.HighPowerSeconds=if($i -eq 0){900}else{3600};$u.HighPowerCoverageSeconds=3600;$u.GameSeconds=3600;$u.GameCoverageSeconds=3600;$u.GameNames='NBA 2K26';$u.UsageSource='logs';if($i -eq 0){$u.ModeGameSeconds=2400};$Script:fixture.UsageDays.Add($key,$u)
    }
    $Script:fakeConfigureCount=0;$Script:fakeProbe=$null
    $service=[PSCustomObject]@{Address='192.168.1.9'};$service|Add-Member ScriptMethod GetSnapshot {return $Script:fixture};$service|Add-Member ScriptMethod Refresh {}; $service|Add-Member ScriptMethod Dispose {}
    $service|Add-Member ScriptMethod TestConnection {param($address,$token) [ProfileEnergyService]::Validate($address,$token,$null);$Script:fakeProbe=New-Object ProfileConnectionProbe;$Script:fakeProbe.Address=$address;return $Script:fakeProbe}
    $service|Add-Member ScriptMethod Configure {param($address,$token,$price) $Script:fakeConfigureCount++}
    $Script:EnergyService=$service
    $hubDir=Join-Path $root '.codex\device-hub';[void][IO.Directory]::CreateDirectory($hubDir)
    $light=[PSCustomObject]@{did='lamp';name='Test lamp';model='test.light.v1';switch=@{siid=2;piid=1};state=$false;observedAt=[DateTime]::UtcNow.ToString('o')}
    $plug=[PSCustomObject]@{did='plug';name='Computer plug';model='cuco.plug.v3';switch=@{siid=2;piid=1};state=$true;computerPower=$true;isPlug=$true;observedAt=[DateTime]::UtcNow.ToString('o')}
    $rule=[PSCustomObject]@{id='night';name='Night';did='lamp';model='test.light.v1';enabled=$true;mode='guard';value=$false;startMinute=0;endMinute=1080}
    Write-AtomicJson (Join-Path $root 'devices.hub.json') @{enabled=$true;rules=@($rule)}
    Write-AtomicJson (Join-Path $hubDir 'status.json') @{codeVersion=3;pid=0;observedAt=[DateTime]::UtcNow.ToString('o');devices=@($light,$plug);rules=@{};operations=@();enabled=$true}
    $settingsHash=(Get-FileHash $SettingsPath).Hash;$hubHash=(Get-FileHash (Join-Path $root 'devices.hub.json')).Hash
    $w=Show-ProfileWorkspace -ReturnForm;$w.Tag.Timer.Stop();$w.Show();[Windows.Forms.Application]::DoEvents()
    Assert 'all seven modules are in one native window' ($w.Pages.Count -eq 7 -and $w.Navigation.Count -eq 7)
    Assert 'default workspace uses a light portrait canvas' ($w.ClientSize.Width -le 540 -and [Math]::Abs($w.ClientSize.Width/$w.ClientSize.Height-0.75) -lt 0.01)
    Assert 'all destinations fit across top navigation' ($w.Navigation['Overview'].Parent -eq $w.NavigationStrip -and $w.Navigation['Settings'].Right -le $w.NavigationStrip.Width)
    Assert 'long explanations and filters start collapsed' (-not $w.Sections['Runtime'].Expanded -and -not $w.Sections['EnergyFilters'].Expanded -and -not $w.Sections['GameEvidence'].Expanded)
    Assert 'actual fee and power appear in overview' ($w.Metrics['cost'].Value.Text -eq '¥0.35' -and $w.Metrics['power'].Value.Text -eq '82.0 W')
    Assert 'overview reason is tied to existing detection' ($w.OverviewReason.Text -like '*fixture game decision*')
    Assert 'overview cards wrap into visible rows' ($w.Metrics['next'].Bottom -le $w.MetricHost.Height -and $w.Metrics['next'].Right -le $w.MetricHost.Width)
    $data=Get-WorkspaceEnergyData $Script:fixture 'Day' 3
    Assert 'ledger labels dates with weekdays and keeps absent data unknown' ($data.Rows[0].Date -match '周[一二三四五六日]' -and $data.Rows[2].Missing -and $data.Rows[2].Energy -eq '未采集')
    Assert 'metered and inferred high are distinguished without billing invention' ($data.Rows[0].High -like '*估*' -and $data.Periods[2].HighHours -eq (2400/3600) -and $data.Periods[2].Cost -eq 0.35)
    Assert 'evidence explains measured coverage and game names' ($data.Details[$Script:fixture.LocalDay] -like '*实测覆盖*' -and $data.Details[$Script:fixture.LocalDay] -like '*NBA 2K26*')
    $month=Get-WorkspaceEnergyData $Script:fixture 'Month' 1
    Assert 'period aggregation sums per-day effective high rather than maximum of totals' ([Math]::Abs($month.Periods[0].HighHours-6000/3600) -lt 0.00001)
    $w.Navigate('Energy');$w.Tag.Chart.SelectIndex(0)
    Assert 'chart selection links to ledger date and explanation' ([string]$w.Ledger.CurrentRow.Tag -eq $w.Tag.Chart.Periods[0].Key -and $w.SelectionInfo.Text -match '电量来源')
    $w.Tag.Chart.SetView(1,3);Assert 'chart range can narrow' ($w.Tag.Chart.ViewStart -eq 1 -and $w.Tag.Chart.ViewCount -eq 3)
    Invoke-WorkspaceCommand 'Series' '2:False';Assert 'series can be hidden without changing data' (-not $w.Tag.Chart.SeriesVisible[2] -and $Script:fixture.TodayKWh -eq 0.5)
    Invoke-WorkspaceCommand 'ResetChart';Assert 'chart resets viewport' ($w.Tag.Chart.ViewStart -eq 0 -and $w.Tag.Chart.ViewCount -eq 0)
    $aiRow=[PSCustomObject]@{date=$Script:fixture.LocalDay;client='Codex';model='test-model';source='native';tokens=12000;input=5000;cached=5000;write=0;output=2000;cost=$null;currency=$null;pricedTokens=0}
    Write-AtomicJson (Join-Path $root 'ai.snapshot.json') @{version=1;revision='fixture';startedAt=[DateTime]::UtcNow.ToString('o');updatedAt=[DateTime]::UtcNow.ToString('o');rows=@($aiRow);daily=@($aiRow);status=@{Codex='已接入';'Claude Code'='未发现本地目录'};errors=@{}}
    $w.Navigate('AI');Assert 'AI tab shows recorded tokens with unknown prices preserved' ($w.AIGrid.Rows.Count -eq 1 -and $w.AIGrid.Rows[0].Cells[4].Value -eq '待配置' -and $w.AITokens.Value.Text -eq '1.20 万' -and $w.AICost.Value.Text -eq '待配置' -and $w.AITokens.AccessibleDescription -match '12,000')
    $wideAI=$w.AIStatHost.ClientSize.Width -ge 2*($w.AIStatHost.ItemWidth+10)
    $alignedAI=if($wideAI){$w.AITokens.Top -eq $w.AICost.Top}else{$w.AICost.Top -ge $w.AITokens.Bottom}
    Assert ('AI cards adapt to available width and keep values readable (host {0}; token height/font {1}/{2}; cost {3}/{4})' -f $w.AIStatHost.Width,$w.AITokens.Value.Height,$w.AITokens.Value.Font.Height,$w.AICost.Value.Height,$w.AICost.Value.Font.Height) ($w.AIStatHost.Controls.Count -eq 2 -and $alignedAI -and $w.AITokens.Value.Height -ge $w.AITokens.Value.Font.Height -and $w.AICost.Value.Height -ge $w.AICost.Value.Font.Height)
    Assert 'exact totals stay in collapsed details instead of five summary lines' (-not $w.Sections['AIStatus'].Expanded -and $w.AIStatus.Text -match '12,000' -and $w.AIPeriodSummary.Text -notmatch "`n")
    Assert 'AI chart uses recorded daily tokens and its own unit' ($w.Tag.AIChart.AnalyticsMode -eq 1 -and @($w.Tag.AIChart.Periods|Where-Object {$_.CodexTokens -eq 0.012}).Count -eq 1)
    $w.Navigate('Energy');$w.AnalysisMode.SelectedIndex=1;$p=@($w.Tag.Chart.Periods|Where-Object Key -eq $Script:fixture.LocalDay)[0]
    Assert 'integrated trend retains power cost and uses a separate million-token axis' ($w.Tag.Chart.AnalyticsMode -eq 1 -and $p.CodexTokens -eq 0.012 -and $p.Cost -eq 0.35 -and $w.Ledger.Columns[7].Visible)
    $w.AnalysisMode.SelectedIndex=2;Assert 'unpriced AI fees remain a gap in money view' ($null -eq $p.CodexCost -and $p.CodexCostPartial)
    $aiRow.cost=0.02;$aiRow.currency='USD';$aiRow.pricedTokens=6000
    Write-AtomicJson (Join-Path $root 'ai.snapshot.json') @{version=1;revision='priced';updatedAt=[DateTime]::UtcNow.ToString('o');rows=@($aiRow);daily=@($aiRow);status=@{};errors=@{}}
    $w.Navigate('AI');Assert 'cost card visualizes partial pricing coverage' ($w.AICost.Value.Text -eq '0.02' -and $w.AICost.Fraction -eq 0.5 -and $w.AICost.Context.Text -match '部分')
    $w.AICurrency.SelectedItem='CNY';Assert 'currency switch never presents USD as CNY' ($w.AICost.Value.Text -eq '—' -and $w.AICost.Context.Text -match '其他币种')
    $w.AICurrency.SelectedItem='USD';Write-AtomicJson (Join-Path $root 'ai.charges.json') @{charges=@(@{date=$Script:fixture.LocalDay;client='Codex';currency='USD';amount=20})}
    $w.Tag.AIChargeRevision='fixture-charge';$w.AIView.SelectedIndex=2
    Assert 'independent expense view keeps tokens and charges in distinct cards' ($w.AICost.Caption.Text -match '独立支出' -and $w.AICost.Value.Text -eq '20.00' -and $w.AITokens.Value.Text -eq '1.20 万' -and -not $w.AIChartHost.Visible)
    $oldAI=$aiRow.PSObject.Copy();$oldAI.date=$today.AddDays(-520).ToString('yyyy-MM-dd');$oldAI.tokens=8000;$oldAI.pricedTokens=0;$oldAI.cost=$null;$oldAI.currency=$null
    Write-AtomicJson (Join-Path $root 'ai.snapshot.json') @{version=1;revision='all-time';updatedAt=[DateTime]::UtcNow.ToString('o');rows=@($aiRow,$oldAI);combinedRows=@($aiRow,$oldAI);daily=@($aiRow);combinedDaily=@($aiRow);status=@{};errors=@{}}
    $w.AIView.SelectedIndex=0;$w.Tag.AIKey='';Update-WorkspaceAI
    Assert 'AI defaults to combined all-history including records older than 400 days' ($w.AISource.SelectedIndex -eq 2 -and $w.AIRange.SelectedIndex -eq 4 -and $w.AIGrid.Rows.Count -eq 2 -and $w.AITokens.Value.Text -eq '2.00 万' -and $w.Tag.AIChart.Periods.Count -eq 521 -and -not $w.Sections['AIFilters'].Expanded -and $w.AIPeriodSummary.Text -match $oldAI.date)
    $w.AIRange.SelectedIndex=0;Assert 'optional date filtering leaves lifetime total intact' ($w.AIGrid.Rows.Count -eq 1 -and $w.AITokens.Value.Text -eq '2.00 万')
    $w.AIRange.SelectedIndex=4
    $w.AIView.SelectedIndex=0;$w.ClientSize=New-Object Drawing.Size 420,600;[Windows.Forms.Application]::DoEvents()
    Assert 'narrow AI view stacks cards without clipping' ($w.AICost.Top -ge $w.AITokens.Bottom -and $w.AICost.Right -le $w.AIStatHost.Width)
    $w.ClientSize=New-Object Drawing.Size 540,720;$w.Navigate('Energy')
    $w.AnalysisMode.SelectedIndex=0
    $w.Group.SelectedIndex=1;Assert 'range labels match weekly aggregation' ([string]$w.Range.Items[0] -eq '近 4 周');$w.Group.SelectedIndex=0
    $w.Theme.SelectedIndex=2;Assert 'dark theme updates chart and surfaces' ([ProfileTheme]::Dark -and $w.Tag.Chart.DarkMode -and $w.BackColor.GetBrightness() -lt 0.3)
    $standardBorder=$w.Ledger.CellBorderStyle;$standardCombo=$w.AISource.DrawMode;$standardTextBorder=$w.AISearch.BorderStyle
    $w.Skin.SelectedIndex=0;Assert 'liquid skin is global and persists independently from dark mode' ([ProfileSkin]::Liquid -and (Get-WorkspacePreferences).skin -eq 'Liquid' -and [ProfileTheme]::Dark -and $w.AITokens.Value.BackColor -eq [Drawing.Color]::Transparent)
    Assert 'liquid body keeps GDI controls on a readable opaque client area' ($w.Opacity -eq 1 -and $w.BackColor.A -eq 255)
    Assert 'charts and native tables participate in liquid styling' ($null -ne $w.Tag.Chart.BackgroundPainter -and $null -ne $w.Tag.AIChart.BackgroundPainter -and $w.Ledger.CellBorderStyle -eq 'SingleHorizontal' -and $w.AISource.DrawMode -eq 'OwnerDrawFixed')
    $popup=New-Object Windows.Forms.Form;Initialize-ModernForm $popup 'Skin fixture' 350 180
    $popupText=New-Object Windows.Forms.TextBox;$popupText.BorderStyle='None';$popup.Controls.Add($popupText)
    $popupCombo=New-Object Windows.Forms.ComboBox;$popupCombo.Top=40;$popup.Controls.Add($popupCombo)
    [ProfileTheme]::ApplyWindow($popup)
    $popupText.ForeColor=[Drawing.Color]::FromArgb(42,55,67);Assert 'dark skin keeps asynchronously refreshed text readable' ($popupText.ForeColor.GetBrightness() -ge 0.5)
    Assert 'secondary forms inherit active skin without changing input values' ($popupText.BorderStyle -eq 'FixedSingle' -and $popupCombo.DrawMode -eq 'OwnerDrawFixed' -and $popupText.Text -eq '')
    $w.Skin.SelectedIndex=1;[ProfileTheme]::ApplyWindow($popup)
    Assert 'standard skin restores original native controls and disables backdrop' (-not [ProfileSkin]::Liquid -and -not $w.GlassActive -and $w.Ledger.CellBorderStyle -eq $standardBorder -and $w.AISource.DrawMode -eq $standardCombo -and $w.AISearch.BorderStyle -eq $standardTextBorder -and $popupText.BorderStyle -eq 'None')
    $popup.Dispose();$w.Skin.SelectedIndex=2
    Assert 'classic header glass remains an independent skin option' ([ProfileSkin]::Kind -eq 'ClassicGlass' -and (Get-WorkspacePreferences).skin -eq 'ClassicGlass' -and $w.Glass.Enabled)
    $w.Skin.SelectedIndex=0;$w.Navigate('AI');$w.AIView.SelectedIndex=0
    $pixels=New-Object Drawing.Bitmap $w.Width,$w.Height;try{$w.DrawToBitmap($pixels,(New-Object Drawing.Rectangle 0,0,$pixels.Width,$pixels.Height));Assert 'liquid scene and charts render in the full portrait window' ($pixels.Width -gt 400 -and $w.AITokens.Value.Height -ge $w.AITokens.Value.Font.Height)}finally{$pixels.Dispose()}
    $w.Skin.SelectedIndex=1
    $viewPrefsHash=(Get-FileHash (Join-Path $root 'workspace.settings.json')).Hash
    Open-WorkspaceAIView 'Costs';Assert 'fixed fee view opens actual data without saving transient source selection' ($w.ActivePage -eq 'AI' -and $w.AISource.SelectedIndex -eq 2 -and $w.AIView.SelectedIndex -eq 1 -and $w.AIRange.SelectedIndex -eq 4)
    Open-WorkspaceAIView 'Combined';Assert 'fixed combined view opens token overlay without device actions' ($w.ActivePage -eq 'Energy' -and $w.Tag.Chart.AnalyticsMode -eq 1 -and $w.AISource.SelectedIndex -eq 2)
    Open-WorkspaceAIView 'Tokens';Assert 'fixed view navigation preserves saved appearance and filter preferences' ($w.ActivePage -eq 'AI' -and $w.AIView.SelectedIndex -eq 0 -and (Get-FileHash (Join-Path $root 'workspace.settings.json')).Hash -eq $viewPrefsHash -and -not $w.TopMost)
    $w.MetricOptions['game'].Checked=$false;Assert 'card preference persists separately' ((Get-WorkspacePreferences).metrics -notcontains 'game')
    $prefs=Get-WorkspacePreferences;$prefs.devices|Add-Member -NotePropertyName 'lamp' -NotePropertyValue ([PSCustomObject]@{alias='Desk lamp';room='Study';favorite=$true});Save-WorkspacePreferences $prefs
    $w.Navigate('Devices');Assert 'device cards replace raw device table' ($w.DeviceHost.Controls.Count -eq 2)
    $originalCard=$w.DeviceHost.Controls[0];$w.Tag.DeviceKey='';Update-ProfileWorkspace
    Assert 'device refresh reuses existing controls when identity is unchanged' ([object]::ReferenceEquals($originalCard,$w.DeviceHost.Controls[0]))
    Assert 'device hub uses two-column cards with individual confirmed-state toggles' ($originalCard -is [ProfileDeviceCard] -and $w.DeviceHost.MaximumColumns -eq 2 -and $originalCard.Toggle.State -eq $false -and $originalCard.Toggle.Enabled -and $w.DeviceSummary.Text -match '2 台设备')
    $w.ClientSize=New-Object Drawing.Size 420,600;[Windows.Forms.Application]::DoEvents();$w.DeviceHost.Reflow()
    Assert 'device cards remain two per row in the narrow portrait window' ($w.DeviceHost.Controls[0].Top -eq $w.DeviceHost.Controls[1].Top -and $w.DeviceHost.Controls[1].Right -le $w.DeviceHost.Width -and $originalCard.Toggle.Right -le $originalCard.Width -and $originalCard.Next.Bottom -lt $originalCard.Schedule.Top)
    $w.ClientSize=New-Object Drawing.Size 540,720
    $switchFixture=New-Object ProfileDeviceCard;$switchFixture.Show();$switchFixture.View=New-Object ProfileDeviceView;$switchFixture.View.Id='test';$switchFixture.View.Name='Fixture';$switchFixture.View.State=$false;$switchFixture.View.Online=$true;$switchFixture.View.CanControl=$true;$switchFixture.Update($switchFixture.View)
    $Script:fixtureDeviceAction='';$switchFixture.add_Command({param($sender,$eventArgs) $Script:fixtureDeviceAction=$eventArgs.Action});$switchFixture.Toggle.PerformClick()
    Assert 'card switch sends explicit intent without optimistic success or changing observed state' ($Script:fixtureDeviceAction -eq 'DeviceOn' -and $switchFixture.Toggle.State -eq $false)
    $switchFixture.View.Pending=$true;$switchFixture.Update($switchFixture.View);Assert 'pending device operations disable repeated toggles and show readback wait' (-not $switchFixture.Toggle.Enabled -and $switchFixture.Status.Text -match '等待读回')
    $switchFixture.View.Pending=$false;$switchFixture.View.State=$null;$switchFixture.View.Online=$false;$switchFixture.Update($switchFixture.View);Assert 'unknown device state is never presented as a confirmed off switch' (-not $switchFixture.Toggle.Enabled -and $null -eq $switchFixture.Toggle.State -and $switchFixture.Status.Text -match '未知')
    $switchFixture.Dispose()
    $w.Favorites.Checked=$true;Assert 'favorite filter and local alias work' ($w.DeviceHost.Controls.Count -eq 1 -and @($w.DeviceHost.Controls[0].Controls|Where-Object {$_.Text -like '*Desk lamp*'}).Count -eq 1)
    $w.Favorites.Checked=$false;$w.Room.SelectedItem='Study';Assert 'room filter works' ($w.DeviceHost.Controls.Count -eq 1)
    $w.Room.SelectedItem='全部分组';$w.Search.Text='cuco';Assert 'model search works' ($w.DeviceHost.Controls.Count -eq 1)
    $w.Search.Clear();$w.Navigate('Automation');Assert 'seven-day calendar and selected rules share one page' ($w.Calendar.Slots.Count -eq 7 -and $w.RuleGrid.Rows.Count -eq 1)
    $w.WeekOffset=1;$w.Tag.ScheduleKey='';Update-ProfileWorkspace;Assert 'calendar can advance a week' ($w.Calendar.WeekStart -gt $today)
    $monday=$today.AddDays(-(([int]$today.DayOfWeek+6)%7));$cross=[PSCustomObject]@{id='cross';name='Cross';did='lamp';model='light';enabled=$true;mode='guard';value=$false;days=@(1);startMinute=1380;endMinute=420}
    $plan=Get-WorkspaceSchedule ([PSCustomObject]@{enabled=$true;rules=@($cross)}) $null $monday $monday.AddHours(12)
    Assert 'cross-midnight projection carries into correct next day' ($plan.Slots[0].Start -eq $monday.AddHours(23) -and $plan.Slots[0].End -eq $monday.AddDays(1).AddHours(7))
    $dated=[PSCustomObject]@{id='dated';name='Once';did='lamp';enabled=$true;mode='at';value=$true;runAt=([DateTimeOffset]::Now.AddHours(1).ToString('o'))}
    $plan=Get-WorkspaceSchedule ([PSCustomObject]@{enabled=$true;rules=@($dated)}) ([PSCustomObject]@{dated=[PSCustomObject]@{completed=$true}}) $today $today
    Assert 'completed one-shot does not become an upcoming event' ($plan.Slots.Count -eq 0 -and $plan.Next.Count -eq 0)
    $wiz=Show-WorkspaceConnectionWizard -ReturnForm;$wiz.Show();[Windows.Forms.Application]::DoEvents()
    Assert 'wizard is five steps with save blocked until verified' ($wiz.Steps.TabPages.Count -eq 5 -and -not $wiz.SaveConnection.Enabled)
    $wiz.Token.Text=('a'*32);$wiz.Steps.SelectedIndex=2;$wiz.Verify.PerformClick();Assert 'network probe is asynchronous and does not save' ($null -ne $Script:fakeProbe -and -not $Script:fakeProbe.Completed -and $Script:fakeConfigureCount -eq 0)
    $Script:fakeProbe.Success=$true;$Script:fakeProbe.Completed=$true;Update-WorkspaceConnection $wiz;Assert 'successful actual-read validation unlocks save' $wiz.SaveConnection.Enabled
    $wiz.Address.Text='192.168.1.10';Assert 'changing inputs invalidates prior validation' (-not $wiz.SaveConnection.Enabled -and $null -eq $wiz.Tag.Probe)
    $wiz.Close();$wiz.Dispose()
    $w.Navigate('Overview');$w.ClientSize=New-Object Drawing.Size 420,600;[Windows.Forms.Application]::DoEvents()
    Assert 'compact window keeps cards within content and exposes vertical scroll' ($w.Metrics['mode'].Right -le $w.MetricHost.Width -and $w.Pages['Overview'].VerticalScroll.Visible)
    $section=$w.Sections['Runtime'];$w.Pages['Overview'].ScrollControlIntoView($section.Toggle);[Windows.Forms.Application]::DoEvents();$section.Toggle.PerformClick();[Windows.Forms.Application]::DoEvents()
    $runtimeRect=$w.Pages['Overview'].RectangleToClient($w.Runtime.RectangleToScreen($w.Runtime.ClientRectangle))
    Assert 'opening runtime near viewport bottom reveals actual status text' ($section.Expanded -and $w.Runtime.Text -match '插座' -and $runtimeRect.Top -ge 0 -and $runtimeRect.Bottom -le $w.Pages['Overview'].ClientSize.Height)
    $section.Toggle.PerformClick();$section.Toggle.PerformClick();$section.Toggle.PerformClick();[Windows.Forms.Application]::DoEvents()
    Assert 'queued reveal does not reopen a quickly collapsed section' (-not $section.Expanded -and -not $section.Body.Visible)
    $w.Navigate('Energy');$w.ShowSection('EnergyFilters');[Windows.Forms.Application]::DoEvents()
    Assert 'collapsed filters remain usable and expand within portrait content' ($w.Sections['EnergyFilters'].Expanded -and $w.Sections['EnergyFilters'].Height -gt 100 -and $w.LedgerSearch.Width -gt 100)
    $w.Navigate('Settings');$w.Motion.Checked=$false
    Assert 'motion preference persists and stops navigation animation' (-not (Get-WorkspacePreferences).motion -and -not $w.NavigationStrip.Animating)
    $w.Motion.Checked=$true;$w.Navigate('Energy')
    $watch=[Diagnostics.Stopwatch]::StartNew();while($watch.ElapsedMilliseconds -lt 240){[Windows.Forms.Application]::DoEvents();[Threading.Thread]::Sleep(10)}
    Assert 'navigation animation finishes without a permanent timer' (-not $w.NavigationStrip.Animating)
    $w.Navigate('Settings');$w.TextSize.SelectedIndex=1;$w=$Script:Workspace;$w.Tag.Timer.Stop();[Windows.Forms.Application]::DoEvents()
    Assert 'text scaling persists and increases readable metric typography' ((Get-WorkspacePreferences).textScale -eq 125 -and $w.Metrics['mode'].Value.Font.Size -gt 22)
    $w.Navigate('Overview');$w.Pages['Overview'].ScrollControlIntoView($w.Sections['Runtime'].Toggle);$w.Sections['Runtime'].Toggle.PerformClick();[Windows.Forms.Application]::DoEvents()
    $runtimeRect=$w.Pages['Overview'].RectangleToClient($w.Runtime.RectangleToScreen($w.Runtime.ClientRectangle))
    Assert 'runtime remains reachable after font scaling and background refresh' ($w.Runtime.Visible -and $runtimeRect.Top -ge 0 -and $runtimeRect.Top -lt $w.Pages['Overview'].ClientSize.Height)
    $w.Dispose();$w=Show-ProfileWorkspace -ReturnForm;$w.Tag.Timer.Stop();Assert 'appearance and card preferences survive reopening' ([ProfileTheme]::Dark -and -not $w.MetricOptions['game'].Checked -and $w.TextSize.SelectedIndex -eq 1)
    Assert 'UI actions preserve core settings and existing task configuration' ((Get-FileHash $SettingsPath).Hash -eq $settingsHash -and (Get-FileHash (Join-Path $root 'devices.hub.json')).Hash -eq $hubHash)
    $w.Tag.DeferModels=$true;$w.Tag.ModelSignature='';$w.Navigate('Energy');$deadline=[Diagnostics.Stopwatch]::StartNew();while($w.Tag.ModelJob -and $deadline.ElapsedMilliseconds -lt 10000){[Windows.Forms.Application]::DoEvents();[Threading.Thread]::Sleep(10)}
    Assert 'background model preparation preserves chart values and usable rows' ($w.Tag.ModelReady['Energy'] -and $w.Tag.EnergyData.Rows.Count -gt 0 -and @($w.Tag.Chart.Periods|Where-Object {$null -ne $_.Cost}).Count -gt 0)
    $w.Navigate('Games');$w.Navigate('Overview');$deadline.Restart();while($w.Tag.ModelJob -and $deadline.ElapsedMilliseconds -lt 10000){[Windows.Forms.Application]::DoEvents();[Threading.Thread]::Sleep(10)}
    Assert 'finished background work never navigates away from the chosen page' ($w.ActivePage -eq 'Overview' -and -not $w.Tag.ModelJob)
    Assert 'navigation and visual settings never enqueue physical operations' (-not(Test-Path (Join-Path $hubDir 'queue')))
    Assert 'fixture workspaces never launch the real personal AI collector' (-not (Test-Path (Join-Path $root 'ai.usage.db')))
    $w.Dispose()
}finally{
    if($Script:Workspace){$Script:Workspace.Dispose()};if($Script:EnergyService){$Script:EnergyService.Dispose()};if($Script:EnergyLogTimer){$Script:EnergyLogTimer.Dispose()};if($Script:DeviceHubTick){$Script:DeviceHubTick.Dispose()}
    if(-not ([IO.Path]::GetFullPath($root)).StartsWith(([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\ProfileWorkspaceTests-'),[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected cleanup path'}
    Remove-Item -LiteralPath $root -Recurse -Force
}
