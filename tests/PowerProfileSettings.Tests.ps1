$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
. (Join-Path $project 'PowerProfileDetection.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('ProfileSettingsTest-'+[Guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($root)
$SettingsPath=Join-Path $root 'settings.json'
Copy-Item (Join-Path $project 'settings.example.json') $SettingsPath
$DefaultSettings=@{modes=@{Idle=@{name='Quiet';freqMax=2200;boost=0;min=50;max=100};Balanced=@{name='Balanced';freqMax=3000;boost=1;min=60;max=99};Game=@{name='Game';freqMax=0;boost=2;min=90;max=100}};autoIntervalSec=30;userIdleSec=90;toastStaySec=1.2;manualUnlockMinutes=10;gameIdleQuietMinutes=10;gameExitMissCount=3}
$ModeColors=@{Idle=[Drawing.Color]::Blue;Balanced=[Drawing.Color]::Green;Game=[Drawing.Color]::Red}
$ModeLabels=@{}
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'PowerProfileTray.ps1'),[ref]$null,[ref]$null)
foreach($name in @('Read-Settings','Save-Settings','New-Preset','New-PresetCombo','Get-PresetValue','Get-FrequencyPresets','Format-Freq','Show-Settings','Refresh-ModeLabels')){
    $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($node.Extent.Text))
}
function Get-CurrentMode{return 'Idle'}
function Invoke-Worker {param($Mode) $Script:appliedMode=$Mode;$Script:appliedFrequency=(Get-Content $SettingsPath -Raw | ConvertFrom-Json).modes.Idle.freqMax}
function Assert($Name,$Value){if(-not $Value){throw $Name};Write-Host "PASS $Name"}
try{
    foreach($frequency in @(2000,1600,2200)){
        # Reproduce entry from a dashboard event callback, then a separate modal save callback.
        $opener=New-Object Windows.Forms.Button
        $opener.Add_Click({$Script:testForm=Show-Settings -ReturnForm})
        $opener.PerformClick();$form=$Script:testForm
        $tabs=@($form.Controls | Where-Object {$_ -is [Windows.Forms.TabControl]})[0]
        Assert 'parameters split into two compact pages' ($tabs.TabPages.Count -eq 2 -and $form.ClientSize.Height -eq 510)
        $form.Show();[Windows.Forms.Application]::DoEvents()
        foreach($page in $tabs.TabPages){$tabs.SelectedTab=$page;[Windows.Forms.Application]::DoEvents();foreach($group in $page.Controls){
            Assert 'parameter group fits its page' ($group.Right -le $page.ClientSize.Width -and $group.Bottom -le $page.ClientSize.Height)
            Assert 'parameter controls fit their group' (@($group.Controls | Where-Object {$_.Right -gt $group.ClientSize.Width -or $_.Bottom -gt $group.ClientSize.Height}).Count -eq 0)
        }}
        $tabs.SelectedIndex=0;$form.Hide()
        $combo=$form.Tag.Controls.Idle.FreqCombo
        for($i=0;$i -lt $combo.Items.Count;$i++){if($combo.Items[$i].Value -eq $frequency){$combo.SelectedIndex=$i;break}}
        $timer=New-Object Windows.Forms.Timer;$timer.Interval=100;$timer.Tag=$form
        $timer.Add_Tick({param($sender,$e) $sender.Stop();$save=@($sender.Tag.Controls | Where-Object {$_ -is [Windows.Forms.Button] -and $_.Text -eq '保存'})[0];$save.PerformClick()})
        $timer.Start();[void]$form.ShowDialog();$timer.Dispose();$opener.Dispose()
        $saved=Get-Content $SettingsPath -Raw | ConvertFrom-Json
        Assert "modal callback saves $frequency MHz" ($saved.modes.Idle.freqMax -eq $frequency -and $form.Tag.LastSaveError -eq '')
        Assert 'saved selection reaches worker immediately' ($Script:appliedFrequency -eq $frequency -and $Script:appliedMode -eq 'Idle')
        Assert 'save preserves CPU stability fields' ($saved.modes.Idle.boost -eq 0 -and $saved.modes.Idle.min -eq 50 -and $saved.modes.Game.freqMax -eq 0)
        Assert 'save preserves workstation and device-independent settings' ($saved.workstation.freqMax -eq 1800)
        $form.Dispose()
    }
}finally{
    if($form){$form.Dispose()}
    if(-not ([IO.Path]::GetFullPath($root)).StartsWith(([IO.Path]::GetTempPath()).TrimEnd('\')+'\ProfileSettingsTest-',[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected test directory'}
    Remove-Item -LiteralPath $root -Recurse -Force
}
