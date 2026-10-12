#Requires -Version 5.1
Import-Module (Join-Path $PSScriptRoot 'Common.psm1')

function Invoke-CMNative {
    param([string]$FilePath, [string[]]$Arguments, [string]$OutputPrefix, [int]$TimeoutSeconds=30)
    $out="$OutputPrefix.stdout.txt"; $err="$OutputPrefix.stderr.txt"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()

    $stdoutTask = $p.StandardOutput.ReadToEndAsync()
    $stderrTask = $p.StandardError.ReadToEndAsync()

    try {
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            try { $p.Kill() } catch {}
            throw "Timeout running $FilePath"
        }
        [IO.File]::WriteAllText($out, $stdoutTask.Result)
        [IO.File]::WriteAllText($err, $stderrTask.Result)
        if ($p.ExitCode -ne 0) { throw "$FilePath exit code $($p.ExitCode). See $err" }
    } finally { $p.Dispose() }
}

function Get-CMInventory {
    $result=[ordered]@{ SchemaVersion=2; CapturedUtc=[datetime]::UtcNow.ToString('o'); Errors=@() }
    $queries=@{
        OperatingSystem=@('Win32_OperatingSystem',@('Caption','Version','BuildNumber','LastBootUpTime','SystemDrive','WindowsDirectory','TotalVisibleMemorySize','FreePhysicalMemory'))
        Computer=@('Win32_ComputerSystem',@('Manufacturer','Model','TotalPhysicalMemory','AutomaticManagedPagefile','HypervisorPresent'))
        Bios=@('Win32_BIOS',@('Manufacturer','SMBIOSBIOSVersion','ReleaseDate'))
        Processor=@('Win32_Processor',@('Name','MaxClockSpeed','NumberOfCores','NumberOfLogicalProcessors'))
        Disks=@('Win32_DiskDrive',@('Index','DeviceID','Model','SerialNumber','InterfaceType','Size','Status','PNPDeviceID'))
        LogicalDisks=@('Win32_LogicalDisk',@('DeviceID','DriveType','FileSystem','Size','FreeSpace','VolumeName'))
        PageFileSettings=@('Win32_PageFileSetting',@('Name','InitialSize','MaximumSize'))
        PageFileUsage=@('Win32_PageFileUsage',@('Name','AllocatedBaseSize','CurrentUsage','PeakUsage','TempPageFile'))
        Recovery=@('Win32_OSRecoveryConfiguration',@('DebugInfoType','DebugFilePath','MiniDumpDirectory','AutoReboot','WriteToSystemLog','OverwriteExistingDebugFile'))
        Drivers=@('Win32_PnPSignedDriver',@('DeviceName','DeviceID','DriverVersion','DriverDate','DriverProviderName','InfName','IsSigned'))
        KernelDrivers=@('Win32_SystemDriver',@('Name','DisplayName','State','StartMode','PathName','ServiceType'))
        Updates=@('Win32_QuickFixEngineering',@('HotFixID','Description','InstalledOn'))
    }
    foreach ($key in $queries.Keys) {
        try { $result[$key]=@(Get-CimInstance -ClassName $queries[$key][0] -OperationTimeoutSec 5 -ErrorAction Stop | Select-Object -Property $queries[$key][1]) }
        catch { $result.Errors+= "${key}: $_" }
    }
    try { $result.Partitions=@(Get-Partition -ErrorAction Stop | Select-Object DiskNumber,PartitionNumber,DriveLetter,Type,Size,AccessPaths,IsBoot,IsSystem) }
    catch { $result.Errors+="Partitions: $_" }
    try {
        $physical=@(Get-PhysicalDisk -ErrorAction Stop)
        $result.PhysicalDisks=@($physical | Select-Object DeviceId,FriendlyName,SerialNumber,MediaType,BusType,HealthStatus,OperationalStatus,Size)
        $result.StorageReliability=@($physical | Get-StorageReliabilityCounter -ErrorAction Stop | Select-Object DeviceId,Temperature,TemperatureMax,ReadErrorsTotal,ReadErrorsUncorrected,WriteErrorsTotal,WriteErrorsUncorrected,Wear,PowerOnHours)
    } catch { $result.Errors+="Storage reliability (not full SMART; hardware dependent): $_" }
    try { $result.CrashControl=Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction Stop | Select-Object CrashDumpEnabled,DumpFile,MinidumpDir,AutoReboot,LogEvent,AlwaysKeepMemoryDump,DedicatedDumpFile,DumpFileSize }
    catch { $result.Errors+="CrashControl: $_" }
    $result.DumpFiles=@()
    foreach ($path in @("$env:SystemRoot\MEMORY.DMP","$env:SystemRoot\Minidump","$env:SystemRoot\LiveKernelReports")) {
        if (Test-Path -LiteralPath $path) {
            if ((Get-Item -LiteralPath $path) -is [IO.FileInfo]) {
                $item = Get-Item -LiteralPath $path
                $result.DumpFiles += [pscustomobject]@{ Name=$item.Name; Length=$item.Length; LastWriteTimeUtc=$item.LastWriteTimeUtc; FullName=$item.FullName }
            } else {
                $result.DumpFiles += @(Get-ChildItem -LiteralPath $path -File -Recurse -ErrorAction SilentlyContinue | Select-Object Name,Length,LastWriteTimeUtc,FullName)
            }
        }
    }
    return $result
}

function Export-CMEvtx {
    param([string]$Directory, [Nullable[datetime]]$SinceUtc)
    [void][IO.Directory]::CreateDirectory($Directory)
    foreach ($channel in @('System','Application')) {
        $dest=Join-Path $Directory "$channel.evtx"
        $args=@('epl',$channel,('"{0}"' -f $dest),'/ow:true')
        if ($null -ne $SinceUtc) {
            $when=([datetime]$SinceUtc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            $args+=('/q:"*[System[TimeCreated[@SystemTime >= ''{0}'']]]"' -f $when)
        }
        Invoke-CMNative -FilePath (Join-Path $env:SystemRoot 'System32/wevtutil.exe') -Arguments $args -OutputPrefix (Join-Path $Directory "$channel-export") -TimeoutSeconds 60
    }
}

function New-CMIncident {
    param([string]$Root, [hashtable]$Config, $Boot, [object[]]$Events, $PreviousSession)
    $dir=Join-Path $Root "Evidence/Incidents/$($Boot.BootKey)"
    if (Test-Path -LiteralPath (Join-Path $dir 'complete.json')) { return }
    [void][IO.Directory]::CreateDirectory($dir)
    $bootUtcDt = [datetime]::Parse($Boot.BootUtc).ToUniversalTime()
    $previousBoot=$null
    if ($PreviousSession) { $previousBoot=[datetime]::Parse($PreviousSession.Boot.BootUtc).ToUniversalTime() }
    $classification=Get-CMRestartClassification -Events $Events -BootUtc $bootUtcDt -PreviousBootUtc $previousBoot
    $inventory=Get-CMInventory
    Write-CMJson (Join-Path $dir 'inventory.json') $inventory

    # 1. Preserve pre-crash process snapshot
    $procSrc = Join-Path $Root 'Evidence/Logs/processes-previous.json'
    if (-not (Test-Path -LiteralPath $procSrc)) {
        $procSrc = Join-Path $Root 'Evidence/Logs/processes-latest.json'
    }
    if (Test-Path -LiteralPath $procSrc) {
        Copy-Item -LiteralPath $procSrc -Destination (Join-Path $dir 'processes.json') -Force -ErrorAction SilentlyContinue
    }

    # 2. Copy pre-crash logs with boot demarcation
    foreach ($name in @('telemetry-v2.csv','heartbeat-v2.csv','temperatures.csv','events.jsonl','supervisor.log','events.log','telemetry.log')) {
        $path=Join-Path $Root "Evidence/Logs/$name"
        if (Test-Path -LiteralPath $path) {
            if ($name.EndsWith('.csv')) {
                Invoke-CMFileLock $path {
                    $header=Get-Content -LiteralPath $path -TotalCount 1 -Encoding UTF8 -ErrorAction Stop
                    $rawTail=@(Get-Content -LiteralPath $path -Tail 500 -Encoding UTF8 -ErrorAction Stop)
                    $tail=@()
                    foreach ($l in $rawTail) {
                        if ($l -eq $header) { continue }
                        $cols = $l.Split(';')
                        if ($cols.Length -gt 1) {
                            $rowUtc = $cols[1].Trim('"')
                            $rowDto = [DateTimeOffset]::MinValue
                            if ([DateTimeOffset]::TryParse($rowUtc, [ref]$rowDto)) {
                                if ($rowDto.UtcDateTime -le $bootUtcDt) { $tail += $l }
                            } else { $tail += $l }
                        } else { $tail += $l }
                    }
                    if ($tail.Count -eq 0 -and $rawTail.Count -gt 0) {
                        $tail = @($rawTail | Where-Object { $_ -ne $header })
                    }
                    if ($tail.Count -gt 300) { $tail = $tail[($tail.Count - 300)..($tail.Count - 1)] }
                    $outLines = @($header) + $tail
                    $outLines | Set-Content -LiteralPath (Join-Path $dir $name) -Encoding UTF8
                }
            } else { Get-Content -LiteralPath $path -Tail 300 -Encoding UTF8 -ErrorAction Stop | Set-Content -LiteralPath (Join-Path $dir $name) -Encoding UTF8 }
        }
    }

    # 3. Calculate crash death metrics from pre-crash heartbeat
    $lastHeartbeatUtc = $null
    $crashGapSeconds = $null
    $hbIncidentPath = Join-Path $dir 'heartbeat-v2.csv'
    if (Test-Path -LiteralPath $hbIncidentPath) {
        $hbRows = @(Import-Csv -LiteralPath $hbIncidentPath -Delimiter ';' -ErrorAction SilentlyContinue)
        if ($hbRows.Count) {
            $lastHbUtcStr = $hbRows[-1].Utc
            $lastHbDto = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse($lastHbUtcStr, [ref]$lastHbDto)) {
                $lastHeartbeatUtc = $lastHbDto.UtcDateTime.ToString('o')
                $crashGapSeconds = [math]::Round(($bootUtcDt - $lastHbDto.UtcDateTime).TotalSeconds, 1)
            }
        }
    }

    # 4. Telemetry extremes in the last 15 minutes before crash
    $preCrashExtremes = [ordered]@{
        WindowMinutes = 15
        SampleCount = 0
        MaxCpuUsagePct = $null
        MinRamAvailableMB = $null
        MaxRamUsedPct = $null
        MaxDiskQueueLength = $null
        MaxIoLatencyMs = $null
        Min12V = $null; Max12V = $null
        Min5V = $null; Max5V = $null
        Min3V3 = $null; Max3V3 = $null
        MinVcore = $null; MaxVcore = $null
        MaxCpuTemp = $null
        MaxDiskTemp = $null
        MaxThermalZoneTemp = $null
    }
    $telIncidentPath = Join-Path $dir 'telemetry-v2.csv'
    if (Test-Path -LiteralPath $telIncidentPath) {
        $telRows = @(Import-Csv -LiteralPath $telIncidentPath -Delimiter ';' -ErrorAction SilentlyContinue)
        $windowCutoff = $bootUtcDt.AddMinutes(-15)
        $recentRows = @($telRows | Where-Object {
            $rDto = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse($_.Utc, [ref]$rDto)) { $rDto.UtcDateTime -ge $windowCutoff } else { $true }
        })
        if ($recentRows.Count) {
            $preCrashExtremes.SampleCount = $recentRows.Count
            foreach ($r in $recentRows) {
                if ($r.CpuUsagePct -and [double]$r.CpuUsagePct -gt $preCrashExtremes.MaxCpuUsagePct) { $preCrashExtremes.MaxCpuUsagePct = [double]$r.CpuUsagePct }
                if ($r.RamAvailableMB) {
                    $ram = [double]$r.RamAvailableMB
                    if ($null -eq $preCrashExtremes.MinRamAvailableMB -or $ram -lt $preCrashExtremes.MinRamAvailableMB) { $preCrashExtremes.MinRamAvailableMB = $ram }
                }
                if ($r.RamUsedPct -and [double]$r.RamUsedPct -gt $preCrashExtremes.MaxRamUsedPct) { $preCrashExtremes.MaxRamUsedPct = [double]$r.RamUsedPct }
                if ($r.DiskQueueLength -and [double]$r.DiskQueueLength -gt $preCrashExtremes.MaxDiskQueueLength) { $preCrashExtremes.MaxDiskQueueLength = [double]$r.DiskQueueLength }
                if ($r.PSObject.Properties['IoLatencyMs'] -and $r.IoLatencyMs -and [double]$r.IoLatencyMs -gt $preCrashExtremes.MaxIoLatencyMs) { $preCrashExtremes.MaxIoLatencyMs = [double]$r.IoLatencyMs }
                if ($r.HardwareSensorsJson) {
                    try {
                        $s = $r.HardwareSensorsJson | ConvertFrom-Json
                        if ($s.Plus12V -and $s.Plus12V -ne 'N/A') {
                            $v = [double]$s.Plus12V
                            if ($null -eq $preCrashExtremes.Min12V -or $v -lt $preCrashExtremes.Min12V) { $preCrashExtremes.Min12V = $v }
                            if ($null -eq $preCrashExtremes.Max12V -or $v -gt $preCrashExtremes.Max12V) { $preCrashExtremes.Max12V = $v }
                        }
                        if ($s.Plus5V -and $s.Plus5V -ne 'N/A') {
                            $v = [double]$s.Plus5V
                            if ($null -eq $preCrashExtremes.Min5V -or $v -lt $preCrashExtremes.Min5V) { $preCrashExtremes.Min5V = $v }
                            if ($null -eq $preCrashExtremes.Max5V -or $v -gt $preCrashExtremes.Max5V) { $preCrashExtremes.Max5V = $v }
                        }
                        if ($s.Plus33V -and $s.Plus33V -ne 'N/A') {
                            $v = [double]$s.Plus33V
                            if ($null -eq $preCrashExtremes.Min3V3 -or $v -lt $preCrashExtremes.Min3V3) { $preCrashExtremes.Min3V3 = $v }
                            if ($null -eq $preCrashExtremes.Max3V3 -or $v -gt $preCrashExtremes.Max3V3) { $preCrashExtremes.Max3V3 = $v }
                        }
                        if ($s.Vcore -and $s.Vcore -ne 'N/A') {
                            $v = [double]$s.Vcore
                            if ($null -eq $preCrashExtremes.MinVcore -or $v -lt $preCrashExtremes.MinVcore) { $preCrashExtremes.MinVcore = $v }
                            if ($null -eq $preCrashExtremes.MaxVcore -or $v -gt $preCrashExtremes.MaxVcore) { $preCrashExtremes.MaxVcore = $v }
                        }
                        if ($s.CpuTemp -and $s.CpuTemp -ne 'N/A' -and [double]$s.CpuTemp -gt $preCrashExtremes.MaxCpuTemp) { $preCrashExtremes.MaxCpuTemp = [double]$s.CpuTemp }
                        if ($s.DiskTemp -and $s.DiskTemp -ne 'N/A' -and [double]$s.DiskTemp -gt $preCrashExtremes.MaxDiskTemp) { $preCrashExtremes.MaxDiskTemp = [double]$s.DiskTemp }
                        if ($s.ThermalZoneTemp -and [double]$s.ThermalZoneTemp -gt $preCrashExtremes.MaxThermalZoneTemp) { $preCrashExtremes.MaxThermalZoneTemp = [double]$s.ThermalZoneTemp }
                    } catch { }
                }
            }
        }
    }

    # 5. SMART delta analysis
    $smartAnalysis = $null
    $smartCurPath = Join-Path $Root 'Evidence/State/smart-counters.json'
    $smartPrevPath = Join-Path $Root 'Evidence/State/previous-smart-counters.json'
    if (Test-Path -LiteralPath $smartCurPath) {
        $curSmart = Read-CMJson $smartCurPath
        $prevSmart = if (Test-Path -LiteralPath $smartPrevPath) { Read-CMJson $smartPrevPath } else { $null }
        $smartAnalysis = Compare-CMSmartSnapshots -CurrentSnapshot $curSmart -PreviousSnapshot $prevSmart
    }

    $workerStates = if ($PreviousSession -and $PreviousSession.LastKnownHealth) { $PreviousSession.LastKnownHealth.Workers } else { $null }

    $preCrashMetrics = [ordered]@{
        LastHeartbeatUtc = $lastHeartbeatUtc
        CrashGapSeconds = $crashGapSeconds
        WorkerStatesAtCrash = $workerStates
        TelemetryExtremes15m = [pscustomobject]$preCrashExtremes
    }

    $report=[ordered]@{
        SchemaVersion=2; GeneratedUtc=[datetime]::UtcNow.ToString('o'); Boot=$Boot
        PreviousSession=$PreviousSession; Classification=$classification
        PreCrashMetrics=[pscustomobject]$preCrashMetrics
        SmartAnalysis=$smartAnalysis
        BootEvents=@($Events); Limitations=@('No dump analysis performed. Heartbeat timestamps are last confirmed monitor activity, not an exact failure time.','Disk errors and WHEA are evidence, not an automatic root-cause verdict.','Software polling cannot rule out short power loss, CPU overheating or hardware watchdog resets.')
    }
    Write-CMJson (Join-Path $dir 'report.json') $report

    # Generate human-readable report.txt
    $lines=@('CrashMonitor v2 - boot incident',"Boot UTC: $($Boot.BootUtc)","Boot key: $($Boot.BootKey)","Classification: $($classification.Type)",$classification.Explanation,'')
    $lines+=@('--- Pre-Crash Timing & Metrics ---',
        "Last heartbeat UTC: $(if ($lastHeartbeatUtc) { $lastHeartbeatUtc } else { 'None' })",
        "Silence / gap to boot: $(if ($null -ne $crashGapSeconds) { "${crashGapSeconds}s" } else { 'Unknown' })"
    )
    if ($smartAnalysis) {
        $lines+=@("SMART verdict: $($smartAnalysis.Verdict)", "Hardware power loss confirmed: $($smartAnalysis.HardwarePowerLossConfirmed)")
    }
    if ($preCrashExtremes.SampleCount -gt 0) {
        $lines+=@("Max CPU load (15m): $(if ($null -ne $preCrashExtremes.MaxCpuUsagePct) { "$($preCrashExtremes.MaxCpuUsagePct)%" } else { 'N/A' })",
            "Min RAM available (15m): $(if ($null -ne $preCrashExtremes.MinRamAvailableMB) { "$($preCrashExtremes.MinRamAvailableMB) MB" } else { 'N/A' })",
            "Max Disk Queue (15m): $(if ($null -ne $preCrashExtremes.MaxDiskQueueLength) { $preCrashExtremes.MaxDiskQueueLength } else { 'N/A' })",
            "Max I/O Probe Latency (15m): $(if ($null -ne $preCrashExtremes.MaxIoLatencyMs) { "$($preCrashExtremes.MaxIoLatencyMs)ms" } else { 'N/A' })",
            "Voltage rails (15m): +12V [$($preCrashExtremes.Min12V) .. $($preCrashExtremes.Max12V)], +5V [$($preCrashExtremes.Min5V) .. $($preCrashExtremes.Max5V)], +3.3V [$($preCrashExtremes.Min3V3) .. $($preCrashExtremes.Max3V3)]",
            "Max temperatures (15m): CPU=$(if ($null -ne $preCrashExtremes.MaxCpuTemp) { "$($preCrashExtremes.MaxCpuTemp)C" } else { 'N/A' }), Disk=$(if ($null -ne $preCrashExtremes.MaxDiskTemp) { "$($preCrashExtremes.MaxDiskTemp)C" } else { 'N/A' }), ThermalZone=$(if ($null -ne $preCrashExtremes.MaxThermalZoneTemp) { "$($preCrashExtremes.MaxThermalZoneTemp)C" } else { 'N/A' })"
        )
    }
    $lines+=@('','Events (UTC / provider / ID / message):')
    $lines+=@($Events | Sort-Object Utc | ForEach-Object { "$($_.Utc) | $($_.Provider) | $($_.EventId) | $($_.Message)" })
    $lines+=@('','Limits:')+$report.Limitations
    [IO.File]::WriteAllLines((Join-Path $dir 'report.txt'),[string[]]$lines,(New-Object Text.UTF8Encoding($false)))

    # Each event in report.json includes EventData; full XML is copied independently.
    $xmlDir=Join-Path $dir 'XML'; [void][IO.Directory]::CreateDirectory($xmlDir)
    foreach ($ev in $Events) {
        $safe=$ev.Channel -replace '[^a-zA-Z0-9_-]','_'
        $stamp=[datetime]::Parse($ev.Utc).ToUniversalTime().Ticks
        $source=Join-Path $Root "Evidence/Events/$safe/$($ev.RecordId)-$stamp.xml"
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $xmlDir "$safe-$($ev.RecordId)-$stamp.xml") -Force }
    }
    $exportErrors=@()
    $since=[datetime]::Parse($Boot.BootUtc).ToUniversalTime().AddHours(-24)
    try { Export-CMEvtx -Directory (Join-Path $dir 'EVTX') -SinceUtc $since }
    catch { $exportErrors+= [string]$_; Write-CMLog $Root 'events' "EVTX incident export failed: $_" 'ERROR' }
    Write-CMJson (Join-Path $dir 'complete.json') @{ CompletedUtc=[datetime]::UtcNow.ToString('o'); ExportErrors=$exportErrors; Classification=$classification.Type }
}

function Export-CMDiagnostics {
    param([string]$Root, [string]$Destination, [hashtable]$Config, [switch]$FullHistory)
    $stamp=[datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)
    $dir=Join-Path $Destination "CrashMonitor-Diagnostics-$stamp"
    [void][IO.Directory]::CreateDirectory($dir)
    Write-CMJson (Join-Path $dir 'inventory.json') (Get-CMInventory)
    foreach ($name in @('Logs','State','Incidents','Events','Archive')) {
        $source=Join-Path $Root "Evidence/$name"
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $dir -Recurse -Force -ErrorAction Stop }
    }
    $since=[datetime]::UtcNow.AddHours(-[double]$Config.EventBackfillHours)
    if ($FullHistory) { $since=$null }
    Export-CMEvtx -Directory (Join-Path $dir 'EVTX') -SinceUtc $since
    $manifest=@(Get-ChildItem $dir -File -Recurse | ForEach-Object {
        [pscustomobject]@{ Path=$_.FullName.Substring($dir.Length+1); Bytes=$_.Length; SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    })
    Write-CMJson (Join-Path $dir 'manifest.json') @{ CapturedUtc=[datetime]::UtcNow.ToString('o'); Files=$manifest; FullHistory=[bool]$FullHistory; Note='Live snapshot: individual logs may advance during copying. Memory dumps and legacy logs are not copied.' }
    $zip="$dir.zip"
    Compress-Archive -LiteralPath $dir -DestinationPath $zip -CompressionLevel Optimal -ErrorAction Stop
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    return $zip
}
Export-ModuleMember -Function Invoke-CMNative, Get-CMInventory, Export-CMEvtx, New-CMIncident, Export-CMDiagnostics
