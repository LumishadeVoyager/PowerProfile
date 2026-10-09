$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$project=Split-Path -Parent $PSScriptRoot
$ScriptDir=Join-Path ([IO.Path]::GetTempPath()) ('PowerProfileEnergyTests-'+[Guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($ScriptDir)
function Assert($Name,$Value){if(-not $Value){throw $Name};Write-Host "PASS $Name"}
. (Join-Path $project 'PowerProfileEnergyUI.ps1')
try {
    Initialize-EnergyService
    $Script:EnergyService.Dispose()
    $Script:EnergyService=New-Object ProfileEnergyService $ScriptDir,$false
    Assert 'unconfigured service never invents readings' (-not $Script:EnergyService.GetSnapshot().Configured -and $null -eq $Script:EnergyService.GetSnapshot().Watts)
    $Script:EnergyService.Configure('','',[decimal]0.7)
    Assert 'fixed tariff persists independently' ($Script:EnergyService.GetSnapshot().Price -eq [decimal]0.7)
    Assert 'price alone does not connect or control' (-not $Script:EnergyService.GetSnapshot().Configured)
    $secret='0123456789abcdef0123456789abcdef'
    $Script:EnergyService.Configure('192.168.1.254',$secret,[decimal]0.7)
    $saved=[IO.File]::ReadAllText((Join-Path $ScriptDir 'energy.settings.json'))
    Assert 'token encrypted rather than written as plaintext' (-not $saved.Contains($secret))
    Assert 'saved credentials do not invent successful connection' ($Script:EnergyService.GetSnapshot().Status -ne '已连接' -and $null -eq $Script:EnergyService.GetSnapshot().Watts)
    $Script:EnergyService.Dispose()
    $Script:EnergyService=New-Object ProfileEnergyService $ScriptDir,$false
    Assert 'encrypted connection and tariff survive restart' ($Script:EnergyService.GetSnapshot().Configured -and $Script:EnergyService.GetSnapshot().Price -eq [decimal]0.7)
    $h=New-Object ProfileEnergyHistory
    $h.Points=New-Object 'Collections.Generic.List[ProfileEnergyPoint]'
    $h.Days=New-Object 'Collections.Generic.Dictionary[string,ProfileEnergyDay]'
    $at=[DateTime]::SpecifyKind([DateTime]'2026-10-08 15:59:30',[DateTimeKind]::Utc)
    [ProfileEnergyService]::AddSample($h,$at,1000)
    Assert 'first sample does not imply earlier energy' ($h.Days.Count -eq 0)
    [ProfileEnergyService]::AddSample($h,$at.AddSeconds(60),1000)
    Assert 'midnight splits China daily totals correctly' ($h.Days.Count -eq 2 -and [Math]::Abs($h.Days['2026-10-08'].KWh-1.0/120) -lt 0.000001 -and $h.Days['2026-10-09'].Seconds -eq 30)
    [ProfileEnergyService]::AddSample($h,$at.AddSeconds(400),1000)
    Assert 'long offline gap is not charged or graphed as continuous' ($h.Days['2026-10-09'].Seconds -eq 30 -and $h.Points[2].BreakBefore)
    [ProfileEnergyService]::AddSample($h,$at.AddSeconds(460),500)
    Assert 'sampling resumes after a gap with trapezoidal energy' ([Math]::Abs($h.Days['2026-10-09'].KWh-(1.0/120+0.0125)) -lt 0.000001)
    $h.Points[3].InvalidAfter=$true
    [ProfileEnergyService]::AddSample($h,$at.AddSeconds(500),500)
    Assert 'failed poll also breaks short-gap energy integration' ($h.Days['2026-10-09'].Seconds -eq 90)
    [byte[]]$key=0..15;[byte[]]$header=New-Object byte[] 16
    $encoded=[ProfilePlugTransport]::Encode($header,$key,'{"id":1,"result":[]}')
    Assert 'authenticated protocol encryption roundtrip' ([ProfilePlugTransport]::Decode($encoded,$key) -eq '{"id":1,"result":[]}')
    $encoded[35]=$encoded[35] -bxor 1;$rejected=$false
    try{[void][ProfilePlugTransport]::Decode($encoded,$key)}catch{$rejected=$true}
    Assert 'tampered device payload rejected' $rejected
    $invalid=$false;try{[ProfileEnergyService]::Validate('8.8.8.8',$secret,[decimal]0.7)}catch{$invalid=$true}
    Assert 'LAN adapter rejects external network targets' $invalid
    $invalid=$false;try{[ProfileEnergyService]::Validate('192.168.1.1','bad',[decimal]0.7)}catch{$invalid=$true}
    Assert 'invalid token rejected before saving' $invalid
    $props=@(@{siid=11;piid=2;code=-4004;value=100},@{siid=2;piid=1;code=0;value=$false}) | ConvertTo-Json -Compress
    $parser=New-Object Web.Script.Serialization.JavaScriptSerializer
    $result=$parser.DeserializeObject($props)
    Assert 'property errors never masquerade as power readings' ($null -eq [ProfilePlugTransport]::ReadValue($result,11,2))
    Assert 'valid off state remains a boolean' ([ProfilePlugTransport]::ReadValue($result,2,1) -eq $false)
    $Script:EnergyService.Configure('','',[decimal]0.7)
    Assert 'disconnect clears device readings and stored credentials' (-not $Script:EnergyService.GetSnapshot().Configured -and $null -eq $Script:EnergyService.GetSnapshot().Watts -and -not ([IO.File]::ReadAllText((Join-Path $ScriptDir 'energy.settings.json')) | ConvertFrom-Json).Secret)
} finally {
    if($Script:EnergyService){$Script:EnergyService.Dispose()}
    if($Script:EnergyLogTimer){$Script:EnergyLogTimer.Stop();$Script:EnergyLogTimer.Dispose()}
    $resolved=[IO.Path]::GetFullPath($ScriptDir);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\PowerProfileEnergyTests-'
    if(-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected cleanup path'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host 'Energy regression tests passed.'
