$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'PowerProfileDetection.ps1')
. (Join-Path $project 'PowerProfileUpdate.ps1')
. (Join-Path $project 'PowerProfileCState.ps1')
function Assert($Name,$Value){if(-not $Value){throw $Name};Write-Host "PASS $Name"}
function Assert-Throws($Name,[scriptblock]$Action){$failed=$false;try{& $Action}catch{$failed=$true};Assert $Name $failed}
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('PowerProfileDistribution-'+[Guid]::NewGuid());[void][IO.Directory]::CreateDirectory($tmp)
try {
    # All power operations are mocked. Never modify the testing machine.
    $Script:power=@{scheme='8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c';ac=0;dc=0};$Script:powerWrites=0
    function Read-CStatePower{return $Script:power.Clone()}
    function Invoke-CStatePower($Scheme,$AC,$DC){$Script:powerWrites++;$Script:power=@{scheme=$Scheme;ac=$AC;dc=$DC}}
    Assert 'new users default to no C-state workaround' (-not (Get-CStateOptions $tmp).enabled -and $Script:powerWrites -eq 0)
    Assert-Throws 'enabling requires explicit acknowledgement' {Set-CStateProtection $tmp $true $false}
    Assert 'unconfirmed setting did not touch power' ($Script:powerWrites -eq 0)
    Set-CStateProtection $tmp $true $true
    Assert 'confirmed workaround disables idle AC and DC' ($Script:power.ac -eq 1 -and $Script:power.dc -eq 1)
    Set-CStateProtection $tmp $false $false
    Assert 'turning off restores exact original values' ($Script:power.ac -eq 0 -and $Script:power.dc -eq 0)
    $Script:power.ac=1;$Script:power.dc=1;Set-CStateProtection $tmp $true $true
    $writes=$Script:powerWrites;Set-CStateProtection $tmp $true $true
    Assert 'existing protection is not reset or reapplied' ($Script:powerWrites -eq $writes -and $Script:power.ac -eq 1)
    $Script:power.scheme='381b4222-f694-41f0-9685-ff5bb260df2e'
    Assert-Throws 'cannot restore into a different plan' {Set-CStateProtection $tmp $false $false}

    $source=Join-Path $tmp 'source';[void][IO.Directory]::CreateDirectory($source)
    Get-ChildItem $project -File | Where-Object {Test-ProfilePackagePath $_.Name} | Copy-Item -Destination $source
    Copy-Item (Join-Path $project 'legacy') (Join-Path $source 'legacy') -Recurse
    $privateFiles=@('settings.json','energy.settings.json','devices.hub.json','cstate.settings.json','usage.logs.history.json','games.sessions.history.json','ai.settings.json','ai.snapshot.json','ai.usage.db','ai.usage.history.json','ai.backfill.history.json','ai.charges.json','ai.collector.lock')
    foreach($private in $privateFiles){'private fixture'|Set-Content (Join-Path $source $private)}
    @{version='2.0.0';distribution='source'}|ConvertTo-Json|Set-Content (Join-Path $source 'version.json')
    $out=Join-Path $tmp 'out';& (Join-Path $project 'Build-Release.ps1') -Source $source -Output $out
    $zip=Join-Path $out 'PowerProfile-2.0.0-windows.zip';$package=Join-Path $tmp 'package'
    Expand-ProfilePackage $zip $package;$manifest=Test-ProfilePackage $package '2.0.0'
    Assert 'release ZIP has program files and manual' (@($manifest.files).Count -gt 30)
    Assert 'versioned release notes are bundled' (Test-Path (Join-Path $package 'RELEASE_NOTES_1.0.0.md'))
    Assert 'analytics dependencies are bundled' ((Test-Path (Join-Path $package 'PowerProfileGameAnalytics.cs')) -and (Test-Path (Join-Path $package 'PowerProfileInsights.ps1')) -and (Test-Path (Join-Path $package 'PowerProfileInsightsUI.cs')))
    foreach($private in $privateFiles){Assert "package excludes $private" (-not(Test-Path (Join-Path $package $private)))}
    Assert 'release enables default OTA' ((Get-ProfileUpdateOptions $package).enabled)
    Assert 'source checkout defaults OTA off' (-not (Get-ProfileUpdateOptions $project).enabled)
    Assert 'runtime credentials prohibited by manifest' (-not(Test-ProfilePackagePath '../settings.json'))
    'tampered'|Add-Content (Join-Path $package 'USER_GUIDE.md')
    Assert-Throws 'tampered files rejected' {Test-ProfilePackage $package '2.0.0'}
    $badZip=Join-Path $tmp 'bad.zip';$archive=[IO.Compression.ZipFile]::Open($badZip,[IO.Compression.ZipArchiveMode]::Create)
    [void]$archive.CreateEntry('../escape.ps1');$archive.Dispose()
    Assert-Throws 'zip traversal rejected before extraction' {Expand-ProfilePackage $badZip (Join-Path $tmp 'bad')}

    $app=Join-Path $tmp 'app';[void][IO.Directory]::CreateDirectory($app)
    @{version='1.0.0';distribution='release'}|ConvertTo-Json|Set-Content (Join-Path $app 'version.json')
    foreach($private in $privateFiles){'keep fixture'|Set-Content (Join-Path $app $private)}
    $Script:fixtureZip=$zip;$Script:digest=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant();$Script:fetchCount=0
    function Get-ProfileRelease {
        $Script:fetchCount++
        return [PSCustomObject]@{draft=$false;prerelease=$false;tag_name='v2.0.0';assets=@([PSCustomObject]@{name='PowerProfile-2.0.0-windows.zip';state='uploaded';digest=('sha256:'+$Script:digest);browser_download_url='https://github.com/LumishadeVoyager/PowerProfile/releases/download/v2.0.0/PowerProfile-2.0.0-windows.zip'})}
    }
    function Invoke-WebRequest($Uri,[switch]$UseBasicParsing,$OutFile,$TimeoutSec){Copy-Item -LiteralPath $Script:fixtureZip -Destination $OutFile}
    Invoke-ProfileUpdateCheck $app
    $status=Read-ProfileUpdateState (Join-Path $app '.updates/status.json')
    Assert "OTA downloads validated update: $($status.message)" ($status.phase -eq 'ready')
    Assert 'download does not install while user is working' ((Get-ProfileVersionInfo $app).version -eq '1.0.0')
    Invoke-ProfileUpdateCheck $app
    Assert 'automatic check limited to once per 24 hours' ($Script:fetchCount -eq 1)
    Install-ProfilePendingUpdate $app
    Assert 'next start installs program package' ((Get-ProfileVersionInfo $app).version -eq '2.0.0')
    foreach($private in $privateFiles){Assert "update preserves $private" ((Get-Content (Join-Path $app $private) -Raw).Trim() -eq 'keep fixture')}
    Restore-ProfileUpdate $app
    Assert 'failed startup restores prior version' ((Get-ProfileVersionInfo $app).version -eq '1.0.0')
    Invoke-ProfileUpdateCheck $app -Manual;Install-ProfilePendingUpdate $app;Confirm-ProfileUpdate $app
    Restore-ProfileUpdate $app
    Assert 'successful update retained' ((Get-ProfileVersionInfo $app).version -eq '2.0.0')
    $tx=Read-ProfileUpdateState (Join-Path $app '.updates/transaction.json');$tx.phase='applying';Write-AtomicJson (Join-Path $app '.updates/transaction.json') $tx
    '{torn'|Set-Content (Join-Path $app 'version.json');Install-ProfilePendingUpdate $app
    Assert 'interrupted metadata can still recover' ((Get-ProfileVersionInfo $app).version -eq '1.0.0')
    $Script:digest=('0'*64);@{version='1.0.0';distribution='release'}|ConvertTo-Json|Set-Content (Join-Path $app 'version.json')
    Invoke-ProfileUpdateCheck $app -Manual
    Assert 'wrong package digest cannot stage update' ((Read-ProfileUpdateState (Join-Path $app '.updates/status.json')).phase -eq 'error' -and -not(Test-Path (Join-Path $app '.updates/pending')))
    Write-AtomicJson (Join-Path $app 'updates.settings.json') @{enabled=$false};$count=$Script:fetchCount;Invoke-ProfileUpdateCheck $app
    Assert 'disabled automatic updates stop access' ($Script:fetchCount -eq $count)

    # Real Windows controls; mock the power reader again after loading UI dependencies.
    Add-Type -AssemblyName System.Windows.Forms,System.Drawing
    Add-Type -Path (Join-Path $project 'PowerProfileUI.cs') -ReferencedAssemblies System.Windows.Forms,System.Drawing
    $Script:ModernFont=New-Object Drawing.Font 'Microsoft YaHei UI',9
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'PowerProfileModernUI.ps1'),[ref]$null,[ref]$null)
    foreach($name in @('New-ModernLabel','Initialize-ModernForm')){$node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true);. ([scriptblock]::Create($node.Extent.Text))}
    . (Join-Path $project 'PowerProfileEnergyUI.ps1')
    . (Join-Path $project 'PowerProfileWelcomeUI.ps1')
    function Read-CStatePower{return @{ac=1;dc=1}}
    $ScriptDir=$project;$SettingsPath=Join-Path $tmp 'settings.json'
    $form=Show-CStateProtection -ReturnForm
    Assert 'existing local protection shown as enabled' $form.Tag.Enable.Checked
    Assert 'confirmation unchecked on open' (-not $form.Tag.Ack.Checked -and -not $form.Tag.Save.Enabled)
    $form.Tag.Ack.Checked=$true;Assert 'checkbox unlocks apply' $form.Tag.Save.Enabled
    $form.Dispose()
    $newUser=Join-Path $tmp 'new-user';[void][IO.Directory]::CreateDirectory($newUser);$SettingsPath=Join-Path $newUser 'settings.json'
    $form=Show-CStateProtection -ReturnForm
    Assert 'fresh UI has protection and acknowledgement off' (-not $form.Tag.Enable.Checked -and -not $form.Tag.Ack.Checked)
    $form.Tag.Enable.Checked=$true;Assert 'fresh enable waits for confirmation' (-not $form.Tag.Save.Enabled)
    $form.Tag.Ack.Checked=$true;Assert 'fresh confirmed enable available' $form.Tag.Save.Enabled
    $form.Dispose();$SettingsPath=Join-Path $tmp 'settings.json'
    $guide=Show-ProfileWelcome -ReturnForm
    Assert 'guide offers update preference' (-not $guide.Tag.Enable.Checked)
    $guide.Tag.Timer.Dispose();$guide.Dispose()
} finally {Remove-Item -LiteralPath $tmp -Recurse -Force}
