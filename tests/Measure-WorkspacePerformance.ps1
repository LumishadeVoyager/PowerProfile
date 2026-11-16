param([string]$Source=(Split-Path -Parent $PSScriptRoot),[ValidateRange(10,300)][int]$Samples=60,[string]$Output)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$project=[IO.Path]::GetFullPath($Source);$ScriptDir=$project
$fixtureRoot=Join-Path $env:TEMP ('PowerProfilePerf-'+[Guid]::NewGuid());[void][IO.Directory]::CreateDirectory($fixtureRoot)
$SettingsPath=Join-Path $fixtureRoot 'settings.json';Copy-Item (Join-Path $project 'settings.example.json') $SettingsPath
function Get-CurrentMode{return 'Idle'}
function Get-AutoEnabled{return $true}
function Read-GameDetectionState{return @{Fresh=$false}}
function Stats($values){$sorted=@($values|Sort-Object);return @{medianMs=$sorted[[int]($sorted.Count/2)];p95Ms=$sorted[[Math]::Min($sorted.Count-1,[int][Math]::Ceiling($sorted.Count*.95)-1)];maxMs=$sorted[-1]}}
try{
    . (Join-Path $project 'PowerProfileModernUI.ps1');$Script:EnergyService.Dispose();$Script:EnergyLogTimer.Stop();function Start-DeviceHubWorker{}
    $Script:perfState=New-Object ProfileEnergySnapshot;$today=[TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow,[TimeZoneInfo]::FindSystemTimeZoneById('China Standard Time')).Date
    $Script:perfState.LocalDay=$today.ToString('yyyy-MM-dd');$Script:perfState.WeekStart=$today.AddDays(-(([int]$today.DayOfWeek+6)%7)).ToString('yyyy-MM-dd');$Script:perfState.MonthStart=$today.ToString('yyyy-MM')+'-01';$Script:perfState.Price=[decimal]0.7;$Script:perfState.UsageUpdatedAt=[DateTime]::UtcNow
    for($i=0;$i -lt 400;$i++){$game=New-Object ProfileGameSession;$game.Id='fixture-'+$i;$game.Name='Fixture game '+($i%8);$game.Start=$today.AddDays(-1-[int][Math]::Floor($i/16)).AddHours($i%16).ToUniversalTime();$game.End=$game.Start.AddMinutes(30);$game.Source='fixture';$Script:perfState.GameSessions.Add($game)}
    $service=[PSCustomObject]@{};$service|Add-Member ScriptMethod GetSnapshot {return $Script:perfState};$service|Add-Member ScriptMethod Dispose {};$service|Add-Member ScriptMethod Refresh {};$Script:EnergyService=$service
    $w=Show-ProfileWorkspace -ReturnForm;$w.Tag.Timer.Stop();$w.Skin.SelectedIndex=0;$w.Motion.Checked=$false;$w.Show();$w.Navigate('Games');$w.GameRange.SelectedIndex=3;Update-ProfileWorkspace;$w.Tag.Suppress=$true
    $bitmap=New-Object Drawing.Bitmap $w.Width,$w.Height;$rect=New-Object Drawing.Rectangle 0,0,$bitmap.Width,$bitmap.Height
    for($i=0;$i -lt 4;$i++){$w.Navigate('Settings');$w.Navigate('Games');$w.DrawToBitmap($bitmap,$rect)}
    $navigation=@();$render=@();$scroll=@()
    for($i=0;$i -lt $Samples;$i++){
        $sw=[Diagnostics.Stopwatch]::StartNew();$w.Navigate('Settings');$navigation+=$sw.Elapsed.TotalMilliseconds
        $sw.Restart();$w.Navigate('Games');$navigation+=$sw.Elapsed.TotalMilliseconds
        $sw.Restart();$w.DrawToBitmap($bitmap,$rect);$render+=$sw.Elapsed.TotalMilliseconds
        $w.Pages['Games'].AutoScrollPosition=New-Object Drawing.Point 0,(($i%9)*50);$sw.Restart();$w.DrawToBitmap($bitmap,$rect);$scroll+=$sw.Elapsed.TotalMilliseconds
    }
    $report=@{workload='400 synthetic sessions / 8 games / 400 calendar days';samples=$Samples;navigation=(Stats $navigation);offscreenFrame=(Stats $render);scrolledOffscreenFrame=(Stats $scroll);frameBudgetMs=25;note='Warm UI-thread and offscreen raster timings, not measured monitor presentation FPS. No physical power or device operations.'}
    $json=$report|ConvertTo-Json -Depth 5;if($Output){[IO.File]::WriteAllText([IO.Path]::GetFullPath($Output),$json,[Text.UTF8Encoding]::new($false))};$json
}finally{
    if($bitmap){$bitmap.Dispose()};if($w){$w.Dispose()};if($Script:EnergyService){$Script:EnergyService.Dispose()};if($Script:EnergyLogTimer){$Script:EnergyLogTimer.Dispose()}
    if(([IO.Path]::GetFullPath($fixtureRoot)).StartsWith(([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\PowerProfilePerf-'),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $fixtureRoot -Recurse -Force}
}
