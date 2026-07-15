# 查询当前 powercfg 的 PROCFREQMAX 三档值
$out = & powercfg /Q SCHEME_CURRENT SUB_PROCESSOR | Out-String
$lines = $out -split "`r?`n"
$capture = $false
$blockLines = @()
foreach ($line in $lines) {
    if ($line -match '电源设置 GUID|Power Setting GUID') {
        if ($blockLines.Count -gt 0) {
            $block = $blockLines -join "`n"
            if ($block -match 'PROCFREQMAX|最大处理器频率|Maximum processor frequency') {
                Write-Host $block -ForegroundColor Yellow
                Write-Host '---' -ForegroundColor DarkGray
            }
            $blockLines = @()
        }
    }
    $blockLines += $line
}
# 最后一块
$block = $blockLines -join "`n"
if ($block -match 'PROCFREQMAX|最大处理器频率|Maximum processor frequency') {
    Write-Host $block -ForegroundColor Yellow
}
