# Opt-in workaround. Merely loading this file never changes a power setting.
function Read-CStatePower {
    $scheme=(& powercfg.exe /GETACTIVESCHEME | Out-String)
    if($LASTEXITCODE -ne 0 -or $scheme -notmatch '[0-9a-fA-F-]{36}'){throw '无法读取当前电源计划。'}
    $id=$Matches[0]
    $text=(& powercfg.exe /Q $id SUB_PROCESSOR 5d76a2ca-e8c0-402f-a133-2158492d58ad | Out-String)
    $values=[regex]::Matches($text,'0x([0-9a-fA-F]{8})')
    if($LASTEXITCODE -ne 0 -or $values.Count -lt 2){throw '此电脑未提供可验证的 CPU 空闲状态设置。'}
    return @{scheme=$id;ac=[Convert]::ToInt32($values[$values.Count-2].Groups[1].Value,16);dc=[Convert]::ToInt32($values[$values.Count-1].Groups[1].Value,16)}
}
function Invoke-CStatePower {
    param([string]$Scheme,[int]$AC,[int]$DC)
    foreach($pair in @(@('/SETACVALUEINDEX',$AC),@('/SETDCVALUEINDEX',$DC))){
        $result=& powercfg.exe $pair[0] $Scheme SUB_PROCESSOR 5d76a2ca-e8c0-402f-a133-2158492d58ad $pair[1] 2>&1
        if($LASTEXITCODE -ne 0){throw "无法应用 CPU 空闲设置：$result"}
    }
    $result=& powercfg.exe /SETACTIVE $Scheme 2>&1
    if($LASTEXITCODE -ne 0){throw "无法激活电源计划：$result"}
}
function Get-CStateOptions {
    param([string]$Root)
    $path=Join-Path $Root 'cstate.settings.json'
    if(Test-Path $path){return Read-AtomicJson $path}
    return [PSCustomObject]@{enabled=$false;acknowledged=$false;baseline=$null}
}
function Set-CStateProtection {
    param([string]$Root,[bool]$Enabled,[bool]$Acknowledged)
    if($Enabled -and -not $Acknowledged){throw '请先勾选已理解 C-state 稳定性保护的作用及影响。'}
    $mutex=New-Object Threading.Mutex($false,'Global\PowerProfile_Worker');$locked=$false
    try {
        try{$locked=$mutex.WaitOne(30000)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(-not $locked){throw '电源切换正忙，请稍后重试。'}
        $old=Get-CStateOptions $Root
        if([bool]$old.enabled -eq $Enabled){return}
        if(Get-Command Restore-WorkstationOverlay -ErrorAction SilentlyContinue){Restore-WorkstationOverlay $Root '调整 C-state 稳定性保护'}
        $before=Read-CStatePower
        $baseline=if($Enabled){$before}else{$old.baseline}
        if(-not $Enabled -and (-not $baseline -or $baseline.scheme -ne $before.scheme)){throw '电源计划已变化；请先切回启用保护时的电源计划再关闭，避免改动其他计划。'}
        $ac=if($Enabled){1}else{[int]$baseline.ac};$dc=if($Enabled){1}else{[int]$baseline.dc}
        try {
            Invoke-CStatePower $before.scheme $ac $dc
            $after=Read-CStatePower
            if($after.scheme -ne $before.scheme -or $after.ac -ne $ac -or $after.dc -ne $dc){throw 'CPU 空闲设置读回校验失败。'}
            Write-AtomicJson (Join-Path $Root 'cstate.settings.json') @{enabled=$Enabled;acknowledged=$Acknowledged;baseline=$baseline;updatedAt=[DateTime]::UtcNow.ToString('o')} -Pretty
        } catch {
            $failure=$_;Invoke-CStatePower $before.scheme $before.ac $before.dc;throw $failure
        }
    } finally {if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
