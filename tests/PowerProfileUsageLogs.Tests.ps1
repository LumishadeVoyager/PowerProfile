$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$project=Split-Path -Parent $PSScriptRoot
$root=Join-Path $env:TEMP ('PowerProfileUsageTests-'+[Guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($root)
$ScriptDir=$root
. (Join-Path $project 'PowerProfileEnergyUI.ps1')
function Assert($Name,$Value){if(-not $Value){throw $Name};Write-Host "PASS $Name"}
try{
    Initialize-EnergyService;$Script:EnergyService.Dispose()
    $at=[DateTime]::Parse('2026-11-13T15:59:30Z').ToUniversalTime()
    function Point($Time,$Game,$Decision=$true){$p=New-Object ProfileUsageLogPoint;$p.Time=$Time;$p.Game=$Game;$p.Decision=$Decision;return $p}
    $points=New-Object 'Collections.Generic.List[ProfileUsageLogPoint]'
    $points.Add((Point $at $true));$points.Add((Point $at.AddSeconds(60) $true));$points.Add((Point $at.AddSeconds(60) $true))
    $boundaries=New-Object 'Collections.Generic.List[DateTime]'
    $days=[ProfileUsageLogReader]::Build($points,$boundaries,$at.AddSeconds(120))
    Assert 'duplicate log records do not inflate usage or game duration' ($days['2026-11-13'].Seconds -eq 30 -and $days['2026-11-14'].Seconds -eq 30 -and $days['2026-11-14'].GameSeconds -eq 30)
    $boundaries.Add($at.AddSeconds(20));$sleep=[ProfileUsageLogReader]::Build($points,$boundaries,$at.AddSeconds(120))
    Assert 'known suspend boundary breaks the interval even for a short sleep' ($sleep.Count -eq 0)
    $boundaries.Clear();$points.Clear();$points.Add((Point $at $true));$points.Add((Point $at.AddSeconds(600) $true))
    Assert 'long log gaps never inherit a held game mode' ([ProfileUsageLogReader]::Build($points,$boundaries,$at.AddSeconds(600)).Count -eq 0)
    $points.Clear();$points.Add((Point $at $true));$points.Add((Point $at.AddSeconds(30) $null));$points.Add((Point $at.AddSeconds(60) $true))
    $unknown=[ProfileUsageLogReader]::Build($points,$boundaries,$at.AddSeconds(120))
    Assert 'awake usage survives unknown game classification without invented game hours' ($unknown['2026-11-13'].Seconds -eq 30 -and $null -eq $unknown['2026-11-13'].GameSeconds)
    $manual=[ProfileUsageLogReader]::ParseLegacy('2026-11-13 23:59:30  switched to Game (Boost=2) Reason: 用户手动选择')
    Assert 'manual Game mode is not evidence of gaming' ($null -eq $manual.Game)
    $record=@{timestamp=$at.ToString('o');event='auto.decision';data=@{source='NoGameSignal';after='Game'}}|ConvertTo-Json -Compress
    Assert 'exit debounce held in Game is classified from detector evidence' ([ProfileUsageLogReader]::ParseRecord($record).Game -eq $false)
    Assert 'malformed log line is skipped' ($null -eq [ProfileUsageLogReader]::ParseRecord('broken'))
    $sessions=New-Object 'Collections.Generic.List[ProfileUsageLogPoint]'
    $enter=[ProfileUsageLogReader]::ParseLegacy('2026-11-13 23:30:00  switched to Game (Boost=2) Reason: 单核瓶颈: topGPU=NBA2K26.exe pid=12')
    $exit=[ProfileUsageLogReader]::ParseLegacy('2026-11-14 01:30:00  switched to Idle (Boost=0) Reason: 无已确认游戏')
    $sessions.Add($enter);$sessions.Add($exit)
    $power=New-Object 'Collections.Generic.List[ProfileUsagePowerEvent]'
    $modeDays=[ProfileUsageLogReader]::BuildSessions($sessions,$power,$exit.Time)
    Assert 'paired NBA mode changes rebuild a two-hour session across long log gaps' ($modeDays['2026-11-13'].GameSeconds -eq 1800 -and $modeDays['2026-11-14'].GameSeconds -eq 5400)
    Assert 'game-mode high-power estimate is separately attributed' ($modeDays['2026-11-14'].ModeGameSeconds -eq 5400 -and $null -eq $modeDays['2026-11-14'].HighPowerSeconds -and $modeDays['2026-11-14'].GameNames -eq 'NBA 2K26')
    $down=New-Object ProfileUsagePowerEvent;$down.Time=$enter.Time.AddMinutes(30);$down.Awake=$false;$power.Add($down)
    $up=New-Object ProfileUsagePowerEvent;$up.Time=$enter.Time.AddMinutes(90);$up.Awake=$true;$power.Add($up)
    $awakeDays=[ProfileUsageLogReader]::BuildSessions($sessions,$power,$exit.Time)
    Assert 'sleep within a long game session is subtracted rather than counted' ($awakeDays['2026-11-13'].GameSeconds -eq 1800 -and $awakeDays['2026-11-14'].GameSeconds -eq 1800)
    $report='<EventData><Data Name="SleepTime">2026-11-13T16:00:00Z</Data><Data Name="WakeTime">2026-11-13T17:00:00Z</Data></EventData>'
    $exact=[ProfileUsageLogReader]::ParseSleepReport($report);$power.Clear();foreach($p in $exact){$power.Add($p)}
    $earlyWake=New-Object ProfileUsagePowerEvent;$earlyWake.Time=$enter.Time.AddMinutes(31);$earlyWake.Awake=$true;$power.Add($earlyWake)
    $precise=[ProfileUsageLogReader]::BuildSessions($sessions,$power,$exit.Time)
    Assert 'explicit sleep/wake payload wins over misleading early resume timestamps' ($precise['2026-11-14'].ModeGameSeconds -eq 1800)
    $sessions.Add($enter);$dedup=[ProfileUsageLogReader]::BuildSessions($sessions,$power,$exit.Time)
    Assert 'duplicated mode records do not duplicate reconstructed sessions' ($dedup['2026-11-14'].ModeGameSeconds -eq 1800)
    $sessions.Clear();$sessions.Add($enter)
    Assert 'unclosed historical session is not extended indefinitely' ([ProfileUsageLogReader]::BuildSessions($sessions,$power,$enter.Time.AddDays(3)).Count -eq 0)
    $library=[ProfileUsageLogReader]::ParseLegacy('2026-11-13 23:30:00  switched to Game (Boost=2) Reason: LibraryGame [start_protected_game.exe pid=12] library=NBA 2K26; CPU=25%')
    Assert 'library identity is retained for protected NBA launchers' ($library.GameName -eq 'NBA 2K26')
    $usage=New-Object 'Collections.Generic.Dictionary[string,ProfileEnergyDay]'
    $sample=New-Object ProfileEnergyDay;$sample.Seconds=120;$sample.HighPowerSeconds=60;$sample.HighPowerCoverageSeconds=120;$usage['2026-11-14']=$sample
    $cache=New-Object ProfileUsageLogCache;$cache.Days=New-Object 'Collections.Generic.Dictionary[string,ProfileEnergyDay]'
    $logged=New-Object ProfileEnergyDay;$logged.Seconds=180;$logged.GameSeconds=90;$logged.GameCoverageSeconds=180;$cache.Days['2026-11-14']=$logged
    [ProfileUsageLogReader]::Merge($usage,$cache);[ProfileUsageLogReader]::Merge($usage,$cache)
    Assert 'log and sample totals are not double counted on repeated merge' ($usage['2026-11-14'].Seconds -eq 180 -and $usage['2026-11-14'].GameSeconds -eq 90)
    Assert 'high-power counters retain their original metered coverage' ($usage['2026-11-14'].HighPowerSeconds -eq 60 -and $usage['2026-11-14'].HighPowerCoverageSeconds -eq 120)
    $logDir=Join-Path $root 'logs';[void][IO.Directory]::CreateDirectory($logDir)
    $file=Join-Path $logDir 'PowerProfile-2026-11-14.jsonl'
    $record1=@{timestamp=$at.ToString('o');event='auto.decision';data=@{source='LibraryGame'}}|ConvertTo-Json -Compress
    $record2=@{timestamp=$at.AddSeconds(60).ToString('o');event='auto.decision';data=@{source='ConfirmedForeground'}}|ConvertTo-Json -Compress
    [IO.File]::WriteAllText($file,$record1+"`n"+$record2+"`npartial")
    $reader=New-Object ProfileUsageLogReader $root,$false;$first=$reader.Refresh($at.AddSeconds(120))
    Assert 'log import skips incomplete trailing writes and persists daily summaries' ($first.Days['2026-11-14'].GameSeconds -eq 30 -and (Test-Path (Join-Path $root 'usage.logs.history.json')))
    $reloaded=New-Object ProfileUsageLogReader $root,$false
    Assert 'cached log statistics survive restart' ($reloaded.Cache.Days['2026-11-14'].Seconds -eq 30)
    Remove-Item -LiteralPath $file
    Assert 'rotated or deleted logs do not erase saved historical durations' ($reloaded.Refresh($at.AddSeconds(120)).Days['2026-11-14'].Seconds -eq 30)
}finally{
    if($Script:EnergyService){$Script:EnergyService.Dispose()};if($Script:EnergyLogTimer){$Script:EnergyLogTimer.Dispose()}
    if(-not ([IO.Path]::GetFullPath($root)).StartsWith(([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\PowerProfileUsageTests-'),[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected cleanup path'}
    Remove-Item -LiteralPath $root -Recurse -Force
}
