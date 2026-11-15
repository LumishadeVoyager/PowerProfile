function Get-WorkspaceNetworkReadiness {
    $lines=@('● Windows 本地监测组件可用','● 插座验证只读取型号、身份、开关与功率','','本机当前网络：')
    foreach($adapter in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()){
        if($adapter.OperationalStatus -ne 'Up' -or $adapter.NetworkInterfaceType -eq 'Loopback'){continue}
        $addresses=@($adapter.GetIPProperties().UnicastAddresses|Where-Object {$_.Address.AddressFamily -eq 'InterNetwork'}|ForEach-Object {$_.Address.IPAddressToString})
        if($addresses.Count){$lines+=($adapter.Name+' · '+($addresses -join '，'))}
    }
    $lines+=@('','接入前准备：','1. 插座已在米家 App 配对并保持联网。','2. 电脑与插座在同一局域网，避免访客网络隔离。','3. 准备路由器中显示的 IP 与自己的设备 Token。','4. 验证通过后再设置电价并保存。')
    return $lines -join "`r`n"
}
function Update-WorkspaceConnection($Form){
    $t=$Form.Tag
    if($t.Probe){
        $Form.ProbeStatus.Text=$t.Probe.Phase+"`r`n"+$t.Probe.Message
        if($t.Probe.Completed){$Form.Verify.Enabled=$true;$Form.SaveConnection.Enabled=$t.Probe.Success -and -not $Script:EnergyService.GetSnapshot().Busy;$t.VerifiedAddress=$t.Probe.Address
            if($t.Probe.Success){$Form.ProbeStatus.Text+="`r`n实际开关：$(if($t.Probe.On){'开启'}else{'关闭'}) · 功率：$(if($null -ne $t.Probe.Watts){'{0:N1} W' -f $t.Probe.Watts}else{'未提供'})`r`n没有向插座发送任何开关指令。"}
        }
    }
    $root=Get-WorkspaceRoot;$installed=Test-Path (Join-Path $ScriptDir '.codex\energy-cloud\Scripts\pythonw.exe');$auth=Test-Path (Join-Path $root '.codex\energy-cloud-auth.bin');$hub=Get-WorkspaceHub
    $Form.InstallCloud.Enabled=-not $installed -and -not ($t.InstallProcess -and -not $t.InstallProcess.HasExited);$Form.Login.Enabled=$installed;$Form.Sync.Enabled=$installed -and $auth
    $cloudProbe=if($t.CloudProcess){Read-WorkspaceJson (Join-Path $root '.codex\connection-probe.json')}else{$null}
    $Form.Sync.Enabled=$installed -and $auth -and -not ($t.CloudProcess -and -not $t.CloudProcess.HasExited)
    $Form.CloudStatus.Text=if($t.InstallProcess -and -not $t.InstallProcess.HasExited){'◷ 正在安装可选组件；窗口保持响应。完成后自动更新状态。'}elseif($t.InstallProcess -and $t.InstallProcess.HasExited -and $t.InstallProcess.ExitCode -ne 0){'! 安装未完成：检查 Python 3.10+、网络及安装日志；可重试。'}elseif($t.CloudProcess -and -not $t.CloudProcess.HasExited){'◷ 正在只读检查授权、设备能力和状态；不会启动或执行任务。'}elseif($cloudProbe.phase -eq 'connected'){'✓ '+$cloudProbe.message+" · $($cloudProbe.devices) 台设备，$($cloudProbe.controllable) 台提供通用开关"}elseif($cloudProbe.phase -eq 'error'){'! '+$cloudProbe.message}elseif(-not $installed){'○ 尚未安装云端组件。本地监测可直接使用。'}elseif(-not $auth){'○ 云端组件已安装，尚未扫码授权。'}elseif($hub.Fresh -and $hub.Config.enabled){'● 中枢响应正常；设备状态以实际读回为准。'}else{'○ 已保存加密授权，尚未确认有效；点击同步设备进行检查。'}
}
function Show-WorkspaceConnectionWizard {
    param([switch]$ReturnForm)
    Initialize-EnergyService;$form=New-Object ProfileConnectForm;$state=$Script:EnergyService.GetSnapshot();$form.Address.Text=$Script:EnergyService.Address;if($null -ne $state.Price){$form.Price.Value=$state.Price}
    $form.Readiness.Text=Get-WorkspaceNetworkReadiness;$form.ProbeStatus.Text='在连接信息页填写 IP 与 Token，点击开始只读验证。只有型号、身份和实际读取通过，才可保存。'
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=1000;$form.Tag=@{Probe=$null;Timer=$timer;InstallProcess=$null;CloudProcess=$null;VerifiedAddress=''}
    $form.add_Command({param($sender,$eventArgs) $t=$sender.Tag
        try{
            switch($eventArgs.Action){
                'InputChanged'{$t.Probe=$null;$t.VerifiedAddress='';$sender.SaveConnection.Enabled=$false;$sender.Verify.Enabled=$true;$sender.ProbeStatus.Text='连接信息已变化，请重新验证。'}
                'Probe'{$t.Probe=$Script:EnergyService.TestConnection($sender.Address.Text.Trim(),$sender.Token.Text);$sender.Verify.Enabled=$false;$sender.SaveConnection.Enabled=$false;$sender.ProbeStatus.Text='◷ 正在读取设备；不会切换插座。'}
                'Save'{if(-not $t.Probe -or -not $t.Probe.Completed -or -not $t.Probe.Success -or $t.VerifiedAddress -ne $sender.Address.Text.Trim()){throw '请先验证当前连接信息。'};$Script:EnergyService.Configure($sender.Address.Text.Trim(),$sender.Token.Text,[decimal]$sender.Price.Value);$sender.Token.Clear();$sender.ProbeStatus.Text='✓ 配置已保存；插座正在后台监测。';$sender.Steps.SelectedIndex=4;if($Script:Workspace){$Script:Workspace.Tag.EnergyKey=''}}
                'Install'{$logDir=Join-Path (Get-WorkspaceRoot) '.codex';[void][IO.Directory]::CreateDirectory($logDir);$t.InstallProcess=Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f (Join-Path $ScriptDir 'Install-EnergyHistory.ps1'))) -RedirectStandardOutput (Join-Path $logDir 'cloud-component-install.log') -RedirectStandardError (Join-Path $logDir 'cloud-component-install-error.log')}
                'Login'{$cloud=Show-CloudHistory -ReturnForm;$cloud.Tag.Timer.Start();try{[ProfileTheme]::Apply($cloud,[ProfileTheme]::Dark);[void]$cloud.ShowDialog($sender)}finally{$cloud.Dispose()}}
                'Sync'{$status=Join-Path (Get-WorkspaceRoot) '.codex\connection-probe.json';Remove-Item -LiteralPath $status -ErrorAction SilentlyContinue;$t.CloudProcess=Start-Process (Join-Path $ScriptDir '.codex\energy-cloud\Scripts\pythonw.exe') -WindowStyle Hidden -PassThru -ArgumentList @(('"{0}"' -f (Join-Path $ScriptDir 'PowerProfileConnectionProbe.py')),'--root',('"{0}"' -f (Get-WorkspaceRoot)))}
            }
        }catch{$errorDetail=$_.Exception.GetBaseException();$sender.ProbeStatus.Text='! '+$(if($errorDetail -is [FormatException]){'Token 必须为 32 位十六进制字符；请确认没有空格或把账号密码填入。'}else{$errorDetail.Message});$sender.Steps.SelectedIndex=2;$sender.Verify.Enabled=$true}
    })
    $timer.Tag=$form;$timer.Add_Tick({param($sender,$eventArgs) try{Update-WorkspaceConnection $sender.Tag}catch{$sender.Tag.CloudStatus.Text='! 状态暂不可读，稍后重试。'}})
    $form.Add_FormClosed({param($sender,$eventArgs) $sender.Tag.Timer.Stop();$sender.Tag.Timer.Dispose();$sender.Token.Clear()})
    Update-WorkspaceConnection $form;$timer.Start()
    if($ReturnForm){return $form};Show-WorkspaceDialog $form
}
