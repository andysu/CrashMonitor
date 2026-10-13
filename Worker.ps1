#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidateSet('events','telemetry')][string]$Role, [Parameter(Mandatory=$true)][string]$RootPath)
$ErrorActionPreference='Stop'
$codeRoot=$PSScriptRoot
Import-Module (Join-Path $codeRoot 'Modules/Common.psm1') -Force
$config=Get-CMConfig $RootPath $codeRoot
$bootPath=Join-Path $RootPath 'Evidence/State/boot.json'
$boot=Read-CMJson $bootPath
if (-not $boot) {
    for ($attempt=0; $attempt -lt 5 -and -not $boot; $attempt++) {
        Start-Sleep -Milliseconds 200
        $boot=Read-CMJson $bootPath
    }
}
if (-not $boot) { $boot=Get-CMBootInfo }
$previous=Read-CMJson (Join-Path $RootPath 'Evidence/State/previous-session.json')
$statusPath=Join-Path $RootPath "Evidence/State/worker-$Role.json"
function Write-ProgressState {
    param([string]$Phase,[string]$ErrorText='')
    Write-CMJson $statusPath @{ Pid=$PID; Role=$Role; Phase=$Phase; ProgressUtc=[datetime]::UtcNow.ToString('o'); Error=$ErrorText }
}
Write-ProgressState 'Starting'
$clock=[Diagnostics.Stopwatch]::StartNew()
$lastCleanup=-60000L
$lastStorage=0L
$storageIntervalMinutes=[double](Get-CMValue $config 'StorageHealthIntervalMinutes' 15)
if ($storageIntervalMinutes -le 0) { $storageIntervalMinutes=15 }
$incidentPending=$true
if ($Role -eq 'events') { Import-Module (Join-Path $codeRoot 'Modules/EventCapture.psm1') -Force; Import-Module (Join-Path $codeRoot 'Modules/Diagnostics.psm1') -Force }
else {
    Import-Module (Join-Path $codeRoot 'Modules/TelemetryV2.psm1') -Force
    Write-ProgressState 'WarmingUp'
    $warmUp=Initialize-CMTelemetry
    if ($warmUp.Success) { Write-CMLog $RootPath $Role "Performance counter warm-up took $($warmUp.DurationMs) ms." }
    else { Write-CMLog $RootPath $Role "Performance counter warm-up failed after $($warmUp.DurationMs) ms: $($warmUp.Error)" 'WARN' }
}
try {
    while (-not (Test-Path -LiteralPath (Join-Path $RootPath 'Evidence/State/stop.request'))) {
        $next=$clock.ElapsedMilliseconds
        $failure=''
        try {
            Write-ProgressState 'Collecting'
            $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($RootPath))
            if ($drive.AvailableFreeSpace -lt ([long]$config.MinFreeSpaceMB*1MB)) { throw "Low free space: less than $($config.MinFreeSpaceMB) MB. Collection paused; heartbeat continues." }
            if ($Role -eq 'telemetry') { Write-CMTelemetry $RootPath (Get-CMTelemetry $RootPath $codeRoot $config $boot) $config }
            else {
                [void](Receive-CMEvents $RootPath $config $boot)
                # Storage health runs here, not in the telemetry loop: a snapshot can take seconds and must not open gaps in telemetry.
                $storageDue=$incidentPending -or (($clock.ElapsedMilliseconds-$lastStorage) -ge ($storageIntervalMinutes*60000))
                $storageChanges=@()
                if ($storageDue) {
                    Write-ProgressState 'StorageHealth'
                    try { $storageChanges=@(Invoke-CMStorageHealthSnapshot -Root $RootPath -ToolsDir (Join-Path $RootPath 'Tools') -BootKey $boot.BootKey) }
                    catch { Write-CMLog $RootPath $Role "Storage health snapshot failed: $_" 'ERROR' }
                    $lastStorage=$clock.ElapsedMilliseconds
                }
                if ($incidentPending) {
                    Write-ProgressState 'BuildingIncident'
                    try {
                        $currentSmart = Get-CMSmartSnapshot -ToolsDir (Join-Path $RootPath 'Tools')
                        Write-CMJson (Join-Path $RootPath 'Evidence/State/smart-counters.json') $currentSmart
                    } catch { }
                    $events=@(Get-CMBootEvents $RootPath $boot)
                    New-CMIncident -Root $RootPath -Config $config -Boot $boot -Events $events -PreviousSession $previous -StorageHealthChanges $storageChanges
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
} finally {
    if ($Role -eq 'telemetry') {
        try { Close-CMTelemetrySensor } catch { }
    }
    Write-ProgressState 'Stopped'
}
