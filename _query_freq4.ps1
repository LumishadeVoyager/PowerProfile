# 看 PROCTHROTTLEMAX + 各 frequency cap 当前设置 (AC), 用 GUID 直接 query
$processorSub = '54533251-82be-4824-96c1-47b60b740d00'
$settings = @{
    'PROCFREQMAX  (核类 0 = E-core)' = '75b0ae3f-bce0-45a7-8c89-c9611c25e100'
    'PROCFREQMAX1 (核类 1 = P-core)' = '75b0ae3f-bce0-45a7-8c89-c9611c25e101'
    'PROCFREQMAX2 (核类 2)'          = '75b0ae3f-bce0-45a7-8c89-c9611c25e102'
    'PROCTHROTTLEMAX (全局百分比)'   = 'bc5038f7-23e0-4960-96da-33abaf5935ec'
    'PROCTHROTTLEMIN (全局百分比)'   = '893dee8e-2bef-41e0-89c6-b55d0929964c'
    'PERFBOOSTMODE (Turbo)'          = 'be337238-0d82-4146-a960-4f3749d470c7'
}
foreach ($name in $settings.Keys) {
    $out = & powercfg /Q SCHEME_CURRENT $processorSub $settings[$name] 2>&1 | Out-String
    $hex = if ($out -match '(?:当前交流|Current AC).*?:\s*(0x[0-9a-fA-F]+)') { $matches[1] } else { '<未设置>' }
    $dec = if ($hex -ne '<未设置>') { [Convert]::ToInt32($hex, 16) } else { 'N/A' }
    Write-Host ("{0,-38} = {1,12}  ({2})" -f $name, $hex, $dec)
}
