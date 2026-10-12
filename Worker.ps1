#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidateSet('events','telemetry')][string]$Role, [Parameter(Mandatory=$true)][string]$RootPath)
$ErrorActionPreference='Stop'
$codeRoot=$PSScriptRoot
Import-Module (Join-Path $codeRoot 'Modules/Common.psm1') -Force
$config=Get-CMConfig $RootPath $codeRoot
$boot=Read-CMJson (Join-Path $RootPath 'Evidence/State/boot.json')
$previous=Read-CMJson (Join-Path $RootPath 'Evidence/State/previous-session.json')
$statusPath=Join-Path $RootPath "Evidence/State/worker-$Role.json"
function Write-ProgressState {
    param([string]$Phase,[string]$ErrorText='')
    Write-CMJson $statusPath @{ Pid=$PID; Role=$Role; Phase=$Phase; ProgressUtc=[datetime]::UtcNow.ToString('o'); Error=$ErrorText }
}
Write-ProgressState 'Starting'
$clock=[Diagnostics.Stopwatch]::StartNew()
$lastCleanup=-60000L
$incidentPending=$true
if ($Role -eq 'events') { Import-Module (Join-Path $codeRoot 'Modules/EventCapture.psm1') -Force; Import-Module (Join-Path $codeRoot 'Modules/Diagnostics.psm1') -Force }
else { Import-Module (Join-Path $codeRoot 'Modules/TelemetryV2.psm1') -Force }
try {
    while (-not (Test-Path -LiteralPath (Join-Path $RootPath 'Evidence/State/stop.request'))) {
        $next=$clock.ElapsedMilliseconds
        $failure=''
        try {
            Write-ProgressState 'Collecting'
            $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($RootPath))
            if ($drive.AvailableFreeSpace -lt ([long]$config.MinFreeSpaceMB*1MB)) { throw "Low free space: less than $($config.MinFreeSpaceMB) MB. Collection paused; heartbeat continues." }
            if ($Role -eq 'telemetry') { Write-CMTelemetry $RootPath (Get-CMTelemetry $RootPath $codeRoot $config $boot) }
            else {
                [void](Receive-CMEvents $RootPath $config $boot)
                if ($incidentPending) {
                    Write-ProgressState 'BuildingIncident'
                    $events=@(Get-CMBootEvents $RootPath $boot)
                    New-CMIncident -Root $RootPath -Config $config -Boot $boot -Events $events -PreviousSession $previous
                    $incidentPending=$false
                }
                if (($clock.ElapsedMilliseconds-$lastCleanup) -ge 60000) { Invoke-CMRotation $RootPath $config; $lastCleanup=$clock.ElapsedMilliseconds }
            }
        } catch {
            $failure=[string]$_
            Write-CMLog $RootPath $Role $failure 'ERROR'
        }
        Write-ProgressState 'Waiting' $failure
        $interval=[double]$config.SampleIntervalSeconds
        if ($Role -eq 'events') { $interval=[double]$config.EventPollSeconds }
        # Monotonic scheduling survives NTP/RTC changes.
        while (($clock.ElapsedMilliseconds-$next) -lt ($interval*1000)) {
            if (Test-Path -LiteralPath (Join-Path $RootPath 'Evidence/State/stop.request')) { break }
            Start-Sleep -Milliseconds 200
        }
    }
} finally { Write-ProgressState 'Stopped' }
