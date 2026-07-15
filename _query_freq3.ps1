# 直接 query 三个 PROCFREQMAX 的当前 AC 值, 用 GUID 形式
$processorSub = '54533251-82be-4824-96c1-47b60b740d00'
$guids = @{
    'PROCFREQMAX (核类 0, 通常 E-core)'  = '75b0ae3f-bce0-45a7-8c89-c9611c25e100'
    'PROCFREQMAX1 (核类 1, 通常 P-core)' = '75b0ae3f-bce0-45a7-8c89-c9611c25e101'
    'PROCFREQMAX2 (核类 2)'              = '75b0ae3f-bce0-45a7-8c89-c9611c25e102'
}
foreach ($name in $guids.Keys) {
    Write-Host "=== $name ===" -ForegroundColor Cyan
    $g = $guids[$name]
    $out = & powercfg /Q SCHEME_CURRENT $processorSub $g 2>&1 | Out-String
    Write-Host $out
}
Write-Host "--- 当前 CPU 频率 (WMI 实测) ---" -ForegroundColor Yellow
Get-CimInstance Win32_Processor | Select-Object Name, MaxClockSpeed, CurrentClockSpeed | Format-List
