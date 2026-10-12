#Requires -Version 5.1
param([string]$RootPath='C:\CrashMonitor')
# Compatibility entry point. The events worker performs v2 rotation every minute.
# Never truncate legacy logs, panic evidence, or incident reports.
Write-Output "CrashMonitor v2 manages its Evidence folder during collection. Legacy Logs and Reports in $RootPath are preserved."
