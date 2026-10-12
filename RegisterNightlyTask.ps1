#Requires -Version 5.1
# v2 rotation runs inside the events worker; retire the destructive legacy task.
$task=Get-ScheduledTask -TaskName 'CrashMonitor_NightlyCleanup' -ErrorAction SilentlyContinue
if ($task) { Disable-ScheduledTask -TaskName 'CrashMonitor_NightlyCleanup' | Out-Null }
Write-Output 'Nightly cleanup task is disabled. v2 collection manages Evidence retention.'
