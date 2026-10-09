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
    $settingsForm=Show-ModernSettings -ReturnForm
    $settingsForm.Show();[Windows.Forms.Application]::DoEvents()
    $saveButton=@($settingsForm.Controls | Where-Object { $_ -is [Windows.Forms.Button] -and $_.Text -eq '保存' })[0]
    $saveButton.PerformClick()
    $after=Get-Content $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach($mode in @('Idle','Balanced','Game')) {
        Assert-Equal "modern UI save preserves CPU $mode" ($after.modes.$mode | ConvertTo-Json -Compress) ($before.modes.$mode | ConvertTo-Json -Compress)
    }
    Assert-Equal 'modern UI save changes only UI option' $after.ui.toastEnabled $true
    if($settingsForm.Icon){$settingsForm.Icon.Dispose()};$settingsForm.Dispose()
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\PowerProfileUITests-'
    if(-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected cleanup target'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host 'All UI/version regression tests passed.'
