#Requires -Version 5.1
param([string]$RootPath='C:\CrashMonitor')
$dir=Join-Path $RootPath 'Evidence/State'
if (Test-Path -LiteralPath $dir) { [IO.File]::WriteAllText((Join-Path $dir 'stop.request'),[datetime]::UtcNow.ToString('o')) }
