function Start-CloudHistoryJob {
    param($Form,[string]$Action)
    $tag=$Form.Tag
    if($tag.Process -and -not $tag.Process.HasExited){return}
    $python=Join-Path $ScriptDir '.codex\energy-cloud\Scripts\pythonw.exe'
    if(-not (Test-Path $python)){throw '历史查询组件尚未安装，请运行 Install-EnergyHistory.ps1。'}
    Remove-Item -LiteralPath (Join-Path $ScriptDir '.codex\energy-cloud-status.json') -ErrorAction SilentlyContinue
    $tag.LastStatus='';$tag.Status.Text='正在连接小米…'
    $tag.Process=Start-Process $python -WindowStyle Hidden -PassThru -ArgumentList @(('"{0}"' -f (Join-Path $ScriptDir 'PowerProfileCloudHistory.py')),$Action)
}
function Import-CloudHistorySelection {
    param($Form)
    $tag=$Form.Tag;$candidate=$tag.Sources.SelectedItem.Data
    if(-not $candidate){throw '请先查询历史。'}
    $multiplier=[double]$tag.Units.SelectedItem.Value;$days=@{}
    $today=[TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow,'China Standard Time').Date
    foreach($row in $candidate.rows){
        $date=[DateTimeOffset]::FromUnixTimeSeconds([long]$row.time).ToOffset([TimeSpan]::FromHours(8)).Date
        if($date -ge $today){continue}
        $value=if($row.value -is [string]){ConvertFrom-Json -InputObject $row.value}else{$row.value}
        if(@($value).Count -ne 1 -or @($value)[0] -is [bool]){throw '历史值格式不支持，未导入。'}
        $kwh=[double]@($value)[0]*$multiplier;$key=$date.ToString('yyyy-MM-dd')
        if($days.ContainsKey($key) -and $days[$key].KWh -ne $kwh){throw '同一天有冲突记录，未导入。'}
        $days[$key]=@{KWh=$kwh;Seconds=0;Source='MiHome'}
    }
    $content=@{DeviceId=$tag.Raw.DeviceId;Model=$tag.Raw.Model;Days=$days;Query=($candidate.key+':'+$candidate.data_type);Multiplier=$multiplier;FetchedAt=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json -Depth 8
    $count=$Script:EnergyService.ImportCloudHistory($content)
    $tag.Status.Text="已导入 $count 天历史；按当前电价计算，原本机记录保留。"
    Update-EnergyDetails
}
function Show-CloudHistory {
    param([switch]$ReturnForm)
    $form=New-Object Windows.Forms.Form;Initialize-ModernForm $form 'PowerProfile · 米家历史用电' 540 670
    $status=New-ModernLabel '手动查询，不增加后台轮询。请先扫码授权。' 18 15 502;$status.Height=45;$form.Controls.Add($status)
    $picture=New-Object Windows.Forms.PictureBox;$picture.SetBounds(140,66,260,260);$picture.SizeMode='Zoom';$form.Controls.Add($picture)
    $login=New-EnergyButton '扫码登录' 18 344 140;$form.Controls.Add($login)
    $query=New-EnergyButton '查询近一年历史' 174 344 174;$form.Controls.Add($query)
    $form.Controls.Add((New-ModernLabel '历史数据源' 18 396 130))
    $sources=New-Object Windows.Forms.ComboBox;$sources.SetBounds(154,393,364,27);$sources.DropDownStyle='DropDownList';$sources.DisplayMember='Label';$form.Controls.Add($sources)
    $form.Controls.Add((New-ModernLabel '原始值换算' 18 433 130))
    $units=New-WorkstationCombo $form 154 430 364 @(@(0.01,'原始值 × 0.01 度（插座 3 常见）'),@(0.001,'原始值 × 0.001 度'),@(1,'原始值已经是度')) 0.01
    $preview=New-ModernLabel '查询后显示最近完整日期的电量，先与米家核对。' 18 474 500;$preview.Height=64;$form.Controls.Add($preview)
    $hint=New-ModernLabel '只导入已结束日期；同日米家数据替代本机估算，不叠加。' 18 551 500;$hint.Height=44;$form.Controls.Add($hint)
    $import=New-EnergyButton '核对一致，导入' 18 615 190;$import.Enabled=$false;$form.Controls.Add($import)
    $close=New-EnergyButton '关闭' 410 615 110;$form.Controls.Add($close)
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=1000
    $form.Tag=@{Status=$status;Picture=$picture;Sources=$sources;Units=$units;Preview=$preview;Import=$import;Process=$null;LastStatus='';Raw=$null;Timer=$timer}
    $login.Add_Click({param($sender,$e) try{Start-CloudHistoryJob $sender.FindForm() login}catch{$sender.FindForm().Tag.Status.Text=$_.Exception.Message}})
    $query.Add_Click({param($sender,$e) try{Start-CloudHistoryJob $sender.FindForm() fetch}catch{$sender.FindForm().Tag.Status.Text=$_.Exception.Message}})
    $import.Add_Click({param($sender,$e) try{Import-CloudHistorySelection $sender.FindForm()}catch{$sender.FindForm().Tag.Status.Text=$_.Exception.Message}})
    $previewHandler={param($sender,$e) $t=$sender.FindForm().Tag;if($t.Sources.SelectedItem){$c=$t.Sources.SelectedItem.Data;$rows=@($c.rows | Sort-Object time -Descending | Select-Object -First 3);$lines=@();foreach($row in $rows){$date=[DateTimeOffset]::FromUnixTimeSeconds([long]$row.time).ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd');$v=if($row.value -is [string]){ConvertFrom-Json $row.value}else{$row.value};if(@($v).Count -eq 1){$lines+="${date}：$([Math]::Round([double]@($v)[0]*[double]$t.Units.SelectedItem.Value,3)) 度"}};$t.Preview.Text=$lines -join "`r`n"}}
    $sources.Add_SelectedIndexChanged($previewHandler);$units.Add_SelectedIndexChanged($previewHandler)
    $timer.Tag=$form
    $timer.Add_Tick({param($sender,$e) $t=$sender.Tag.Tag;$path=Join-Path $ScriptDir '.codex\energy-cloud-status.json';if(-not(Test-Path $path)){return};try{$content=[IO.File]::ReadAllText($path);if($content -eq $t.LastStatus){return};$t.LastStatus=$content;$s=$content|ConvertFrom-Json;$t.Status.Text=$s.message;if($s.phase -eq 'scan'){$loaded=[Drawing.Image]::FromFile($s.image);if($t.Picture.Image){$t.Picture.Image.Dispose()};$t.Picture.Image=$loaded.Clone();$loaded.Dispose()};if($s.phase -eq 'fetched'){$t.Raw=Get-Content (Join-Path $ScriptDir '.codex\energy-cloud-raw.json') -Raw -Encoding UTF8 | ConvertFrom-Json;$t.Sources.Items.Clear();foreach($c in $t.Raw.candidates){[void]$t.Sources.Items.Add([PSCustomObject]@{Label="$($c.key) / $($c.data_type) · $(@($c.rows).Count) 条";Data=$c})};$t.Sources.SelectedIndex=0;$t.Import.Enabled=$true}}catch{$t.Status.Text='读取查询结果失败，请重试。'}})
    $close.Add_Click({param($sender,$e) $sender.FindForm().Close()})
    $form.Add_FormClosed({param($sender,$e) $t=$sender.Tag;$t.Timer.Stop();$t.Timer.Dispose();if($t.Process -and -not $t.Process.HasExited){$t.Process.Kill()};if($t.Picture.Image){$t.Picture.Image.Dispose()};if($sender.Icon){$sender.Icon.Dispose()}})
    if($ReturnForm){return $form}
    $timer.Start();[void]$form.ShowDialog();$form.Dispose()
}
