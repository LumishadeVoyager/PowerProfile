[CmdletBinding()]
param([string]$LogPath = '')
# Read-only local report. Switch counts are diagnostic evidence, not play-time estimates.
$ErrorActionPreference = 'Stop'
if (-not $LogPath) { $LogPath = Join-Path $PSScriptRoot 'profile.log' }
$rows = @(Get-Content -LiteralPath $LogPath -Encoding UTF8)
$observations = @()
$missingModules = 0
$backgroundVeto = 0
foreach ($row in $rows) {
    if ($row -match 'switched to Idle.*d3d=False front=') { $missingModules++ }
    if ($row -match 'switched to Idle.*硬排除 GUI') { $backgroundVeto++ }
    $names = @([regex]::Matches($row, '(?:topCPU=|front=|全屏3D活跃 \[|(?:LibraryGame|ConfiguredGame|ConfirmedForeground|BackgroundGameLoad) \[)([\w. -]+)\.exe') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    foreach ($name in $names) { $observations += $name }
}
[PSCustomObject]@{
    logLines = $rows.Count
    firstRecord = if ($rows.Count) { $rows[0].Substring(0, [Math]::Min(19, $rows[0].Length)) } else { '' }
    lastRecord = if ($rows.Count) { $rows[-1].Substring(0, [Math]::Min(19, $rows[-1].Length)) } else { '' }
    legacyMissingD3DIdleSwitches = $missingModules
    legacyForegroundVetoIdleSwitches = $backgroundVeto
    frequentProcesses = @($observations | Group-Object | Sort-Object Count -Descending | Select-Object -First 20 Name,Count)
} | ConvertTo-Json -Depth 5
