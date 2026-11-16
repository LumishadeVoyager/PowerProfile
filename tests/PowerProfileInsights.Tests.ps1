$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$project=Split-Path -Parent $PSScriptRoot
$root=Join-Path $env:TEMP ('ProfileInsightsTests-'+[Guid]::NewGuid());[void][IO.Directory]::CreateDirectory($root)
$ScriptDir=$root
function Assert($Name,$Value){if(-not $Value){throw $Name};Write-Host "PASS $Name"}
try{
    . (Join-Path $project 'PowerProfileEnergyUI.ps1');Initialize-EnergyService;$Script:EnergyService.Dispose();$Script:EnergyLogTimer.Stop()
    Add-Type -Path @((Join-Path $project 'PowerProfileWorkspace.cs'),(Join-Path $project 'PowerProfileCards.cs'),(Join-Path $project 'PowerProfileSkin.cs'),(Join-Path $project 'PowerProfileInsightsUI.cs')) -ReferencedAssemblies System.Drawing,System.Windows.Forms,System.Core
    . (Join-Path $project 'PowerProfileWorkspaceData.ps1');. (Join-Path $project 'PowerProfileWorkspaceAsync.ps1');. (Join-Path $project 'PowerProfileInsights.ps1')
    $state=New-Object ProfileEnergySnapshot;$state.LocalDay='2026-11-15';$state.Price=[decimal]0.7
    foreach($entry in @(@('2026-11-15',100),@('2026-11-14',0),@('2026-11-13',3600),@('2026-11-06',7200))){$u=New-Object ProfileEnergyDay;$u.Seconds=$entry[1];$u.GameSeconds=0;$u.HighPowerSeconds=0;$state.UsageDays.Add($entry[0],$u);$d=New-Object ProfileEnergyDay;$d.KWh=$entry[1]/3600;$d.Source='MiHome';$state.Days.Add($entry[0],$d)}
    $data=Get-WorkspaceEnergyData $state Day 7
    Assert 'real zero remains numeric while absent daily data stays null' ($data.Rows[1].UsageSeconds -eq 0 -and $null -eq $data.Rows[3].UsageSeconds -and $data.Rows[1].Energy -eq '0.000')
    $sorted=@(Sort-InsightsRows $data.Rows 3 $true)
    Assert 'numeric descending sorts duration and leaves missing last' ($sorted[0].UsageSeconds -eq 3600 -and $sorted[1].UsageSeconds -eq 100 -and $null -eq $sorted[-1].UsageSeconds)
    $sorted=@(Sort-InsightsRows $data.Rows 3 $false)
    Assert 'numeric ascending retains valid zero before known values' ($sorted[0].UsageSeconds -eq 0 -and $null -eq $sorted[-1].UsageSeconds)
    $range=Get-WorkspaceEnergyData $state Week 1 ([DateTime]'2026-11-13') ([DateTime]'2026-11-15') 2
    Assert 'weekend filtering precedes weekly aggregation' ($range.Rows[0].UsageSeconds -eq 100 -and $range.Rows[0].Date -match '周一.*周日')
    $mean=Get-InsightsMean $data.Rows 0 2
    Assert 'means include known zero and count missing separately' ($mean.Value -eq 50 -and $mean.Known -eq 2 -and $mean.Missing -eq 0)
    $comparison=Get-InsightsComparison $state ([DateTime]'2026-11-09') ([DateTime]'2026-11-15') 0
    Assert 'comparison excludes incomplete today and shifts equal closed interval' ($comparison -like '*2026-11-14*' -and $comparison -like '*2026-11-03*' -and $comparison -like '*2026-11-08*' -and $comparison -like '*有记录*')
    Assert 'search and source filter can find missing rows' (@(Select-InsightsRows $data.Rows '11-12' 3 0).Count -eq 1)
    $at=[DateTime]::Parse('2026-11-14T10:00:00Z').ToUniversalTime()
    function NewGamePoint($Time,$Mode,$Name,$Game){$p=New-Object ProfileUsageLogPoint;$p.Time=$Time;$p.Mode=$Mode;$p.GameName=$Name;$p.Game=$Game;$p.Decision=$true;return $p}
    $points=New-Object 'Collections.Generic.List[ProfileUsageLogPoint]';$power=New-Object 'Collections.Generic.List[ProfileUsagePowerEvent]'
    $points.Add((NewGamePoint $at Game 'NBA 2K26' $true));$points.Add((NewGamePoint $at Game 'NBA 2K26' $true));$points.Add((NewGamePoint $at.AddHours(2) Idle $null $false))
    $sessions=[ProfileGameSessionStore]::Build($points,$power,$at.AddHours(2))
    Assert 'duplicate mode logs rebuild one named two-hour session' ($sessions.Count -eq 1 -and $sessions[0].Seconds -eq 7200 -and $sessions[0].Estimated)
    $store=New-Object ProfileGameSessionStore $root;$store.Refresh($points,$power,$at.AddHours(2))
    $down=New-Object ProfileUsagePowerEvent;$down.Time=$at.AddMinutes(30);$power.Add($down);$up=New-Object ProfileUsagePowerEvent;$up.Time=$at.AddMinutes(90);$up.Awake=$true;$power.Add($up)
    $store.Refresh($points,$power,$at.AddHours(2));$store.Refresh($points,$power,$at.AddHours(2))
    Assert 'new sleep evidence splits old cache and repeated refresh does not rejoin it' ($store.Sessions.Count -eq 2 -and ($store.Sessions|Measure-Object Seconds -Sum).Sum -eq 3600)
    $samples=New-Object 'Collections.Generic.List[ProfileEnergyPoint]'
    for($i=0;$i -le 30;$i++){$p=New-Object ProfileEnergyPoint;$p.Time=$at.AddMinutes($i);$p.Watts=200;$samples.Add($p)}
    $store.UpdateSamples($samples);$store.UpdateSamples($samples)
    Assert 'sample integration is idempotent and never fills unsampled session' ($store.Sessions[0].SampledSeconds -eq 1800 -and [Math]::Abs($store.Sessions[0].SampledKWh-0.1) -lt 0.000001 -and $null -eq $store.Sessions[1].SampledKWh)
    $reloaded=New-Object ProfileGameSessionStore $root;$samples.Clear();$reloaded.UpdateSamples($samples)
    Assert 'metered game coverage survives restart and rolling raw-point removal' ($reloaded.Sessions.Count -eq 2 -and [Math]::Abs($reloaded.Sessions[0].AverageWatts-200) -lt 0.000001)
    $state.GameSessions=$reloaded.Sessions;$games=@(Get-WorkspaceGameRows $state ([DateTime]'2026-11-14') ([DateTime]'2026-11-15'))
    Assert 'session cost uses sampled energy and current tariff with unknown preserved' (@($games|Where-Object {$null -ne $_.Cost}).Count -eq 1 -and [Math]::Abs(($games|Where-Object {$null -ne $_.Cost}).Cost-0.07) -lt 0.000001)
    $points.Clear();$power.Clear();$points.Add((NewGamePoint $at Game $null $null));$points.Add((NewGamePoint $at.AddHours(1) Idle $null $false))
    Assert 'manual Game without evidence is excluded' ([ProfileGameSessionStore]::Build($points,$power,$at.AddHours(1)).Count -eq 0)
    $points.Clear();$points.Add((NewGamePoint $at Game 'NBA 2K26' $true));$points.Add((NewGamePoint $at.AddHours(1) Game 'Other game' $true));$points.Add((NewGamePoint $at.AddHours(2) Idle $null $false))
    $multi=[ProfileGameSessionStore]::Build($points,$power,$at.AddHours(2));Assert 'game change splits names with no double counting' ($multi.Count -eq 2 -and ($multi|Measure-Object Seconds -Sum).Sum -eq 7200)
    $points.Clear();$points.Add((NewGamePoint $at Game 'NBA 2K26' $true));Assert 'historical unclosed session has no invented tail' ([ProfileGameSessionStore]::Build($points,$power,$at.AddDays(2)).Count -eq 0)
    $points.Add((NewGamePoint $at.AddSeconds(60) Game 'NBA 2K26' $true));$live=[ProfileGameSessionStore]::Build($points,$power,$at.AddSeconds(70));Assert 'live session stops at last observation rather than current clock' ($live.Count -eq 1 -and $live[0].Seconds -eq 60 -and $live[0].Open)
    $points.Clear();$points.Add((NewGamePoint $at Game 'NBA 2K26' $true));$points.Add((NewGamePoint $at.AddDays(2) Idle $null $false));Assert 'implausible multiday awake interval is rejected' ([ProfileGameSessionStore]::Build($points,$power,$at.AddDays(2)).Count -eq 0)
    $gapRoot=Join-Path $root 'gap';[void][IO.Directory]::CreateDirectory($gapRoot);$gapped=New-Object ProfileGameSessionStore $gapRoot;$points.Clear();$points.Add((NewGamePoint $at Game 'NBA 2K26' $true));$points.Add((NewGamePoint $at.AddMinutes(10) Idle $null $false));$gapped.Refresh($points,$power,$at.AddMinutes(10));$samples.Clear();foreach($minute in @(0,1,5,6)){$p=New-Object ProfileEnergyPoint;$p.Time=$at.AddMinutes($minute);$p.Watts=200;$samples.Add($p)};$samples[3].BreakBefore=$true;$gapped.UpdateSamples($samples)
    Assert 'sample gaps and break markers never become measured game cost' ($gapped.Sessions[0].SampledSeconds -eq 60)
    $rr=New-Object 'Collections.Generic.List[string[]]';$rr.Add([string[]]@(' =SUM(1,2)','中文,"引号"',"多行`n内容",'<script>x</script>'))
    $csv=[ProfileAnalyticsExport]::Csv([string[]]@('a','b','c','d'),$rr);$csvPath=Join-Path $root 'test.csv';[ProfileAnalyticsExport]::WriteText($csvPath,$csv)
    Assert 'CSV quotes formulas and retains Chinese and multiline values' ($csv.Contains("' =SUM(1,2)") -and $csv.Contains('""引号""') -and [IO.File]::ReadAllText($csvPath).Contains("多行`n内容") -and [IO.File]::ReadAllBytes($csvPath)[0] -eq 239)
    $html=[ProfileAnalyticsExport]::Report('Report','Scope','Summary',[string[]]@('<name>'),$rr)
    Assert 'offline report escapes log-controlled HTML' ($html.Contains('&lt;script&gt;x&lt;/script&gt;') -and -not $html.Contains('<script>'))
    $w=New-Object ProfileWorkspaceForm;$Script:Workspace=$w;$w.Tag=@{Suppress=$true;GameRows=$games;SessionDetails=@{}};$w.Show();$w.Navigate('Energy');[Windows.Forms.Application]::DoEvents()
    $hoverTip=New-Object ProfileHoverTip $w.Insights.Heatmap
    Assert 'new hover target registers a tooltip once' ($hoverTip.Update('2026-11-14 sample'))
    $retargeted=0;for($i=0;$i -lt 200;$i++){if($hoverTip.Update('2026-11-14 sample')){$retargeted++}}
    Assert 'motion inside the same target never re-registers tooltip' ($retargeted -eq 0)
    $hoverTip.Clear();Assert 'leaving and reentering a target can show tooltip again' ($hoverTip.Update('2026-11-14 sample'))
    $w.Insights.Heatmap.Hide();Assert 'hidden controls do not retain active tooltip text' (-not $hoverTip.Update('2026-11-14 sample'));$w.Insights.Heatmap.Show();$hoverTip.Dispose()
    Assert 'portrait ledger initially prioritizes date and main metrics' ($w.Ledger.Columns[0].Visible -and $w.Ledger.Columns[2].Visible -and -not $w.Ledger.Columns[6].Visible)
    $w.SetLedger($data.Rows.ToArray());foreach($column in $w.Ledger.Columns){$column.Visible=$true};$w.Ledger.Columns[2].Visible=$false;$table=Get-InsightsExportTable $w.Ledger
    Assert 'export uses current visible columns and displayed row order' ($table.Headers.Count -eq $w.Ledger.Columns.Count-1 -and $table.Headers -notcontains '电费' -and $table.Rows[0][0] -eq $data.Rows[0].Date)
    $heat=New-Object 'Collections.Generic.List[ProfileHeatDay]';foreach($r in $data.Rows){$h=New-Object ProfileHeatDay;$h.Date=$r.PeriodStart;$h.Value=$r.UsageSeconds;$heat.Add($h)};$w.Insights.Heatmap.Days=$heat;$w.Insights.Heatmap.Fit()
    $png=Join-Path $root 'chart.png';[ProfileAnalyticsExport]::SaveChart($w.Insights.Heatmap,$png,'Test','Missing is unknown');$bitmap=[Drawing.Image]::FromFile($png);try{Assert 'chart export produces an actual PNG with readable header and caption' ($bitmap.Width -eq $w.Insights.Heatmap.Width+48 -and $bitmap.Height -eq $w.Insights.Heatmap.Height+150)}finally{$bitmap.Dispose()}
    $heat[0].Detail="1 小时`r`nLong coverage explanation";$flags=[Reflection.BindingFlags]'Instance,NonPublic';$heatControl=$w.Insights.Heatmap;$box=$heatControl.GetType().GetField('hit',$flags).GetValue($heatControl)[0].Item1
    $move=$heatControl.GetType().GetMethod('OnMouseMove',$flags);$leave=$heatControl.GetType().GetMethod('OnMouseLeave',$flags)
    for($i=0;$i -lt 20;$i++){$arg=New-Object Windows.Forms.MouseEventArgs None,0,($box.X+1+$i%3),($box.Y+1),0;[void]$move.Invoke($heatControl,[object[]]@($arg.PSObject.BaseObject))}
    $heatTip=$heatControl.GetType().GetField('tip',$flags).GetValue($heatControl);$current=$heatTip.GetType().GetField('current',$flags).GetValue($heatTip)
    Assert 'heatmap hover keeps concise dated value instead of a giant moving popup' ($current -match '周' -and $current -match '1 小时' -and $current -notmatch 'Long coverage' -and -not $heatTip.Update($current))
    [void]$leave.Invoke($heatControl,[object[]]@([EventArgs]::Empty));Assert 'heatmap mouse leave removes the old date popup' ($heatTip.GetType().GetField('current',$flags).GetValue($heatTip) -eq '')
    $w.ClientSize=New-Object Drawing.Size 720,640;[Windows.Forms.Application]::DoEvents();Assert 'heatmap reflows within compact content width' ($w.Insights.Heatmap.Right -le $w.Insights.Width)
    Set-WorkspaceGameSessions $games;Assert 'session table keeps unknown sampled cost visible' ($w.GameSessions.Rows.Count -eq 2 -and @($w.GameSessions.Rows|Where-Object {$_.Cells[6].Value -eq '未采集'}).Count -eq 1)
    $chart=New-Object ProfileInteractiveTimeline;Assert 'clearing inactive tooltips does not create hidden chart handles' (-not $chart.IsHandleCreated);$chart.Dock='Fill';$w.ChartHost.Controls.Add($chart);$w.Tag.Chart=$chart;$w.Tag.SortColumn=0;$w.Tag.SortDescending=$true
    Update-WorkspaceInsights $state Day 7
    Assert 'heatmap includes every date in selected interval' ($w.Insights.Heatmap.Days.Count -eq 7 -and $chart.Periods.Count -eq 7)
    $w.SourceFilter.SelectedIndex=3;Update-WorkspaceInsights $state Day 7
    Assert 'filtered dates become curve gaps without removing calendar positions' ($w.Ledger.Rows.Count -eq 4 -and $chart.Periods.Count -eq 7 -and @($chart.Periods|Where-Object {$null -ne $_.Cost}).Count -eq 0)
    function Update-ProfileWorkspace{Update-WorkspaceInsights $state Day 7}
    [void](Invoke-InsightsCommand HeatDate '2026-11-13')
    Assert 'calendar click restores day context and clears excluding filters' ($w.CustomDates.Checked -and $w.FromDate.Value.Date -eq [DateTime]'2026-11-13' -and $w.ToDate.Value.Date -eq [DateTime]'2026-11-13' -and $w.SourceFilter.SelectedIndex -eq 0 -and $w.Ledger.Rows.Count -eq 1)
    Update-WorkspaceGames $state
    Assert 'independent game aggregates and sessions share measured coverage' ($w.GameTotals.Rows.Count -eq 1 -and $w.GameSessions.Rows.Count -eq 2 -and $w.GameTotals.Rows[0].Cells[4].Value -eq '200.0')
    Assert 'games are cover cards with original totals available on demand' ($w.GameHost.Controls.Count -eq 1 -and $w.GameHost.Controls[0] -is [ProfileGameCard] -and $w.GameHost.Controls[0].View.Name -eq 'NBA 2K26' -and -not $w.Sections['GameTable'].Expanded)
    $originalGame=$w.GameHost.Controls[0];Update-WorkspaceGames $state;Assert 'game refresh reuses artwork cards and preserves statistics' ([object]::ReferenceEquals($originalGame,$w.GameHost.Controls[0]) -and $w.GameHost.Controls[0].View.Sessions -eq 2)
    $w.SelectGame('NBA 2K26',$true);Assert 'selecting a game highlights its card and reveals sessions' ($w.SelectedGame -eq 'NBA 2K26' -and $w.GameHost.Controls[0].Selected -and $w.Sections['GameSessions'].Expanded)
    $steamFixture=Join-Path $root 'steam';[void][IO.Directory]::CreateDirectory((Join-Path $steamFixture 'steamapps'))
    [IO.File]::WriteAllText((Join-Path $steamFixture 'steamapps/appmanifest_1.acf'),'"AppState" { "appid" "12345" "name" "NBA 2K26" }')
    [IO.File]::WriteAllText((Join-Path $steamFixture 'steamapps/appmanifest_2.acf'),'"AppState" { "appid" "../invalid" "name" "Other game" }')
    $catalog=[ProfileSteamArtwork]::ReadInstalled([string[]]@($steamFixture));Assert 'Steam cover mapping uses exact local manifests and rejects invalid app IDs' ($catalog.Count -eq 1 -and $catalog['nba2k26'].AppId -eq '12345' -and -not $catalog.ContainsKey('othergame'))
    $header=[ProfileSteamArtwork]::HeaderUrl('{"header_image":"https:\/\/shared.akamai.steamstatic.com\/store_item_assets\/steam\/apps\/12345\/hash\/header_schinese.jpg"}','12345');Assert 'hashed localized Steam covers resolve from public app metadata' ($header -eq 'https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/12345/hash/header_schinese.jpg')
    $rejected=$false;try{[void][ProfileSteamArtwork]::HeaderUrl('{"header_image":"https://unrelated.example/steam/apps/12345/header.jpg"}','12345')}catch{$rejected=$true};Assert 'artwork metadata cannot redirect downloads to arbitrary hosts' $rejected
    $library=New-Object 'Collections.Generic.List[ProfileGameView]';for($i=0;$i -lt 8;$i++){$v=New-Object ProfileGameView;$v.Name='Fixture game '+$i;$v.Duration='1 小时';$v.Recent='最近 2026-11-14 周六';$library.Add($v)}
    $w.Navigate('Games');$w.SetGameCards($library.ToArray());Assert 'large game libraries start with six cards and can expand without losing totals' ($w.GameHost.Controls.Count -eq 6 -and $w.GameLibraryMore.Visible -and $w.GameHost.Controls[0].CanSelect)
    $firstCard=$w.GameHost.Controls[0];$w.GameLibraryMore.PerformClick();Assert 'expanding library reuses existing cards and shows the remaining games' ($w.GameHost.Controls.Count -eq 8 -and [object]::ReferenceEquals($firstCard,$w.GameHost.Controls[0]))
}finally{
    if($w){$w.Dispose()};if($Script:EnergyService){$Script:EnergyService.Dispose()};if($Script:EnergyLogTimer){$Script:EnergyLogTimer.Dispose()}
    if(-not ([IO.Path]::GetFullPath($root)).StartsWith(([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\ProfileInsightsTests-'),[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected cleanup path'}
    Remove-Item -LiteralPath $root -Recurse -Force
}
