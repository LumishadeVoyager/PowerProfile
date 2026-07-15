# dump SUB_PROCESSOR 找 PROCFREQMAX 三档实际写入值
$out = & powercfg /Q SCHEME_CURRENT SUB_PROCESSOR 2>&1 | Out-String
$lines = $out -split "`r?`n"
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '75b0ae3f-bce0-45a7-8c89-c9611c25e10[012]') {
        Write-Host "==========" -ForegroundColor Cyan
        for ($j = $i; $j -lt [Math]::Min($i + 9, $lines.Count); $j++) {
            Write-Host $lines[$j]
        }
    }
}
Write-Host ""
Write-Host "--- 实测当前 CPU 频率 (WMI) ---" -ForegroundColor Yellow
Get-CimInstance Win32_Processor | Select-Object Name, MaxClockSpeed, CurrentClockSpeed | Format-List
