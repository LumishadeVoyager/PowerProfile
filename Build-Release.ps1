param([string]$Source=$PSScriptRoot,[string]$Output=(Join-Path $PSScriptRoot 'dist'))
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'PowerProfileUpdate.ps1')
$version=(Get-ProfileVersionInfo $Source).version
if($version -notmatch '^\d+\.\d+\.\d+$'){throw 'Invalid release version'}
[void][IO.Directory]::CreateDirectory($Output)
$stage=Join-Path ([IO.Path]::GetTempPath()) ('PowerProfile-Release-'+[Guid]::NewGuid());[void][IO.Directory]::CreateDirectory($stage)
try {
    $files=@(Get-ChildItem -LiteralPath $Source -File | ForEach-Object {$_.Name})
    $files+=@(Get-ChildItem -LiteralPath (Join-Path $Source 'legacy') -Filter '*.ps1' -File | ForEach-Object {'legacy/'+$_.Name})
    $manifestFiles=@()
    foreach($file in ($files | Sort-Object)){
        if(-not(Test-ProfilePackagePath $file)){continue}
        $destination=Join-Path $stage $file;[void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
        Copy-Item -LiteralPath (Join-Path $Source $file) -Destination $destination
        if($file -eq 'version.json'){@{version=$version;distribution='release'}|ConvertTo-Json|Set-Content -LiteralPath $destination -Encoding UTF8}
        $manifestFiles+=@{path=$file;sha256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
    @{version=$version;files=$manifestFiles}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $stage 'release-manifest.json') -Encoding UTF8
    [void](Test-ProfilePackage $stage $version)
    $zip=Join-Path $Output "PowerProfile-$version-windows.zip"
    Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
    if(Test-Path $zip){Remove-Item -LiteralPath $zip}
    $archive=[IO.Compression.ZipFile]::Open($zip,[IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach($file in @($manifestFiles.path)+@('release-manifest.json')){[void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,(Join-Path $stage $file),$file,[IO.Compression.CompressionLevel]::Optimal)}
    } finally {$archive.Dispose()}
    $hash=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $([IO.Path]::GetFileName($zip))" | Set-Content -LiteralPath ($zip+'.sha256') -Encoding ASCII
    Write-Host "Built $zip ($($manifestFiles.Count) program/document files); SHA256 $hash"
} finally {Remove-Item -LiteralPath $stage -Recurse -Force}
