#Requires -Version 5.1
[CmdletBinding()]
param([string]$RootPath='C:\CrashMonitor', [switch]$NonInteractive)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Modules/Common.psm1')
if ($env:OS -ne 'Windows_NT') { throw 'CrashMonitor requires Windows with PowerShell 5.1 or later.' }
$RootPath=[IO.Path]::GetFullPath($RootPath).TrimEnd('\')
$config=Get-CMConfig $RootPath $PSScriptRoot
foreach ($dir in @('Logs','State','Events','Incidents','Archive')) { [void][IO.Directory]::CreateDirectory((Join-Path $RootPath "Evidence/$dir")) }
$hash=[Security.Cryptography.SHA256]::Create()
try { $suffix=([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($RootPath.ToUpperInvariant())))).Replace('-','').Substring(0,20) } finally { $hash.Dispose() }
$mutex=New-Object Threading.Mutex($false,"Global\CrashMonitorV2_$suffix")
$locked=$false
try { $locked=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked=$true }
if (-not $locked) { $mutex.Dispose(); throw 'CrashMonitor is already running for this root.' }
$workers=@{}
$clock=[Diagnostics.Stopwatch]::StartNew()
$heartbeatColumns=@('SchemaVersion','Utc','Local','UtcOffsetMinutes','BootKey','MonitorSessionId','Sequence','MonotonicMs')
$sessionId=[guid]::NewGuid().ToString('N')
$state=Join-Path $RootPath 'Evidence/State'
function Start-Collector {
    param([string]$Role)
    $status=Join-Path $state "worker-$Role.json"
    if (Test-Path -LiteralPath $status) { Remove-Item -LiteralPath $status -Force }
    $exe=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $workerArgs=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"{0}"' -f (Join-Path $PSScriptRoot 'Worker.ps1')),'-Role',$Role,'-RootPath',('"{0}"' -f $RootPath))
    $proc=Start-Process -FilePath $exe -ArgumentList $workerArgs -WindowStyle Hidden -PassThru
    return @{ Process=$proc; StartedMs=$clock.ElapsedMilliseconds; LastProgressMs=$clock.ElapsedMilliseconds; LastProgressUtc=''; Restarts=0 }
}
function Stop-Collector {
    param($Worker)
    $p=$Worker.Process
    try {
        $p.Refresh()
        if (-not $p.HasExited) {
            $killer=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32/taskkill.exe') -ArgumentList @('/PID',[string]$p.Id,'/T','/F') -WindowStyle Hidden -PassThru
            try { if (-not $killer.WaitForExit(5000)) { $killer.Kill() } } finally { $killer.Dispose() }
        }
    } catch { } finally { try { $p.Dispose() } catch { } }
}
try {
    Remove-Item -LiteralPath (Join-Path $state 'stop.request') -Force -ErrorAction SilentlyContinue
    $boot=Get-CMBootInfo
    $prior=Read-CMJson (Join-Path $state 'session.json')
    if ($prior -and $prior.Boot.BootKey -ne $boot.BootKey) {
        $priorHealth=$null
        try { $priorHealth=Read-CMJson (Join-Path $state 'health.json') } catch { }
        Write-CMJson (Join-Path $state 'previous-session.json') @{ Boot=$prior.Boot; MonitorSessionId=$prior.MonitorSessionId; StartedUtc=$prior.StartedUtc; LastKnownHealth=$priorHealth }

        # Preserve pre-crash processes snapshot before telemetry worker overwrites it
        $latestProc = Join-Path $RootPath 'Evidence/Logs/processes-latest.json'
        if (Test-Path -LiteralPath $latestProc) {
            Copy-Item -LiteralPath $latestProc -Destination (Join-Path $RootPath 'Evidence/Logs/processes-previous.json') -Force -ErrorAction SilentlyContinue
        }

        # Preserve previous SMART snapshot for delta comparison
        $smartFile = Join-Path $state 'smart-counters.json'
        if (Test-Path -LiteralPath $smartFile) {
            Copy-Item -LiteralPath $smartFile -Destination (Join-Path $state 'previous-smart-counters.json') -Force -ErrorAction SilentlyContinue
        }
    }

    # SMART snapshot is taken asynchronously by events worker during incident building to prevent supervisor hang


    # Migrate telemetry-v2.csv if schema was updated (e.g. addition of IoLatencyMs column)
    $telemetryCsv = Join-Path $RootPath 'Evidence/Logs/telemetry-v2.csv'
    if (Test-Path -LiteralPath $telemetryCsv) {
        try {
            $reader = [IO.File]::OpenText($telemetryCsv)
            $existingHdr = $null
            try { $existingHdr = $reader.ReadLine() } finally { $reader.Dispose() }
            Import-Module (Join-Path $PSScriptRoot 'Modules/TelemetryV2.psm1') -ErrorAction SilentlyContinue
            $expectedHdr = (@((Get-CMTelemetryColumns) | ForEach-Object { '"' + $_ + '"' }) -join ';')
            if ($existingHdr -and $existingHdr -ne $expectedHdr) {
                $archiveDir = Join-Path $RootPath 'Evidence/Archive'
                [void][IO.Directory]::CreateDirectory($archiveDir)
                $migrated = Join-Path $archiveDir ("telemetry-v2-pre-upgrade-" + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + ".csv")
                Move-Item -LiteralPath $telemetryCsv -Destination $migrated -Force
                Write-CMLog $RootPath 'supervisor' "Migrated legacy telemetry CSV to $migrated" 'INFO'
            }
        } catch { }
    }

    Write-CMJson (Join-Path $state 'boot.json') $boot
    Write-CMJson (Join-Path $state 'session.json') @{ Boot=$boot; MonitorSessionId=$sessionId; StartedUtc=[datetime]::UtcNow.ToString('o'); Pid=$PID; ProcessStartUtc=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o') }
    Write-CMLog $RootPath 'supervisor' "CrashMonitor v2 started. Boot=$($boot.BootKey); monitor=$sessionId; pid=$PID."
    foreach ($role in @('events','telemetry')) { $workers[$role]=Start-Collector $role }
    $lastHeartbeat=-100000L; $lastCheck=-100000L; $sequence=0L
    while (-not (Test-Path -LiteralPath (Join-Path $state 'stop.request'))) {
        if (($clock.ElapsedMilliseconds-$lastHeartbeat) -ge ([double]$config.HeartbeatIntervalSeconds*1000)) {
            $now=[DateTimeOffset]::Now; $sequence++
            # A heartbeat or health write that fails (file held by another program) is logged and skipped:
            # an exception here would stop the supervisor and with it the whole monitor.
            try {
                Write-CMCsv -Path (Join-Path $RootPath 'Evidence/Logs/heartbeat-v2.csv') -Columns $heartbeatColumns -Row @{
                    SchemaVersion=2; Utc=$now.UtcDateTime.ToString('o'); Local=$now.ToString('o'); UtcOffsetMinutes=$now.Offset.TotalMinutes
                    BootKey=$boot.BootKey; MonitorSessionId=$sessionId; Sequence=$sequence; MonotonicMs=$clock.ElapsedMilliseconds
                }
            } catch { try { Write-CMLog $RootPath 'supervisor' "Heartbeat  not written: $_" 'WARNING' } catch { } }
            $lastHeartbeat=$clock.ElapsedMilliseconds
            # The remote receiver treats silence of these packets as the moment the machine stopped.
            Send-CMUdpPacket -Config $config -Payload ([ordered]@{ SchemaVersion=3; Type='hb'; Seq=$sequence; Utc=$now.UtcDateTime.ToString('o'); BootKey=$boot.BootKey; MonitorSessionId=$sessionId })
            $health=@{ Utc=$now.UtcDateTime.ToString('o'); Boot=$boot; SupervisorPid=$PID; MonitorSessionId=$sessionId; HeartbeatSequence=$sequence; Workers=@{} }
            foreach ($role in $workers.Keys) {
                $status=$null
                try { $status=Read-CMJson (Join-Path $state "worker-$role.json") } catch { }
                $health.Workers[$role]=$status
            }
            try { Write-CMJson (Join-Path $state 'health.json') $health } catch { try { Write-CMLog $RootPath 'supervisor' "health.json not written: $_" 'WARNING' } catch { } }
        }
        if (($clock.ElapsedMilliseconds-$lastCheck) -ge 5000) {
            foreach ($role in @('events','telemetry')) {
                $w=$workers[$role];$w.Process.Refresh();$status=$null
                try { $status=Read-CMJson (Join-Path $state "worker-$role.json") } catch { }
                if ($status -and $status.Pid -eq $w.Process.Id -and $status.ProgressUtc -ne $w.LastProgressUtc) {
                    $w.LastProgressUtc=$status.ProgressUtc;$w.LastProgressMs=$clock.ElapsedMilliseconds
                }
                if ($w.Process.HasExited -or (($clock.ElapsedMilliseconds-$w.LastProgressMs) -gt ([double]$config.WorkerStallSeconds*1000))) {
                    Write-CMLog $RootPath 'supervisor' "Collector $role exited or stopped progressing; restarting its process tree." 'WARNING'
                    $count=$w.Restarts+1;Stop-Collector $w
                    $workers[$role]=Start-Collector $role;$workers[$role].Restarts=$count
                }
            }
            $lastCheck=$clock.ElapsedMilliseconds
        }
        if (-not $NonInteractive -and [Environment]::UserInteractive) {
            try { if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'Q') { break } } catch { }
        }
        Start-Sleep -Milliseconds 100
    }
} finally {
    foreach ($w in $workers.Values) { try { Stop-Collector $w } catch { } }
    try { Write-CMLog $RootPath 'supervisor' 'Monitor stopped.' } catch { }
    if ($locked) { $mutex.ReleaseMutex() };$mutex.Dispose()
}
