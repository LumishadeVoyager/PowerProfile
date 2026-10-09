function Initialize-ProfileLogging {
    param([string]$Root,[string]$Component,[string]$OperationId='')
    $Script:ProfileLogRoot=$Root
    $Script:ProfileLogComponent=$Component
    $Script:ProfileOperationId=if($OperationId){$OperationId}else{[Guid]::NewGuid().ToString()}
    $Script:ProfileBuildHash=Get-ProfileFileHash (Join-Path $Root 'PowerProfile.ps1')
    $Script:ProfileSettingsHash=Get-ProfileFileHash (Join-Path $Root 'settings.json')
}
function Get-ProfileFileHash {
    param([string]$Path)
    $stream=$null;$hash=$null
    try {
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $hash=[Security.Cryptography.SHA256]::Create()
        return ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-','')
    } catch { return '' }
    finally {if($stream){$stream.Dispose()};if($hash){$hash.Dispose()}}
}
function Write-ProfileEvent {
    param([string]$Event,[string]$Message,[ValidateSet('INFO','WARN','ERROR')][string]$Level='INFO',$Data=@{})
    if(-not $Script:ProfileLogRoot){return}
    $mutex=$null;$held=$false
    try {
        $mutex=New-Object Threading.Mutex($false,'Global\PowerProfile_Log')
        try{$held=$mutex.WaitOne(2000)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){return}
        $directory=Join-Path $Script:ProfileLogRoot 'logs'
        [void][IO.Directory]::CreateDirectory($directory)
        $now=Get-Date
        $record=[ordered]@{schemaVersion=1;timestamp=$now.ToUniversalTime().ToString('o');localTime=$now.ToString('yyyy-MM-dd HH:mm:ss.fff zzz');level=$Level;component=$Script:ProfileLogComponent;event=$Event;operationId=$Script:ProfileOperationId;pid=$PID;version='Modern';build='2026.10-workstation.1';workerSha256=$Script:ProfileBuildHash;settingsSha256=$Script:ProfileSettingsHash;message=$Message;data=$Data}
        $stem=Join-Path $directory ('PowerProfile-'+$now.ToString('yyyy-MM-dd'))
        foreach($extension in @('.jsonl','.log')) {
            $path=$stem+$extension
            if((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -ge 5MB){
                for($i=2;$i -ge 1;$i--){if(Test-Path -LiteralPath "$path.$i"){Move-Item -LiteralPath "$path.$i" -Destination "$path.$($i+1)" -Force}}
                Move-Item -LiteralPath $path -Destination "$path.1" -Force
            }
        }
        $encoding=New-Object Text.UTF8Encoding $true
        $details=ConvertTo-Json -InputObject $Data -Depth 8 -Compress
        [IO.File]::AppendAllText(($stem+'.jsonl'),((ConvertTo-Json $record -Depth 10 -Compress)+[Environment]::NewLine),$encoding)
        $line='{0} [{1}] [{2}/{3}] 操作={4} PID={5} | {6} | {7}' -f $record.localTime,$Level,$Script:ProfileLogComponent,$Event,$Script:ProfileOperationId,$PID,($Message -replace '[\r\n]+',' '),$details
        [IO.File]::AppendAllText(($stem+'.log'),($line+[Environment]::NewLine),$encoding)
        # Cleanup only files with our fixed names, contained in this installation's logs folder.
        if($Script:LogCleanupDay -ne $now.Date){
            $prefix=[IO.Path]::GetFullPath($directory).TrimEnd('\')+'\'
            foreach($file in @(Get-ChildItem -LiteralPath $directory -File)){
                if($file.Name -match '^PowerProfile-\d{4}-\d{2}-\d{2}\.(log|jsonl)(\.[123])?$' -and $file.LastWriteTime -lt $now.AddDays(-14) -and $file.FullName.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {Remove-Item -LiteralPath $file.FullName}
            }
            $Script:LogCleanupDay=$now.Date
        }
    } catch { Write-Verbose "Logging unavailable: $_" }
    finally {if($held){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}}
}
