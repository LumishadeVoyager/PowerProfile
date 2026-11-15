$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$project=Split-Path -Parent $PSScriptRoot
$root=Join-Path $env:TEMP ('PowerProfileHubTests-'+[Guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($root)
$ScriptDir=$project;$SettingsPath=Join-Path $root 'settings.json'
Copy-Item (Join-Path $project 'settings.example.json') $SettingsPath
function Assert($Name,$Value){if(-not $Value){throw $Name};Write-Host "PASS $Name"}
try{
    . (Join-Path $project 'PowerProfileModernUI.ps1')
    $Script:WorkerStarts=0
    function Start-DeviceHubWorker {$Script:WorkerStarts++}
    Assert 'hub defaults to opt-in with no background worker' (-not (Get-DeviceHubConfig).enabled -and $Script:WorkerStarts -eq 0)
    $light=[PSCustomObject]@{did='lamp';name='Test light';model='test.light.v1';switch=@{siid=2;piid=1};state=$false;message='关闭'}
    $computer=[PSCustomObject]@{did='pc-plug';name='Computer plug';model='cuco.plug.v3';switch=@{siid=2;piid=1};state=$false;computerPower=$true;isPlug=$true;message='关闭'}
    $statusPath=Join-Path $root '.codex\device-hub\status.json'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $statusPath))
    Write-AtomicJson $statusPath @{pid=0;observedAt=[DateTime]::UtcNow.ToString('o');message='已连接';devices=@($light,$computer);rules=@{};events=@()}
    Show-DeviceHub
    Assert 'hub window shows discovered device inventory' ($Script:DeviceHubForm.Visible -and $Script:DeviceHubForm.Tag.Devices.Rows.Count -eq 2)
    Assert 'paused hub cannot send manual commands' (-not $Script:DeviceHubForm.Tag.On.Enabled)
    $config=Get-DeviceHubConfig;$config.enabled=$true;Save-DeviceHubConfig $config;Update-DeviceHubWindow
    Assert 'verified switch enables device actions' $Script:DeviceHubForm.Tag.Off.Enabled
    $Script:DeviceHubForm.Tag.Devices.CurrentCell=$Script:DeviceHubForm.Tag.Devices.Rows[1].Cells[0]
    Assert 'verified computer plug supports switching and scheduling' ($Script:DeviceHubForm.Tag.On.Enabled -and $Script:DeviceHubForm.Tag.Add.Enabled)
    $denied=$false;try{Send-DeviceHubRequest 'set' $computer $false}catch{$denied=$true}
    Assert 'unconfirmed manual power cut rejected before queue' $denied
    $Script:DeviceHubForm.Tag.Devices.CurrentCell=$Script:DeviceHubForm.Tag.Devices.Rows[0].Cells[0]
    Send-DeviceHubRequest 'set' $light $false
    $request=Get-ChildItem (Join-Path $root '.codex\device-hub\queue') -Filter *.json | Select-Object -First 1
    $queued=Read-AtomicJson $request.FullName
    Assert 'manual operation is queued with identity and expiry timestamp' ($queued.did -eq 'lamp' -and $queued.value -eq $false -and $queued.createdAt)
    $editor=Show-HubRuleEditor $light -ReturnForm
    $editor.Show();[Windows.Forms.Application]::DoEvents()
    $save=@($editor.Controls | Where-Object {$_.Text -eq '保存并启用'})[0];$save.PerformClick()
    $saved=Get-DeviceHubConfig
    Assert 'editor saves a concrete midnight guard with end time' (@($saved.rules).Count -eq 1 -and $saved.rules[0].startMinute -eq 0 -and $saved.rules[0].endMinute -eq 420 -and $saved.rules[0].value -eq $false)
    $night=$saved.rules[0]
    $day=[PSCustomObject]@{did='lamp';value=$true;enabled=$true;mode='once';startMinute=480;endMinute=$null}
    Assert 'daytime action can coexist with night guard' (-not (Test-HubRulesConflict $night $day))
    $day.startMinute=120
    Assert 'opposing action inside guard window is rejected' (Test-HubRulesConflict $night $day)
    $Script:DeviceHubForm.Tag.Rules.CurrentCell=$Script:DeviceHubForm.Tag.Rules.Rows[0].Cells[0]
    $toggle=@($Script:DeviceHubForm.Controls | Where-Object {$_.Text -eq '启用 / 暂停'})[0];$toggle.PerformClick()
    Assert 'pausing a task is saved with a new runtime revision' (-not (Get-DeviceHubConfig).rules[0].enabled -and (Get-DeviceHubConfig).rules[0].revision)
    $Script:DeviceHubForm.Tag.Pause.PerformClick()
    Assert 'global pause disables automation without a device command' (-not (Get-DeviceHubConfig).enabled -and @(Get-ChildItem (Join-Path $root '.codex\device-hub\queue') -Filter *.json).Count -eq 1)
    $Script:DeviceHubForm.Tag.Pause.PerformClick()
    $editor.Dispose()
    foreach($form in @($Script:DeviceHubForm)){
        foreach($control in $form.Controls){Assert 'hub controls fit scrollable canvas' ($control.Right -le $form.DisplayRectangle.Width -and $control.Bottom -le $form.DisplayRectangle.Height)}
    }
    if($env:POWERPROFILE_HUB_PREVIEW){
        Update-DeviceHubWindow
        $bitmap=New-Object Drawing.Bitmap $Script:DeviceHubForm.Width,$Script:DeviceHubForm.Height
        try{$Script:DeviceHubForm.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle 0,0,$bitmap.Width,$bitmap.Height));$bitmap.Save($env:POWERPROFILE_HUB_PREVIEW)}finally{$bitmap.Dispose()}
    }
    $Script:DeviceHubForm.Close()
    Assert 'closing hub leaves saved tasks intact' (@((Get-DeviceHubConfig).rules).Count -eq 1)
    $editor=Show-HubRuleEditor $computer -ReturnForm;$editor.Show();[Windows.Forms.Application]::DoEvents()
    Assert 'plug editor has risk confirmation unchecked and save blocked' ($editor.Tag.Risk.Visible -and -not $editor.Tag.Risk.Checked -and -not $editor.Tag.Save.Enabled)
    for($i=0;$i -lt $editor.Tag.Mode.Items.Count;$i++){if($editor.Tag.Mode.Items[$i].Value -eq 'countdown'){$editor.Tag.Mode.SelectedIndex=$i;break}}
    Assert 'countdown enables duration and disables recurring controls' ($editor.Tag.Delay.Enabled -and -not $editor.Tag.Days.Enabled -and -not $editor.Tag.Start.Enabled)
    $editor.Tag.Delay.Value=10;$editor.Tag.Risk.Checked=$true;$editor.Tag.Save.PerformClick()
    $saved=Get-DeviceHubConfig;$countdown=@($saved.rules|Where-Object {$_.did -eq 'pc-plug'})[0]
    $remaining=((Get-HubRunAt $countdown)-[DateTimeOffset]::UtcNow).TotalMinutes
    Assert 'countdown persists absolute deadline and explicit risk acknowledgement' ($countdown.mode -eq 'at' -and $remaining -gt 9 -and $remaining -le 10 -and $countdown.powerRiskAcknowledged)
    Assert 'timer save does not issue an immediate device command' (@(Get-ChildItem (Join-Path $root '.codex\device-hub\queue') -Filter *.json).Count -eq 1)
    $editor.Dispose()
    $editor=Show-HubRuleEditor $computer $countdown -ReturnForm;$editor.Show();[Windows.Forms.Application]::DoEvents()
    Assert 'reopening countdown preserves deadline but asks risk acknowledgement again' ($editor.Tag.Mode.SelectedItem.Value -eq 'at' -and -not $editor.Tag.Risk.Checked -and -not $editor.Tag.Save.Enabled)
    $editor.Dispose()
    $editor=Show-HubRuleEditor $light -ReturnForm;$editor.Show();[Windows.Forms.Application]::DoEvents()
    for($i=0;$i -lt $editor.Tag.Mode.Items.Count;$i++){if($editor.Tag.Mode.Items[$i].Value -eq 'once'){$editor.Tag.Mode.SelectedIndex=$i;break}}
    for($i=0;$i -lt 7;$i++){$editor.Tag.Days.SetItemChecked($i,$i -ge 5)}
    $editor.Tag.Start.Value=[DateTime]::Today.AddHours(8);$editor.Tag.Save.PerformClick();$saved=Get-DeviceHubConfig
    $weekly=@($saved.rules|Where-Object {$_.mode -eq 'once'})[0]
    Assert 'weekday selection is persisted as ISO weekend days' (($weekly.days -join ',') -eq '6,7' -and $weekly.startMinute -eq 480)
    Assert 'rule description names actual weekend schedule' ((Format-HubRule $weekly) -like '周末 08:00*')
    $editor.Dispose()
    $monday=[PSCustomObject]@{did='cross';value=$false;enabled=$true;mode='guard';days=@(1);startMinute=1380;endMinute=420}
    $tuesday=[PSCustomObject]@{did='cross';value=$true;enabled=$true;mode='once';days=@(2);startMinute=120;endMinute=$null}
    Assert 'UI conflict detection includes following day of cross-midnight guard' (Test-HubRulesConflict $monday $tuesday)
    $tuesday.days=@(1);Assert 'UI allows same time on different effective day' (-not(Test-HubRulesConflict $monday $tuesday))
}finally{
    if($Script:DeviceHubForm){$Script:DeviceHubForm.Close()}
    if($Script:EnergyService){$Script:EnergyService.Dispose()}
    if($Script:EnergyLogTimer){$Script:EnergyLogTimer.Dispose()}
    if(-not ([IO.Path]::GetFullPath($root)).StartsWith(([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\PowerProfileHubTests-'),[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected cleanup path'}
    Remove-Item -LiteralPath $root -Recurse -Force
}
