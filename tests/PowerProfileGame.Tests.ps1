$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'PowerProfileDisplay.ps1')
function Assert-Equal($Name,$Actual,$Expected){if($Actual -ne $Expected){throw "$Name expected $Expected got $Actual"};Write-Host "PASS $Name"}
$script:ProfileFixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('PowerProfileGameTests-'+[Guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($script:ProfileFixtureRoot)
try {
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'PowerProfile.ps1'),[ref]$null,[ref]$null)
    $defaults=$ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$DefaultProfiles'},$true)
    . ([scriptblock]::Create($defaults.Extent.Text))
    $Profiles=$DefaultProfiles
    Assert-Equal 'worker game default is unlimited' $Profiles.Game.FreqMax 0
    $template=Get-Content (Join-Path $project 'settings.example.json') -Raw | ConvertFrom-Json
    Assert-Equal 'new installation game default is unlimited' $template.modes.Game.freqMax 0
    $trayAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'PowerProfileTray.ps1'),[ref]$null,[ref]$null)
    $trayDefaults=$trayAst.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$DefaultSettings'},$true)
    . ([scriptblock]::Create($trayDefaults.Extent.Text))
    Assert-Equal 'resetting tray defaults preserves unlimited game profile' $DefaultSettings.modes.Game.freqMax 0
    $apply=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-PowerProfile'},$true)
    . ([scriptblock]::Create($apply.Extent.Text.Replace('$PSScriptRoot','$script:ProfileFixtureRoot')))
    function Read-AtomicJson {return [PSCustomObject]@{processorBaseMHz=2600}}
    function Restore-WorkstationOverlay {param($Root,$Reason) $script:restoreFirst=$true}
    function Write-ProfileEvent {param($Event,$Message,$Level,$Data) $script:events+=@($Event)}
    $script:calls=@();$script:events=@();$script:restoreFirst=$false;$script:failClass1=$false
    function Invoke-ProfilePowerCfg {
        param([string[]]$Arguments,[switch]$Optional)
        $script:calls+=@([PSCustomObject]@{args=$Arguments;optional=[bool]$Optional})
        if($script:failClass1 -and $Arguments[0] -eq '/SETACVALUEINDEX' -and $Arguments[3] -eq '75b0ae3f-bce0-45a7-8c89-c9611c25e101' -and -not $Optional){throw 'fixture class 1 frequency failure'}
    }
    Set-PowerProfile Game 'fixture game profile'
    Assert-Equal 'switch restores workstation overlay before applying game' $script:restoreFirst $true
    foreach($supply in @('/SETACVALUEINDEX','/SETDCVALUEINDEX')) {
        foreach($setting in @(@('75b0ae3f-bce0-45a7-8c89-c9611c25e100',0),@('75b0ae3f-bce0-45a7-8c89-c9611c25e101',0),@('PROCTHROTTLEMAX',100),@('PERFBOOSTMODE',2),@('36687f9e-e3a5-4dbf-b1dc-15eb381c6863',0),@('8baa4a8a-14c6-4451-8e8b-14bdbd197537',1))) {
            $call=@($script:calls | Where-Object {$_.args[0] -eq $supply -and $_.args[3] -eq $setting[0]})[0]
            Assert-Equal "$supply $($setting[0]) applied" $call.args[4] $setting[1]
            Assert-Equal "$supply $($setting[0]) required" $call.optional $false
        }
    }
    Assert-Equal 'game application never changes C-state guard' (@($script:calls | Where-Object {($_.args -join ' ') -match 'IDLEDISABLE|5d76a2ca'}).Count) 0
    $script:events=@();$script:failClass1=$true;$failed=$false
    try{Set-PowerProfile Game 'fixture failed application'}catch{$failed=$_.Exception.Message -match 'class 1'}
    Assert-Equal 'second core class unlock failure surfaces' $failed $true
    Assert-Equal 'failed core class unlock cannot log successful application' ($script:events -contains 'profile.apply.success') $false
} finally {
    $full=[IO.Path]::GetFullPath($script:ProfileFixtureRoot)
    $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\PowerProfileGameTests-'
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe cleanup path'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
