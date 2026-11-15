param([switch]$Manual)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'PowerProfileDetection.ps1')
. (Join-Path $PSScriptRoot 'PowerProfileUpdate.ps1')
Invoke-ProfileUpdateCheck $PSScriptRoot -Manual:$Manual
