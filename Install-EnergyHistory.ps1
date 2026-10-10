$ErrorActionPreference='Stop'
# Optional runtime, launched only when the user opens cloud history.
python -m venv (Join-Path $PSScriptRoot '.codex\energy-cloud')
if($LASTEXITCODE -ne 0){throw 'Python 3.10+ is required'}
& (Join-Path $PSScriptRoot '.codex\energy-cloud\Scripts\python.exe') -m pip install 'mijiaAPI==5.0.0'
if($LASTEXITCODE -ne 0){throw 'History dependency installation failed'}
