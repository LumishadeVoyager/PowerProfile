param([Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$OperationId)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'PowerProfileDetection.ps1')
. (Join-Path $PSScriptRoot 'PowerProfileTelemetry.ps1')
$samples=Get-Counter '\GPU Engine(*)\Utilization Percentage' -SampleInterval 1 -MaxSamples 2 -ErrorAction SilentlyContinue | Select-Object -Last 1
$result=Get-GpuMetricValues $samples.CounterSamples
Write-AtomicJson (Join-Path $PSScriptRoot "telemetry.gpu.$OperationId.json") $result
