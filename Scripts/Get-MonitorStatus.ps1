#Requires -Version 5.1
[CmdletBinding()]
param([string]$RootPath='C:\CrashMonitor')
$ErrorActionPreference='Stop'
$codeRoot=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $codeRoot 'Modules/Common.psm1')
$health=Read-CMJson (Join-Path $RootPath 'Evidence/State/health.json')
if (-not $health) { throw 'No health file. Monitor has not started or RootPath is incorrect.' }
$age=([datetime]::UtcNow-[datetime]::Parse($health.Utc).ToUniversalTime()).TotalSeconds
$health | ConvertTo-Json -Depth 12
if ($age -lt -30 -or $age -gt 15) { throw "Heartbeat health is stale or the clock changed: age=$age seconds." }
$config=Get-CMConfig $RootPath $codeRoot
foreach ($role in @('events','telemetry')) {
    $worker=Get-CMValue $health.Workers $role
    if (-not $worker -or $worker.Phase -eq 'Stopped') { throw "Worker $role is not running." }
    if ($worker.Error) { throw "Worker $role reported: $($worker.Error)" }
    $workerAge=([datetime]::UtcNow-[datetime]::Parse($worker.ProgressUtc).ToUniversalTime()).TotalSeconds
    if ($workerAge -gt [double]$config.WorkerStallSeconds) { throw "Worker $role is stale." }
}
Write-Output 'PASS: heartbeat and both collectors are active.'
