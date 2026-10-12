#Requires -Version 5.1
[CmdletBinding()]
param([string]$RootPath='C:\CrashMonitor')
$ErrorActionPreference='Stop'
if ($env:OS -ne 'Windows_NT') { throw 'This smoke check requires Windows.' }
$codeRoot=Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'Test-Self.ps1')
& (Join-Path $codeRoot 'Scripts/Get-MonitorStatus.ps1') -RootPath $RootPath
$task=Get-ScheduledTask -TaskName 'CrashMonitor_AutoStart' -ErrorAction Stop
if ($task.State -ne 'Running') { throw "Task state is $($task.State), expected Running." }
foreach ($channel in @('System','Application')) {
    Get-WinEvent -LogName $channel -MaxEvents 1 -ErrorAction Stop | Out-Null
    Write-Output "PASS: readable $channel event log"
}
$telemetry=Join-Path $RootPath 'Evidence/Logs/telemetry-v2.csv'
$row=Get-Content -LiteralPath $telemetry -Tail 1 -Encoding UTF8
$header=Get-Content -LiteralPath $telemetry -TotalCount 1 -Encoding UTF8
$sample=@($header,$row) | ConvertFrom-Csv -Delimiter ';'
if (-not $sample.Utc -or $null -eq $sample.ErrorsJson) { throw 'Missing telemetry row/schema.' }
$errors = ConvertFrom-Json $sample.ErrorsJson
$errCount = if ($null -eq $errors) { 0 } else { @($errors).Count }
if ($errCount -gt 0) { throw "Telemetry reported unavailable collectors: $($sample.ErrorsJson)" }
Write-Output 'PASS: telemetry row and Windows collectors'
Import-Module (Join-Path $codeRoot 'Modules/Common.psm1')
$boot=Read-CMJson (Join-Path $RootPath 'Evidence/State/boot.json')
$incident=Join-Path $RootPath "Evidence/Incidents/$($boot.BootKey)"
$complete=Read-CMJson (Join-Path $incident 'complete.json')
if (-not $complete) { throw 'The first boot report is still being built or failed. Inspect events.log and try again later.' }
if (@($complete.ExportErrors).Count) { throw "Incident EVTX export failed: $($complete.ExportErrors -join '; ')" }
Get-WinEvent -Path (Join-Path $incident 'EVTX/System.evtx') -MaxEvents 1 -ErrorAction Stop | Out-Null
Write-Output 'PASS: incident complete and exported System.evtx is readable'
Write-Output 'PASS: Windows smoke check. No restart, stress test, or deliberate crash was triggered.'
