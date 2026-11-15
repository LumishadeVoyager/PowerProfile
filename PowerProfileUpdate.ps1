# Release-only OTA: fetch in a separate process, install only on the next tray start.
$Script:ProfileReleaseRepo='LumishadeVoyager/PowerProfile'
function Read-ProfileUpdateState([string]$Path){if(Test-Path -LiteralPath $Path){return Read-AtomicJson $Path};return $null}
function Get-ProfileVersionInfo([string]$Root){
    $path=Join-Path $Root 'version.json'
    if(-not(Test-Path $path)){return [PSCustomObject]@{version='0.0.0';distribution='source'}}
    return (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function Get-ProfileUpdateOptions([string]$Root){
    $path=Join-Path $Root 'updates.settings.json'
    if(Test-Path $path){return Read-AtomicJson $path}
    return [PSCustomObject]@{enabled=((Get-ProfileVersionInfo $Root).distribution -eq 'release')}
}
function Test-ProfilePackagePath([string]$Path){
    # Data/configuration, helper scratch files and credentials can never be shipped.
    return $Path -cmatch '^(PowerProfile[A-Za-z0-9]*\.(ps1|cs|py)|[A-Z][A-Z_-]*\.md|RELEASE_NOTES_\d+\.\d+\.\d+\.md|version\.json|settings\.example\.json|workdays\.\d{4}\.json|Install(-EnergyHistory)?\.ps1|Uninstall\.ps1|Start-PowerProfile\.ps1|Check-PowerProfileUpdate\.ps1|Start-Tray\.vbs|_restart_tray\.ps1|Analyze-Usage\.ps1|legacy/PowerProfile(Tray|Detection|Logic)?\.ps1)$'
}
function Get-ProfileRelease {
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    try {return Invoke-RestMethod "https://api.github.com/repos/$Script:ProfileReleaseRepo/releases/latest" -Headers @{'User-Agent'='PowerProfile-Updater';Accept='application/vnd.github+json'} -TimeoutSec 25}
    catch {
        if(-not(Get-Command gh -ErrorAction SilentlyContinue)){throw '无法访问 GitHub Release。私有仓库需要获授权，并安装 GitHub CLI 后执行 gh auth login。公开仓库请检查网络。'}
        $raw=& gh api "repos/$Script:ProfileReleaseRepo/releases/latest" 2>$null
        if($LASTEXITCODE -ne 0){throw 'GitHub Release 不可访问，请检查网络或 gh 的仓库访问权限。'}
        return ($raw | ConvertFrom-Json)
    }
}
function Expand-ProfilePackage([string]$Zip,[string]$Destination){
    Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        if($archive.Entries.Count -gt 200){throw '更新包文件过多。'}
        $seen=@{};$size=0L
        foreach($entry in $archive.Entries){
            $name=$entry.FullName
            if($name -ne 'release-manifest.json' -and -not(Test-ProfilePackagePath $name)){throw "更新包包含不允许的路径：$name"}
            if($seen.ContainsKey($name)){throw '更新包包含重复文件。'};$seen[$name]=$true
            $size+=$entry.Length;if($size -gt 100MB){throw '更新包过大。'}
        }
        [IO.Compression.ZipFile]::ExtractToDirectory($Zip,$Destination)
    } finally {$archive.Dispose()}
}
function Test-ProfilePackage([string]$Directory,[string]$Version){
    $manifest=Get-Content (Join-Path $Directory 'release-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if($manifest.version -ne $Version -or $manifest.version -notmatch '^\d+\.\d+\.\d+$'){throw '更新包版本不匹配。'}
    $names=@{};$count=0
    foreach($file in @($manifest.files)){
        if(-not(Test-ProfilePackagePath $file.path) -or $names.ContainsKey([string]$file.path)){throw '更新清单路径无效或重复。'}
        $names[[string]$file.path]=$true;$count++
        $path=Join-Path $Directory $file.path
        if($file.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or -not(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.sha256){throw "文件完整性校验失败：$($file.path)"}
    }
    foreach($required in @('version.json','Start-PowerProfile.ps1','PowerProfileTray.ps1','PowerProfile.ps1','PowerProfileUpdate.ps1','PowerProfileCState.ps1','USER_GUIDE.md')){if(-not $names.ContainsKey($required)){throw "更新包缺少：$required"}}
    if([version]$Version -ge [version]'1.2.0'){foreach($required in @('PowerProfileWorkspace.cs','PowerProfileWorkspace.ps1','PowerProfileWorkspaceData.ps1','PowerProfileWorkspaceCharts.cs','PowerProfileConnectionUI.ps1','PowerProfileConnectionProbe.py')){if(-not $names.ContainsKey($required)){throw "工作台更新包缺少：$required"}}}
    if([version]$Version -ge [version]'1.3.0'){foreach($required in @('PowerProfileGameAnalytics.cs','PowerProfileInsights.ps1','PowerProfileInsightsUI.cs')){if(-not $names.ContainsKey($required)){throw "分析更新包缺少：$required"}}}
    if(@(Get-ChildItem $Directory -Recurse -File).Count -ne $count+1){throw '更新包有清单外文件。'}
    $info=Get-ProfileVersionInfo $Directory
    if($info.version -ne $Version -or $info.distribution -ne 'release'){throw '更新包不是正式分发版本。'}
    return $manifest
}
function Invoke-ProfileUpdateCheck([string]$Root,[switch]$Manual){
    $dir=Join-Path $Root '.updates';[void][IO.Directory]::CreateDirectory($dir)
    $statePath=Join-Path $dir 'status.json';$mutex=New-Object Threading.Mutex($false,'Local\PowerProfile_UpdateCheck');$locked=$false
    try {
        try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true};if(-not $locked){return}
        if(-not $Manual -and -not (Get-ProfileUpdateOptions $Root).enabled){return}
        $old=Read-ProfileUpdateState $statePath
        if(-not $Manual -and $old.checkedAt -and ([DateTime]::UtcNow-([DateTime]$old.checkedAt).ToUniversalTime()).TotalHours -lt 24){return}
        $now=[DateTime]::UtcNow.ToString('o')
        try {
            $release=Get-ProfileRelease
            if($release.draft -or $release.prerelease -or $release.tag_name -notmatch '^v(\d+\.\d+\.\d+)$'){throw '没有可用的稳定版 Release。'}
            $version=$Matches[1];$current=Get-ProfileVersionInfo $Root
            if([version]$version -le [version]$current.version){Write-AtomicJson $statePath @{phase='current';checkedAt=$now;message='已是最新稳定版';version=$current.version};return}
            if($current.distribution -ne 'release' -or (Test-Path (Join-Path $Root '.git'))){Write-AtomicJson $statePath @{phase='available';checkedAt=$now;message="发现 v$version；源码 / Git 目录请通过 Git 更新，不下载或覆盖。";version=$version};return}
            $name="PowerProfile-$version-windows.zip"
            $asset=@($release.assets | Where-Object {$_.name -ceq $name -and $_.state -eq 'uploaded'})
            if($asset.Count -ne 1 -or $asset[0].digest -notmatch '^sha256:([a-fA-F0-9]{64})$'){throw 'Release 缺少正式安装包或 GitHub SHA-256 摘要。'}
            $expectedHash=$Matches[1];$asset=$asset[0]
            if($asset.browser_download_url -cne "https://github.com/$Script:ProfileReleaseRepo/releases/download/v$version/$name"){throw '更新来源无效。'}
            $download=Join-Path $dir ('download-'+[Guid]::NewGuid());[void][IO.Directory]::CreateDirectory($download)
            try {
                $zip=Join-Path $download $name
                try{Invoke-WebRequest $asset.browser_download_url -UseBasicParsing -OutFile $zip -TimeoutSec 60}
                catch {
                    if(-not(Get-Command gh -ErrorAction SilentlyContinue)){throw}
                    & gh release download "v$version" --repo $Script:ProfileReleaseRepo --pattern $name --dir $download --clobber 2>$null
                    if($LASTEXITCODE -ne 0){throw '更新包下载失败。'}
                }
                if((Get-FileHash $zip -Algorithm SHA256).Hash -ne $expectedHash){throw '更新包 SHA-256 与 GitHub 摘要不符，已拒绝安装。'}
                $stage=Join-Path $download 'package';Expand-ProfilePackage $zip $stage
                [void](Test-ProfilePackage $stage $version)
                $pending=Join-Path $dir 'pending'
                if(Test-Path $pending){Remove-Item -LiteralPath $pending -Recurse -Force}
                Move-Item -LiteralPath $stage -Destination $pending
                Write-AtomicJson $statePath @{phase='ready';checkedAt=$now;message="v$version 已下载并校验，下次启动托盘安装";version=$version}
            } finally {if(Test-Path $download){Remove-Item -LiteralPath $download -Recurse -Force}}
        } catch {Write-AtomicJson $statePath @{phase='error';checkedAt=$now;message=$_.Exception.Message}}
    } finally {if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
function Restore-ProfileUpdate([string]$Root){
    $dir=Join-Path $Root '.updates';$transaction=Read-ProfileUpdateState (Join-Path $dir 'transaction.json')
    if(-not $transaction -or $transaction.phase -ne 'applying'){return}
    foreach($file in @($transaction.files)){
        if(-not(Test-ProfilePackagePath $file.path)){throw '回滚清单路径无效。'}
        $target=Join-Path $Root $file.path
        if($file.existed){Copy-Item -LiteralPath (Join-Path $dir ('backup/'+$file.path)) -Destination $target -Force}
        elseif(Test-Path $target){Remove-Item -LiteralPath $target -Force}
    }
    $transaction.phase='rolledBack';Write-AtomicJson (Join-Path $dir 'transaction.json') $transaction
    Write-AtomicJson (Join-Path $dir 'status.json') @{phase='error';checkedAt=[DateTime]::UtcNow.ToString('o');message='上次更新未启动成功，已恢复原版本；请重新检查更新。'}
}
function Install-ProfilePendingUpdate([string]$Root){
    # Source/git checkouts are never modified by OTA, including manual checks.
    if(Test-Path (Join-Path $Root '.git')){return}
    $previous=Read-ProfileUpdateState (Join-Path $Root '.updates/transaction.json')
    # Restore a torn update even if version.json itself was interrupted.
    if($previous.phase -ne 'applying' -and (Get-ProfileVersionInfo $Root).distribution -ne 'release'){return}
    $ready=Read-ProfileUpdateState (Join-Path $Root 'tray_ready.json')
    if($ready.processId -and (Get-Process -Id $ready.processId -ErrorAction SilentlyContinue)){return}
    $downloadMutex=New-Object Threading.Mutex($false,'Local\PowerProfile_UpdateCheck');$downloadLocked=$false
    $mutex=New-Object Threading.Mutex($false,'Global\PowerProfile_Worker');$locked=$false
    try {
        try{$downloadLocked=$downloadMutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$downloadLocked=$true};if(-not $downloadLocked){return}
        try{$locked=$mutex.WaitOne(30000)}catch [Threading.AbandonedMutexException]{$locked=$true};if(-not $locked){return}
        Restore-ProfileUpdate $Root
        $dir=Join-Path $Root '.updates';$pending=Join-Path $dir 'pending'
        if(-not(Test-Path $pending)){return}
        $version=(Get-ProfileVersionInfo $pending).version
        if([version]$version -le [version](Get-ProfileVersionInfo $Root).version){Remove-Item -LiteralPath $pending -Recurse -Force;return}
        $manifest=Test-ProfilePackage $pending $version
        $files=@()
        foreach($file in $manifest.files){
            $target=Join-Path $Root $file.path;$backup=Join-Path $dir ('backup/'+$file.path)
            $exists=Test-Path -LiteralPath $target
            if($exists){[void][IO.Directory]::CreateDirectory((Split-Path -Parent $backup));Copy-Item -LiteralPath $target -Destination $backup -Force}
            $files+=@{path=$file.path;existed=$exists}
        }
        Write-AtomicJson (Join-Path $dir 'transaction.json') @{phase='applying';version=$version;files=$files}
        try {
            foreach($file in $manifest.files){$target=Join-Path $Root $file.path;[void][IO.Directory]::CreateDirectory((Split-Path -Parent $target));Copy-Item -LiteralPath (Join-Path $pending $file.path) -Destination $target -Force}
            Remove-Item -LiteralPath $pending -Recurse -Force
        } catch {Restore-ProfileUpdate $Root;throw}
    } finally {if($locked){$mutex.ReleaseMutex()};$mutex.Dispose();if($downloadLocked){$downloadMutex.ReleaseMutex()};$downloadMutex.Dispose()}
}
function Confirm-ProfileUpdate([string]$Root){
    $dir=Join-Path $Root '.updates';$transaction=Read-ProfileUpdateState (Join-Path $dir 'transaction.json')
    if($transaction.phase -eq 'applying'){
        $transaction.phase='complete';Write-AtomicJson (Join-Path $dir 'transaction.json') $transaction
        Write-AtomicJson (Join-Path $dir 'status.json') @{phase='current';checkedAt=[DateTime]::UtcNow.ToString('o');message="已更新至 v$($transaction.version)";version=$transaction.version}
    }
}
