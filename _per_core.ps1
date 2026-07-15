# 看每个核心当前实际频率, 以及是否被 PROCFREQMAX 限制
Write-Host "--- 每个核心当前频率 (HZ) ---" -ForegroundColor Cyan
$counters = Get-Counter '\Processor Information(*)\Processor Frequency' -ErrorAction SilentlyContinue
if ($counters) {
    foreach ($s in $counters.CounterSamples) {
        if ($s.InstanceName -notmatch '_Total') {
            Write-Host ("  Core {0}: {1} MHz" -f $s.InstanceName, [int]$s.CookedValue)
        }
    }
} else {
    Write-Host "  (no counter)" -ForegroundColor Red
}

Write-Host ""
Write-Host "--- 每个核心当前 % Performance ---" -ForegroundColor Cyan
$pct = Get-Counter '\Processor Information(*)\% Processor Performance' -ErrorAction SilentlyContinue
if ($pct) {
    foreach ($s in $pct.CounterSamples) {
        if ($s.InstanceName -notmatch '_Total') {
            Write-Host ("  Core {0}: {1:F0}%" -f $s.InstanceName, $s.CookedValue)
        }
    }
}

Write-Host ""
Write-Host "--- 关键 powercfg 当前设置 ---" -ForegroundColor Cyan
$processorSub = '54533251-82be-4824-96c1-47b60b740d00'
$lookup = @{
    'PROCFREQMAX (MHz 上限)'           = '75b0ae3f-bce0-45a7-8c89-c9611c25e100'
    'PROCTHROTTLEMAX (Max state %)'    = 'bc5038f7-23e0-4960-96da-33abaf5935ec'
    'PROCTHROTTLEMIN (Min state %)'    = '893dee8e-2bef-41e0-89c6-b55d0929964c'
    'PERFBOOSTMODE (Turbo)'            = 'be337238-0d82-4146-a960-4f3749d470c7'
}
foreach ($name in $lookup.Keys) {
    $out = & powercfg /Q SCHEME_CURRENT $processorSub $lookup[$name] 2>&1 | Out-String
    if ($out -match '当前交流电源配置设置:\s*(0x[0-9a-fA-F]+)') {
        $hex = $matches[1]
        $dec = [Convert]::ToInt32($hex, 16)
        Write-Host ("  {0}: {1} = {2}" -f $name, $hex, $dec)
    }
}
