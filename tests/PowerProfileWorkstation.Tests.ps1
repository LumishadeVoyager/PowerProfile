$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'PowerProfileDetection.ps1')
. (Join-Path $project 'PowerProfileWorkstation.ps1')
. (Join-Path $project 'PowerProfileLog.ps1')
Add-Type -Path (Join-Path $project 'PowerProfileWorkstation.cs')
function Assert-Equal($Name,$Actual,$Expected){if($Actual -ne $Expected){throw "$Name expected $Expected got $Actual"};Write-Host "PASS $Name"}
$recoveryRoot=Join-Path ([IO.Path]::GetTempPath()) ('PowerProfileRecoveryTests-'+[Guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($recoveryRoot)
try {
 $recoveryPath=Join-Path $recoveryRoot 'workstation_state.json'
 foreach($damaged in @((([string][char]0)*621),'{broken','null','{}')) {
  [IO.File]::WriteAllText($recoveryPath,$damaged)
  Assert-Equal 'UI tolerates corrupt state without modifying it' ($null -eq (Read-WorkstationState $recoveryPath -ReadOnly)) $true
  Assert-Equal 'read-only access preserves evidence' ([IO.File]::ReadAllText($recoveryPath)) $damaged
  Restore-WorkstationOverlay $recoveryRoot 'fixture recovery'
  Assert-Equal 'corrupt overlay cannot block base profile switch' (Read-AtomicJson $recoveryPath).active $false
 }
 $backups=@(Get-ChildItem $recoveryRoot -Filter '*.corrupt-*')
 Assert-Equal 'each damaged snapshot is preserved' $backups.Count 4
 Assert-Equal 'zero-filled evidence retains exact size' $backups.Where({$_.Length -eq 621}).Count 1
 Write-AtomicJson $recoveryPath @{active=$true;baseline=@{scheme='invalid'}}
 $failed=$false
 try {Restore-WorkstationOverlay $recoveryRoot}catch{$failed=$_.Exception.Message -match 'Invalid recovery scheme'}
 Assert-Equal 'valid JSON with unsafe recovery values still blocks restoration' $failed $true
} finally {
 $full=[IO.Path]::GetFullPath($recoveryRoot)
 if(-not $full.StartsWith(([IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\PowerProfileRecoveryTests-'),[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe recovery fixture cleanup'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
$calendar=Get-Content (Join-Path $project 'workdays.2026.json') -Raw | ConvertFrom-Json
Assert-Equal 'October holiday' (Test-ChineseWorkingDate ([DateTime]'2026-10-06') $calendar) $false
Assert-Equal 'Saturday makeup working date' (Test-ChineseWorkingDate ([DateTime]'2026-10-10') $calendar) $true
Assert-Equal 'ordinary Sunday' (Test-ChineseWorkingDate ([DateTime]'2026-10-11') $calendar) $false
Assert-Equal 'unknown year does not assume weekdays' (Test-ChineseWorkingDate ([DateTime]'2027-10-08') $calendar) $false
$o=Get-WorkstationOptions ([PSCustomObject]@{workstation=@{enabled=$true;freqMax=1800}})
$safe=@{Known=$true;Game=$false;Protected=$false;Cpu=0;ProcessCpu=0;SingleCore=0;Gpu=0}
function Decide($Time='2026-10-09T12:00:00',$Idle=1200,$Safety=$safe,$Stable=$true,$AC=$true,$Auto=$true,$Mode='Idle',$Quiet=$true){return Get-WorkstationDecision $o ([DateTime]$Time) $calendar $AC $Auto $Mode $Idle $Safety $Stable $Quiet}
Assert-Equal 'ten AM inclusive' (Decide '2026-10-09T10:00:00') 'Eligible'
Assert-Equal 'six PM exclusive' (Decide '2026-10-09T18:00:00') 'OutsideHours'
Assert-Equal 'old settings keep statutory working days' $o.schedule 'ChineseWorkdays'
$old=$o.Clone()
$o.schedule='EveryDay';$o.awayMinutes=5;$o.startMinute=0;$o.endMinute=1440
Assert-Equal 'daily applies on holiday' (Decide '2026-10-01T12:00:00' -Idle 300) 'Eligible'
Assert-Equal 'daily applies Sunday without yearly calendar' (Decide '2027-10-10T23:59:59' -Idle 300) 'Eligible'
Assert-Equal 'custom wait cannot enter one second early' (Decide '2026-10-01T12:00:00' -Idle 299) 'RecentInput'
Assert-Equal 'custom wait explanation follows setting' (Get-WorkstationReason RecentInput $o) '本机或远程输入后未满 5 分钟'
$o.schedule='Weekdays'
Assert-Equal 'weekday schedule ignores holiday calendar' (Decide '2026-10-01T12:00:00' -Idle 300) 'Eligible'
Assert-Equal 'weekday schedule excludes makeup Saturday' (Decide '2026-10-10T12:00:00' -Idle 300) 'Holiday'
$o.schedule='Weekends'
Assert-Equal 'weekend applies to makeup Saturday by weekday' (Decide '2026-10-10T12:00:00' -Idle 300) 'Eligible'
$o.schedule='HolidayOnly'
Assert-Equal 'holiday-only uses holiday dates' (Decide '2026-10-01T12:00:00' -Idle 300) 'Eligible'
Assert-Equal 'holiday-only excludes working dates' (Decide '2026-10-09T12:00:00' -Idle 300) 'Holiday'
Assert-Equal 'holiday-only still requires matching calendar' (Decide '2027-10-01T12:00:00' -Idle 300) 'CalendarUnavailable'
$o=$old.Clone();$o.startMinute=540;$o.endMinute=1020
Assert-Equal 'custom start inclusive' (Decide '2026-10-09T09:00:00') 'Eligible'
Assert-Equal 'custom end exclusive' (Decide '2026-10-09T17:00:00') 'OutsideHours'
Assert-Equal 'custom time explanation follows setting' (Get-WorkstationReason OutsideHours $o) '不在 09:00–17:00'
foreach($invalid in @(@{startMinute=1080;endMinute=600},@{schedule='Unknown'},@{awayMinutes=0},@{quietConfirmSeconds=1},@{awayMinutes=1.5},@{awayMinutes=1e20})){
    $bad=@{enabled=$true};foreach($key in $invalid.Keys){$bad[$key]=$invalid[$key]}
    $o=Get-WorkstationOptions ([PSCustomObject]@{workstation=[PSCustomObject]$bad})
    Assert-Equal 'invalid schedule fails closed' (Decide) 'InvalidSchedule'
}
$o=$old.Clone()
Assert-Equal 'nineteen minutes cannot enter' (Decide -Idle 1199) 'RecentInput'
Assert-Equal 'remote or local input exits' (Decide -Idle 0) 'RecentInput'
Assert-Equal 'battery exits' (Decide -AC $false) 'Battery'
Assert-Equal 'manual selection wins' (Decide -Auto $false) 'ModeProtected'
Assert-Equal 'game mode wins' (Decide -Mode Game) 'ModeProtected'
Assert-Equal 'C-state guard cannot be bypassed' (Decide -Stable $false) 'StabilityGuard'
Assert-Equal 'missing telemetry blocks' (Decide -Safety $null) 'SafetyUnavailable'
Assert-Equal 'must confirm quiet twice' (Decide -Quiet $false) 'ConfirmingQuiet'
foreach($pair in @(@('Game',$true,'GamePresent'),@('Protected',$true,'ProtectedProcess'),@('Known',$false,'SafetyUnavailable'),@('Cpu',25,'HighLoad'),@('ProcessCpu',10,'HighLoad'),@('SingleCore',70,'HighLoad'),@('Gpu',15,'HighLoad'))){
 $sample=$safe.Clone();$sample[$pair[0]]=$pair[1]
 Assert-Equal "block $($pair[0])" (Decide -Safety $sample) $pair[2]
}
$o.pausedUntil='2026-10-10T00:00:00'
Assert-Equal 'pause today' (Decide) 'Paused'
$o.pausedUntil='';$o.enabled=$false
Assert-Equal 'disabled' (Decide) 'Disabled'
$o.enabled=$true
$d=Read-DetectionOptions ([PSCustomObject]@{gameProcesses=@('ExampleGame')})
$game=[PSCustomObject]@{ProcessName='ExampleGame';Path='C:\games\ExampleGame.exe';SessionId=1}
Assert-Equal 'idle background configured game still blocks' (Get-StrictProcessProtection @($game) $o $d @()).Game $true
$game.ProcessName='actual-game';$game.Path='C:\games\Installed\bin\actual-game.exe'
Assert-Equal 'background library executable blocks without D3D or load' (Get-StrictProcessProtection @($game) $o $d @(@{Path='C:\games\Installed'})).Game $true
$game.ProcessName='crashreportclient'
Assert-Equal 'library helper does not become game' (Get-StrictProcessProtection @($game) $o $d @(@{Path='C:\games\Installed'})).Game $false
$exited=[PSCustomObject]@{ProcessName='ExampleGame';Path=$null;SessionId=1;HasExited=$true}
Assert-Equal 'exited snapshot process cannot block' (Get-StrictProcessProtection @($exited) $o $d @()).Game $false
$root=Join-Path ([IO.Path]::GetTempPath()) ('PowerProfileWorkstationTests-'+[Guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($root)
try{
 $json=[PSCustomObject]@{modes=@{Idle=@{freqMax=2200;min=50}};processorBaseMHz=2600;workstation=@{enabled=$true;freqMax=1800}}
 Write-AtomicJson (Join-Path $root 'settings.json') $json
 Copy-Item (Join-Path $project 'workdays.2026.json') $root
 Initialize-ProfileLogging $root 'tests' '11111111-1111-1111-1111-111111111111'
 function Get-BeijingTime{return [DateTime]'2026-10-09T12:00:00'}
 $script:testIdle=1200
 function Get-WorkstationInputState{return @{IdleSeconds=$script:testIdle;OnAC=$true}}
 function Get-WorkstationSafety{return $safe.Clone()}
 $script:values=@{'bc5038f7-23e0-4960-96da-33abaf5935ec'=85;'893dee8e-2bef-41e0-89c6-b55d0929964c'=50;'75b0ae3f-bce0-45a7-8c89-c9611c25e100'=2200;'75b0ae3f-bce0-45a7-8c89-c9611c25e101'=2200;'5d76a2ca-e8c0-402f-a133-2158492d58ad'=1}
 function Read-WorkstationPowerValues {return @{scheme='8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c';values=$script:values.Clone();dcIdleDisable=1}}
 function Get-WorkstationScheme{return '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'}
 $script:calls=New-Object Collections.Generic.List[string]
 $script:failNext=$false
 function Invoke-WorkstationPowerCfg($Arguments){
    $script:calls.Add(($Arguments -join ' '))
    if($script:failNext){$script:failNext=$false;throw 'simulated powercfg failure'}
    if($Arguments[0] -eq '/SETACVALUEINDEX'){$script:values[$Arguments[3]]=[int]$Arguments[4]}
 }
 Invoke-WorkstationEvaluation $root Idle $d
 Assert-Equal 'first quiet sample writes no power' $script:calls.Count 0
 Invoke-WorkstationEvaluation $root Idle $d
 Assert-Equal 'rapid duplicate sample cannot enter' $script:calls.Count 0
 function Age-QuietConfirmation {
    $fixture=Get-Content (Join-Path $root 'workstation_state.json') -Raw | ConvertFrom-Json
    $fixture.quietSince=[DateTime]::UtcNow.AddSeconds(-11).ToString('o')
    Write-AtomicJson (Join-Path $root 'workstation_state.json') $fixture
 }
 Age-QuietConfirmation
 Invoke-WorkstationEvaluation $root Idle $d
 $state=Get-Content (Join-Path $root 'workstation_state.json') -Raw | ConvertFrom-Json
 Assert-Equal 'second sample enables overlay' $state.active $true
 Assert-Equal 'only CPU maximum percentage reduced' $script:values['bc5038f7-23e0-4960-96da-33abaf5935ec'] 69
 Assert-Equal 'C-state kept disabled' $script:values['5d76a2ca-e8c0-402f-a133-2158492d58ad'] 1
 Assert-Equal 'never writes DC, minimum, boost, EPP or idle setting' (@($script:calls | Where-Object {$_ -notmatch '^/SETACTIVE' -and $_ -notmatch '^/SETACVALUEINDEX \S+ SUB_PROCESSOR (bc5038f7-23e0-4960-96da-33abaf5935ec|75b0ae3f-bce0-45a7-8c89-c9611c25e10[01]) '}).Count) 0
 $script:testIdle=0
 Invoke-WorkstationEvaluation $root Idle $d
 Assert-Equal 'input restores exact original max' $script:values['bc5038f7-23e0-4960-96da-33abaf5935ec'] 85
 Assert-Equal 'input restores original MHz' $script:values['75b0ae3f-bce0-45a7-8c89-c9611c25e101'] 2200
 $script:testIdle=1200
 Invoke-WorkstationEvaluation $root Idle $d
 Age-QuietConfirmation
 $script:failNext=$true
 $threw=$false
 try{Invoke-WorkstationEvaluation $root Idle $d}catch{$threw=$true}
 Assert-Equal 'powercfg error surfaced' $threw $true
 Assert-Equal 'failed apply recovers baseline' $script:values['bc5038f7-23e0-4960-96da-33abaf5935ec'] 85
 Assert-Equal 'failed apply clears active after successful restore' (Get-Content (Join-Path $root 'workstation_state.json') -Raw | ConvertFrom-Json).active $false
 $records=@(Get-ChildItem (Join-Path $root 'logs') -Filter '*.jsonl' | Get-Content | ForEach-Object {$_ | ConvertFrom-Json})
 Assert-Equal 'logs have schema and operation trace' (@($records | Where-Object {$_.schemaVersion -ne 1 -or $_.operationId -ne '11111111-1111-1111-1111-111111111111'}).Count) 0
 Assert-Equal 'failure log is searchable' (@($records | Where-Object {$_.event -eq 'workstation.apply.failed'}).Count) 1
 Assert-Equal 'restore logs link entry operation' (@($records | Where-Object {$_.event -eq 'workstation.restore.success' -and $_.data.enteredBy}).Count -ge 2) $true
 $json.workstation=@{enabled=$true;freqMax=1800;awayMinutes=5;schedule='EveryDay';startMinute=0;endMinute=1440;quietConfirmSeconds=30}
 Write-AtomicJson (Join-Path $root 'settings.json') $json
 $script:testIdle=300
 Invoke-WorkstationEvaluation $root Idle $d
 Age-QuietConfirmation
 Invoke-WorkstationEvaluation $root Idle $d
 Assert-Equal 'longer quiet confirmation does not use old ten second constant' (Read-AtomicJson (Join-Path $root 'workstation_state.json')).active $false
 $fixture=Read-AtomicJson (Join-Path $root 'workstation_state.json');$fixture.quietSince=[DateTime]::UtcNow.AddSeconds(-31).ToString('o');Write-AtomicJson (Join-Path $root 'workstation_state.json') $fixture
 Invoke-WorkstationEvaluation $root Idle $d
 Assert-Equal 'worker accepts configured five minute wait' (Read-AtomicJson (Join-Path $root 'workstation_state.json')).active $true
 $json.workstation.awayMinutes=30;Write-AtomicJson (Join-Path $root 'settings.json') $json
 Invoke-WorkstationEvaluation $root Idle $d
 Assert-Equal 'increasing wait restores active overlay immediately on reevaluation' (Read-AtomicJson (Join-Path $root 'workstation_state.json')).active $false
 Assert-Equal 'schedule changes restore original frequency rather than default' $script:values['75b0ae3f-bce0-45a7-8c89-c9611c25e101'] 2200
}finally{
 $full=[IO.Path]::GetFullPath($root);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\PowerProfileWorkstationTests-'
 if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe cleanup path'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
Write-Host 'All workstation and log tests passed.'
