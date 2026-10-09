$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'PowerProfileDetection.ps1')
. (Join-Path $PSScriptRoot 'PowerProfileLogic.Tests.ps1')

function New-Candidate {
    param([hashtable]$Changes = @{})
    $value = @{ Excluded = $false; SameSession = $false; Foreground = $true; SecondsSinceForeground = 0
        Cpu = 0; Gpu = 0; InLibrary = $false; ExplicitGame = $false; IsD3D = $false; IsFullscreen = $false }
    foreach ($key in $Changes.Keys) { $value[$key] = $Changes[$key] }
    return $value
}

Assert-Equal 'NBA protected modules: library and own CPU qualify' (Get-GameSignalDecision (New-Candidate @{ InLibrary=$true; Cpu=257; IsFullscreen=$true })) 'LibraryGame'
Assert-Equal 'windowed 2D library game qualifies' (Get-GameSignalDecision (New-Candidate @{ InLibrary=$true; Gpu=2 })) 'LibraryGame'
Assert-Equal 'native HID and low-load menus retain confirmed foreground' (Get-GameSignalDecision (New-Candidate @{ SameSession=$true })) 'ConfirmedForeground'
Assert-Equal 'Alt-Tab retains game during grace' (Get-GameSignalDecision (New-Candidate @{ SameSession=$true; Foreground=$false; SecondsSinceForeground=119 })) 'BackgroundGrace'
Assert-Equal 'Bodycam behind Chrome retains its own load' (Get-GameSignalDecision (New-Candidate @{ SameSession=$true; Foreground=$false; SecondsSinceForeground=180; Cpu=501; Gpu=21 })) 'BackgroundGameLoad'
Assert-Equal 'inactive background session eventually cools' (Get-GameSignalDecision (New-Candidate @{ SameSession=$true; Foreground=$false; SecondsSinceForeground=181 })) 'BackgroundInactive'
Assert-Equal 'negative clock delta cannot extend grace' (Get-GameSignalDecision (New-Candidate @{ SameSession=$true; Foreground=$false; SecondsSinceForeground=-1 })) 'BackgroundInactive'
Assert-Equal 'wallpaper GPU cannot qualify an idle fullscreen app' (Get-GameSignalDecision (New-Candidate @{ IsD3D=$true; IsFullscreen=$true })) 'NoGameEvidence'
Assert-Equal 'unrelated D3D app does not inherit current Game mode' (Get-GameSignalDecision (New-Candidate @{ IsD3D=$true; IsFullscreen=$true })) 'NoGameEvidence'
Assert-Equal 'excluded helper beats explicit game rule' (Get-GameSignalDecision (New-Candidate @{ Excluded=$true; ExplicitGame=$true; InLibrary=$true; Cpu=900 })) 'Excluded'
Assert-Equal 'explicit game supports missing path and modules' (Get-GameSignalDecision (New-Candidate @{ ExplicitGame=$true })) 'ConfiguredGame'
Assert-Equal 'generic 3D outside launchers qualifies on its own load' (Get-GameSignalDecision (New-Candidate @{ IsD3D=$true; IsFullscreen=$true; Gpu=25 })) 'Foreground3DLoad'
Assert-Equal 'directory prefix sibling is not a game root' (Test-PathUnderRoot 'C:\Games\FooTools\helper.exe' 'C:\Games\Foo') $false
Assert-Equal 'canonical traversal cannot escape a root' (Test-PathUnderRoot 'C:\Games\Foo\..\other.exe' 'C:\Games\Foo') $false
Assert-Equal 'nested binary and case-insensitive path qualify' (Test-PathUnderRoot 'C:\Games\FOO\Binaries\Win64\game.exe' 'c:\games\foo\') $true

$options = Read-DetectionOptions ([PSCustomObject]@{ backgroundGraceSec=-1; discoverSteam='false'; gameProcesses=@('test.exe',42) })
Assert-Equal 'invalid grace uses default' $options.backgroundGraceSec 120
Assert-Equal 'string false is not treated as bool true or false' $options.discoverSteam $true
Assert-Equal 'non-string rule ignored' $options.gameProcesses.Count 1
Assert-Equal 'zero grace is supported' (Read-DetectionOptions ([PSCustomObject]@{backgroundGraceSec=0})).backgroundGraceSec 0
foreach ($name in @('wallpaperui', 'LosslessScaling', 'CrashReportClient', 'EasyAntiCheat_EOS', 'UnityCrashHandler64', 'gameLauncher', 'csrss', 'leigod')) {
    Assert-Equal "helper excluded: $name" (Test-ExcludedGameProcess $name $options @()) $true
}
Assert-Equal 'game binary is not blanket excluded' (Test-ExcludedGameProcess 'Bodycam-Win64-Shipping' $options @()) $false
Assert-Equal 'lock overrides a confirmed game' (Get-AutoModeTransition 'Game' @{ForceIdle=$true;IsGame=$true} 0 3).Mode 'Idle'
$transition = Get-AutoModeTransition 'Game' @{IsGame=$false} 0 3
Assert-Equal 'first miss holds Game' $transition.Mode 'Game'
$transition = Get-AutoModeTransition 'Game' @{IsGame=$false} $transition.MissCount 3
Assert-Equal 'second miss holds Game' $transition.Mode 'Game'
$transition = Get-AutoModeTransition 'Game' @{IsGame=$true} $transition.MissCount 3
Assert-Equal 'returning game resets exit misses' $transition.MissCount 0
Assert-Equal 'third miss returns to Idle' (Get-AutoModeTransition 'Game' @{IsGame=$false} 2 3).Mode 'Idle'

# Exercise real session persistence with fake OS observations, without touching powercfg.
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('PowerProfileTests-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testDirectory)
try {
    function Format-LoadSummary { param($Load) return 'fixture load' }
    function Get-InstalledGameRoots { param($Options) return @([PSCustomObject]@{Path='C:\Games\Bodycam';Name='Bodycam';Source='Fixture'}) }
    $script:identities = @{
        10=@{Id=10; Name='Bodycam-Win64-Shipping'; Path='C:\Games\Bodycam\Binaries\game.exe'; Started='2026-09-01T10:00:00Z'}
        20=@{Id=20; Name='chrome'; Path='C:\Apps\chrome.exe'; Started='2026-09-01T09:00:00Z'}
    }
    function Get-ProcessIdentity { param([int]$ProcessId) return $script:identities[$ProcessId] }
    $options = Read-DetectionOptions $null
    $fg = @{Pid=10; Proc='Bodycam-Win64-Shipping'; IsFs=$false; IsD3D=$false}
    $load = @{ProcessCpu=@{10=501}; ProcessGpu=@{10=21}; TopCpuPid=10; TopCpuValue=501}
    $first = Get-SessionGameDetection $fg $load $options @('chrome') $testDirectory
    Assert-Equal 'session starts from windowed library evidence' $first.Source 'LibraryGame'
    $path = Join-Path $testDirectory 'game_session_state.json'
    $session = Get-Content $path -Raw | ConvertFrom-Json
    Assert-Equal 'session saves process creation time' $session.started '2026-09-01T10:00:00Z'
    $fg = @{Pid=20; Proc='chrome'; IsFs=$true; IsD3D=$true}
    $session.lastForegroundAt = [DateTime]::UtcNow.AddMinutes(-5).ToString('o')
    Write-AtomicJson $path $session
    $background = Get-SessionGameDetection $fg $load $options @('chrome') $testDirectory
    Assert-Equal 'excluded foreground does not veto background game' $background.Source 'BackgroundGameLoad'
    $load = @{ProcessCpu=@{10=0}; ProcessGpu=@{10=0}; TopCpuPid=20; TopCpuValue=800}
    Assert-Equal 'another process CPU does not hold game' (Get-SessionGameDetection $fg $load $options @('chrome') $testDirectory).IsGame $false
    $fg = @{Pid=10; Proc='Bodycam-Win64-Shipping'; IsFs=$false; IsD3D=$false}
    Assert-Equal 'returning to paused game restores it immediately' (Get-SessionGameDetection $fg $load $options @('chrome') $testDirectory).Source 'ConfirmedForeground'
    $fg.Pid=20; $fg.Proc='chrome'
    $script:identities[10].Started='2026-09-01T11:00:00Z'
    Assert-Equal 'reused PID cannot inherit confirmation' (Get-SessionGameDetection $fg $load $options @('chrome') $testDirectory).IsGame $false
    Assert-Equal 'invalid session is removed' (Test-Path $path) $false
    $fg.Pid=10; $fg.Proc='Bodycam-Win64-Shipping'; $load.ProcessCpu[10]=501
    [void](Get-SessionGameDetection $fg $load $options @('chrome') $testDirectory -ReadOnly)
    Assert-Equal 'read-only diagnosis creates no session state' (Test-Path $path) $false
    [void](Get-SessionGameDetection $fg $load $options @('chrome') $testDirectory)
    $script:identities.Remove(10); $fg.Pid=20; $fg.Proc='chrome'
    Assert-Equal 'game exit clears confirmation' (Get-SessionGameDetection $fg $load $options @('chrome') $testDirectory).IsGame $false
    Assert-Equal 'game exit removes state file' (Test-Path $path) $false
    [IO.File]::WriteAllText($path, '{broken')
    Assert-Equal 'corrupt state fails safely' (Get-SessionGameDetection $fg $load $options @('chrome') $testDirectory).IsGame $false

    # Load only the real settings writer, without starting the tray UI.
    $tokens=$null; $parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'PowerProfileTray.ps1'),[ref]$tokens,[ref]$parseErrors)
    $saveFunction=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Save-Settings'},$true)
    . ([scriptblock]::Create($saveFunction.Extent.Text))
    $hiddenPowerShellFunction=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-HiddenPowerShell'},$true)
    . ([scriptblock]::Create($hiddenPowerShellFunction.Extent.Text))
    $SettingsPath=Join-Path $testDirectory 'settings.json'
    $settings=Get-Content (Join-Path $project 'settings.example.json') -Raw | ConvertFrom-Json
    $settings.detection.gameProcesses=@('private-game')
    Write-AtomicJson $SettingsPath $settings
    $gui=@{modes=@{Idle=$settings.modes.Idle;Balanced=$settings.modes.Balanced;Game=$settings.modes.Game};autoIntervalSec=30;userIdleSec=90;toastStaySec=2;manualUnlockMinutes=20;gameIdleQuietMinutes=10;gameExitMissCount=3}
    Save-Settings $gui
    $saved=Get-Content $SettingsPath -Raw | ConvertFrom-Json
    Assert-Equal 'GUI save preserves personalized detection' $saved.detection.gameProcesses[0] 'private-game'
    Assert-Equal 'GUI save still updates ordinary settings' $saved.autoIntervalSec 30

    $childScript=Join-Path $testDirectory 'hidden-worker-test.ps1'
    $childMarker=Join-Path $testDirectory 'hidden-worker-result.txt'
    "param([string]`$Marker); 'ok' | Set-Content -LiteralPath `$Marker; Start-Sleep -Milliseconds 500" | Set-Content -LiteralPath $childScript -Encoding UTF8
    $hiddenProcess=Start-HiddenPowerShell -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $childScript), '-Marker', ('"{0}"' -f $childMarker))
    Assert-Equal 'worker shell disables shell execution' $hiddenProcess.StartInfo.UseShellExecute $false
    Assert-Equal 'worker shell requests no console window' $hiddenProcess.StartInfo.CreateNoWindow $true
    Assert-Equal 'worker shell window style remains hidden' $hiddenProcess.StartInfo.WindowStyle ([Diagnostics.ProcessWindowStyle]::Hidden)
    [void]$hiddenProcess.WaitForExit(5000)
    Assert-Equal 'hidden worker exits successfully' $hiddenProcess.ExitCode 0
    Assert-Equal 'hidden worker executes its script' (Get-Content -LiteralPath $childMarker -Raw).Trim() 'ok'

    $workerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'PowerProfile.ps1'),[ref]$tokens,[ref]$parseErrors)
    $powerFunction=$workerAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-ProfilePowerCfg'},$true)
    . ([scriptblock]::Create($powerFunction.Extent.Text))
    function powercfg.exe { $global:LASTEXITCODE=1; return 'fixture command failure' }
    $failed=$false
    try { Invoke-ProfilePowerCfg -Arguments @('/SETACTIVE','SCHEME_CURRENT') } catch { $failed=$true }
    Assert-Equal 'required power command failure is surfaced' $failed $true
    Invoke-ProfilePowerCfg -Arguments @('/attributes','unsupported') -Optional
    Remove-Item Function:\powercfg.exe

    $restartAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $project '_restart_tray.ps1'),[ref]$tokens,[ref]$parseErrors)
    $restartFunction=$restartAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-InstallationProcess'},$true)
    . ([scriptblock]::Create($restartFunction.Extent.Text))
    $targets=@('C:\Power Profile\PowerProfileTray.ps1','C:\Power Profile\PowerProfile.ps1')
    Assert-Equal 'restart recognizes its quoted installation path' (Test-InstallationProcess @{ProcessId=999;Name='powershell.exe';CommandLine='powershell.exe -File "C:\Power Profile\PowerProfileTray.ps1"'}) $true
    Assert-Equal 'restart leaves another installation alone' (Test-InstallationProcess @{ProcessId=999;Name='powershell.exe';CommandLine='powershell.exe -File C:\Other\PowerProfileTray.ps1'}) $false
    Assert-Equal 'restart leaves hosts with unknown command lines alone' (Test-InstallationProcess @{ProcessId=999;Name='powershell.exe';CommandLine=''}) $false
} finally {
    $resolved=[IO.Path]::GetFullPath($testDirectory)
    $tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\PowerProfileTests-'
    if (-not $resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test cleanup target' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host 'All detection and session regression tests passed.'
