# 看 EPP / Hetero / freq / throttle 实际值
$processorSub = '54533251-82be-4824-96c1-47b60b740d00'
$lookup = @(
    @{ Name='EPP (能效偏好, 0-100)'; Guid='36687f9e-e3a5-4dbf-b1dc-15eb381c6863' },
    @{ Name='Hetero Policy (异构调度)'; Guid='7f2f5cfa-f10c-4823-b5e1-e93ae85f46b3' },
    @{ Name='PROCFREQMAX  (E-core)'; Guid='75b0ae3f-bce0-45a7-8c89-c9611c25e100' },
    @{ Name='PROCFREQMAX1 (P-core)'; Guid='75b0ae3f-bce0-45a7-8c89-c9611c25e101' },
    @{ Name='PROCTHROTTLEMAX (%)'; Guid='bc5038f7-23e0-4960-96da-33abaf5935ec' },
    @{ Name='PROCTHROTTLEMIN (%)'; Guid='893dee8e-2bef-41e0-89c6-b55d0929964c' },
    @{ Name='PERFBOOSTMODE (Turbo)'; Guid='be337238-0d82-4146-a960-4f3749d470c7' }
)
Write-Host "--- 实际当前值 (设置失败的会显示 'N/A') ---" -ForegroundColor Cyan
foreach ($i in $lookup) {
    $out = & powercfg /Q SCHEME_CURRENT $processorSub $i.Guid 2>&1 | Out-String
    $hex = if ($out -match '(?:当前交流|Current AC).*?:\s*(0x[0-9a-fA-F]+)') { $matches[1] } else { 'N/A' }
    $dec = if ($hex -ne 'N/A') { [Convert]::ToInt32($hex, 16) } else { 'N/A' }
    Write-Host ("  {0,-30} = {1}" -f $i.Name, $dec)
}

# 直接试一次 EPP 看错误
Write-Host ""
Write-Host "--- 单独测 EPP=100 ---" -ForegroundColor Cyan
& powercfg /SETACVALUEINDEX SCHEME_CURRENT $processorSub '36687f9e-e3a5-4dbf-b1dc-15eb381c6863' 100 2>&1
Write-Host "exit=$LASTEXITCODE"

Write-Host ""
Write-Host "--- 单独测 Hetero=1 ---" -ForegroundColor Cyan
& powercfg /SETACVALUEINDEX SCHEME_CURRENT $processorSub '7f2f5cfa-f10c-4823-b5e1-e93ae85f46b3' 1 2>&1
Write-Host "exit=$LASTEXITCODE"
