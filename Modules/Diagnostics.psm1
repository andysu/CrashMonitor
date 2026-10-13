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
    param([string]$Directory, [Nullable[datetime]]$SinceUtc, [object[]]$ExtraChannels = @())
    [void][IO.Directory]::CreateDirectory($Directory)
    # Hardware channels absent on this Windows build are skipped; a failed export of one is reported after the rest are tried.
    # They are exported with their capture filter: unfiltered, card-reader "no media" errors alone add ~3 MB a day.
    $sources=@(@{Name='System'},@{Name='Application'}) + @($ExtraChannels | Where-Object { $_.Name -and (Get-WinEvent -ListLog $_.Name -ErrorAction SilentlyContinue) })
    $extraErrors=@()
    foreach ($source in $sources) {
        $channel=[string]$source.Name
        $safe=$channel -replace '[^a-zA-Z0-9_-]','_'
        $dest=Join-Path $Directory "$safe.evtx"
        $args=@('epl',$channel,('"{0}"' -f $dest),'/ow:true')
        $conditions=@()
        if ($null -ne $SinceUtc) { $conditions+=("TimeCreated[@SystemTime >= '{0}']" -f ([datetime]$SinceUtc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')) }
        if ($source.MaxLevel) { $conditions+=('(' + ((1..[math]::Max(1,[math]::Min(4,[int]$source.MaxLevel)) | ForEach-Object { "Level=$_" }) -join ' or ') + ')') }
        $query=''
        if ($conditions.Count) { $query="System[$($conditions -join ' and ')]" }
        if ($source.EventDataFilter) { $query=(@($query,"EventData[$($source.EventDataFilter)]") | Where-Object { $_ }) -join ' and ' }
        if ($query) { $args+=('/q:"*[{0}]"' -f $query) }
        if ($channel -in @('System','Application')) {
            Invoke-CMNative -FilePath (Join-Path $env:SystemRoot 'System32/wevtutil.exe') -Arguments $args -OutputPrefix (Join-Path $Directory "$safe-export") -TimeoutSeconds 60
        } else {
            try { Invoke-CMNative -FilePath (Join-Path $env:SystemRoot 'System32/wevtutil.exe') -Arguments $args -OutputPrefix (Join-Path $Directory "$safe-export") -TimeoutSeconds 60 }
            catch { $extraErrors+="${channel}: $_" }
        }
    }
    if ($extraErrors.Count) { throw ('Hardware channel EVTX export failed: ' + ($extraErrors -join '; ')) }
}

function Get-CMHardwareChannels {
    param([hashtable]$Config)
    return @(@(Get-CMValue $Config 'HardwareEventChannels' @()) | ForEach-Object {
        @{ Name=[string](Get-CMValue $_ 'Name'); MaxLevel=[int](Get-CMValue $_ 'MaxLevel' 4); EventDataFilter=[string](Get-CMValue $_ 'EventDataFilter' '') }
    } | Where-Object { $_.Name })
}

# Storage health history: one row per disk every StorageHealthIntervalMinutes (events worker).
# Windows reliability counters (CIM) are sparse on many disks; smartctl in Tools/smartmontools adds the SMART
# attributes that point at hardware: reallocated/pending sectors, CRC (cable) errors, command timeouts, NVMe media errors.
$script:StorageHealthColumns = @('SchemaVersion','Utc','BootKey','Source','DeviceId','Model','Serial','BusType','MediaType','Health','SmartPassed','TemperatureC','TemperatureMaxC','PowerOnHours','PowerCycles','UnsafeShutdowns','StartStopCycles','LoadUnloadCycles','WearPct','AvailableSparePct','ReadErrorsTotal','ReadErrorsUncorrected','WriteErrorsTotal','WriteErrorsUncorrected','ReadLatencyMaxMs','WriteLatencyMaxMs','FlushLatencyMaxMs','ReallocatedSectors','PendingSectors','OfflineUncorrectable','ReportedUncorrect','CommandTimeouts','CrcErrors','MediaErrors','ErrorLogEntries','CriticalWarning')
# Counters whose growth means new hardware trouble (or, for UnsafeShutdowns, a power loss).
$script:StorageGrowthCounters = @('UnsafeShutdowns','ReadErrorsTotal','ReadErrorsUncorrected','WriteErrorsTotal','WriteErrorsUncorrected','ReallocatedSectors','PendingSectors','OfflineUncorrectable','ReportedUncorrect','CommandTimeouts','CrcErrors','MediaErrors','ErrorLogEntries')

function New-CMStorageHealthRow {
    $row=[ordered]@{}
    foreach ($name in $script:StorageHealthColumns) { $row[$name]=$null }
    $row.SchemaVersion=1
    return $row
}

function ConvertFrom-CMReliabilityCounter {
    param($Disk, $Counter)
    $row=New-CMStorageHealthRow
    $row.Source='CIM'; $row.DeviceId=[string]$Disk.DeviceId; $row.Model=[string]$Disk.FriendlyName; $row.Serial=([string]$Disk.SerialNumber).Trim()
    $row.BusType=[string]$Disk.BusType; $row.MediaType=[string]$Disk.MediaType; $row.Health=[string]$Disk.HealthStatus
    if ($Counter) {
        foreach ($map in @(@('TemperatureC','Temperature'),@('TemperatureMaxC','TemperatureMax'),@('PowerOnHours','PowerOnHours'),@('StartStopCycles','StartStopCycleCount'),@('LoadUnloadCycles','LoadUnloadCycleCount'),@('WearPct','Wear'),@('ReadErrorsTotal','ReadErrorsTotal'),@('ReadErrorsUncorrected','ReadErrorsUncorrected'),@('WriteErrorsTotal','WriteErrorsTotal'),@('WriteErrorsUncorrected','WriteErrorsUncorrected'),@('ReadLatencyMaxMs','ReadLatencyMax'),@('WriteLatencyMaxMs','WriteLatencyMax'),@('FlushLatencyMaxMs','FlushLatencyMax'))) {
            $value=Get-CMValue $Counter $map[1]
            if ($null -ne $value) { $row[$map[0]]=[double]$value }
        }
    }
    return $row
}

function ConvertFrom-CMSmartctlJson {
    param($Info, [string]$Device)
    $row=New-CMStorageHealthRow
    $row.Source='smartctl'; $row.DeviceId=$Device; $row.Model=[string]$Info.model_name; $row.Serial=([string]$Info.serial_number).Trim()
    if ($Info.smart_status -and $null -ne $Info.smart_status.passed) { $row.SmartPassed=[bool]$Info.smart_status.passed }
    if ($Info.temperature -and $null -ne $Info.temperature.current) { $row.TemperatureC=[double]$Info.temperature.current }
    if ($Info.power_on_time -and $null -ne $Info.power_on_time.hours) { $row.PowerOnHours=[double]$Info.power_on_time.hours }
    if ($null -ne $Info.power_cycle_count) { $row.PowerCycles=[double]$Info.power_cycle_count }
    $nvme=$Info.nvme_smart_health_information_log
    if ($nvme) {
        $row.BusType='NVMe'
        foreach ($map in @(@('CriticalWarning','critical_warning'),@('AvailableSparePct','available_spare'),@('WearPct','percentage_used'),@('MediaErrors','media_errors'),@('ErrorLogEntries','num_err_log_entries'),@('UnsafeShutdowns','unsafe_shutdowns'),@('PowerCycles','power_cycles'),@('PowerOnHours','power_on_hours'))) {
            $value=Get-CMValue $nvme $map[1]
            if ($null -ne $value) { $row[$map[0]]=[double]$value }
        }
    }
    if ($Info.ata_smart_attributes -and $Info.ata_smart_attributes.table) {
        $ataMap=@{ 4='StartStopCycles'; 5='ReallocatedSectors'; 12='PowerCycles'; 187='ReportedUncorrect'; 188='CommandTimeouts'; 192='UnsafeShutdowns'; 193='LoadUnloadCycles'; 197='PendingSectors'; 198='OfflineUncorrectable'; 199='CrcErrors' }
        foreach ($attr in $Info.ata_smart_attributes.table) {
            $column=$ataMap[[int]$attr.id]
            if ($column -and $attr.raw -and $null -ne $attr.raw.value) {
                $value=[double]$attr.raw.value
                # Seagate packs attribute 188 as three 16-bit counters (raw "2 2 5" = 8590065669); the low word is the total.
                if ($attr.id -eq 188 -and $value -gt 65535) { $value=[double]([uint64]$attr.raw.value -band 0xFFFF) }
                $row[$column]=$value
            }
        }
        # Some drives (Toshiba DT01ACA100: 51 281 = 51 281) report the head load/unload count in 192 as well,
        # so 192 is not an emergency-retract counter there and must not be read as unsafe shutdowns.
        if ($null -ne $row.UnsafeShutdowns -and $row.UnsafeShutdowns -gt 0 -and $row.UnsafeShutdowns -eq $row.LoadUnloadCycles) { $row.UnsafeShutdowns=$null }
    }
    return $row
}

function Get-CMSmartctlPath {
    param([string]$ToolsDir)
    $path=Join-Path $ToolsDir 'smartmontools\smartctl.exe'
    if (Test-Path -LiteralPath $path) { return $path }
    $cmd=Get-Command 'smartctl.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-CMSmartctl {
    param([string]$Path, [string]$Arguments, [int]$TimeoutMs = 10000)
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$Path; $psi.Arguments=$Arguments; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    $proc=[Diagnostics.Process]::Start($psi)
    try {
        $read=$proc.StandardOutput.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutMs)) { try { $proc.Kill() } catch { }; return $null }
        # smartctl sets exit-code bits for disk warnings; the JSON is still valid, so it is parsed regardless.
        return $read.Result
    } finally { $proc.Dispose() }
}

function ConvertTo-CMSerialKey { param([string]$Serial) return (($Serial -replace '[^A-Za-z0-9]','').TrimStart('0')).ToUpperInvariant() }

function Get-CMStorageHealth {
    param([string]$ToolsDir)
    $rows=New-Object Collections.Generic.List[object]
    $disks=@()
    try { $disks=@(Get-PhysicalDisk -ErrorAction Stop) } catch { }
    foreach ($disk in $disks) {
        $counter=$null
        try { $counter=$disk | Get-StorageReliabilityCounter -ErrorAction Stop } catch { }
        $rows.Add((ConvertFrom-CMReliabilityCounter $disk $counter))
    }
    $smartctl=Get-CMSmartctlPath $ToolsDir
    if ($smartctl) {
        $scan=$null
        try { $scan=(Invoke-CMSmartctl $smartctl '--scan-open -j') | ConvertFrom-Json } catch { }
        foreach ($dev in @($scan.devices)) {
            if (-not $dev.name) { continue }
            $info=$null
            try { $info=(Invoke-CMSmartctl $smartctl "-a $($dev.name) -j") | ConvertFrom-Json } catch { }
            if (-not $info -or -not $info.model_name) { continue }
            $smart=ConvertFrom-CMSmartctlJson $info ([string]$dev.name)
            # Match the CIM row by serial; NVMe serials differ between the two sources, so fall back to a unique model name.
            $match=@($rows | Where-Object { $_.Serial -and (ConvertTo-CMSerialKey $_.Serial) -eq (ConvertTo-CMSerialKey $smart.Serial) })
            if (-not $match.Count) { $match=@($rows | Where-Object { $_.Model -and $_.Model.Trim() -eq $smart.Model.Trim() }) }
            if ($match.Count -eq 1) {
                foreach ($name in $script:StorageHealthColumns) { if ($null -ne $smart[$name] -and $name -notin @('Source','DeviceId','Model','Serial','SchemaVersion')) { $match[0][$name]=$smart[$name] } }
                $match[0].Source='CIM+smartctl'
            } else { $rows.Add($smart) }
        }
    }
    return $rows.ToArray()
}

function Compare-CMStorageHealth {
    param([object[]]$Previous, [object[]]$Current)
    $changes=New-Object Collections.Generic.List[object]
    $keyOf={ param($row) if ($row.Serial) { 'S:' + (ConvertTo-CMSerialKey $row.Serial) } else { "D:$($row.DeviceId)|$($row.Model)" } }
    $before=@{}
    foreach ($row in @($Previous)) { if ($row) { $before[(& $keyOf $row)]=$row } }
    foreach ($row in @($Current)) {
        $old=$before[(& $keyOf $row)]
        if (-not $old) { continue }
        $disk="$($row.Model) ($($row.Serial))".Trim()
        foreach ($name in $script:StorageGrowthCounters) {
            $was=Get-CMValue $old $name; $now=Get-CMValue $row $name
            if ($null -ne $was -and $null -ne $now -and "$was" -ne '' -and "$now" -ne '' -and [double]$now -gt [double]$was) { $changes.Add([pscustomobject]@{ Disk=$disk; Counter=$name; Before=[double]$was; After=[double]$now }) }
        }
        $wasHealth=[string](Get-CMValue $old 'Health'); $nowHealth=[string](Get-CMValue $row 'Health')
        if ($wasHealth -and $nowHealth -and $wasHealth -ne $nowHealth) { $changes.Add([pscustomobject]@{ Disk=$disk; Counter='Health'; Before=$wasHealth; After=$nowHealth }) }
        $wasPassed=Get-CMValue $old 'SmartPassed'; $nowPassed=Get-CMValue $row 'SmartPassed'
        if ("$wasPassed" -eq 'True' -and "$nowPassed" -eq 'False') { $changes.Add([pscustomobject]@{ Disk=$disk; Counter='SmartPassed'; Before=$true; After=$false }) }
        $warning=Get-CMValue $row 'CriticalWarning'
        if ("$warning" -ne '' -and [double]$warning -gt 0 -and "$warning" -ne "$(Get-CMValue $old 'CriticalWarning')") { $changes.Add([pscustomobject]@{ Disk=$disk; Counter='CriticalWarning'; Before=(Get-CMValue $old 'CriticalWarning'); After=[double]$warning }) }
    }
    return $changes.ToArray()
}

function Invoke-CMStorageHealthSnapshot {
    # Appends one storage-health.csv row per disk, logs counters that grew since the previous snapshot
    # (also across a reboot) and returns those changes for the incident report.
    param([string]$Root, [string]$ToolsDir, [string]$BootKey)
    $rows=@(Get-CMStorageHealth $ToolsDir)
    if (-not $rows.Count) { return @() }
    $utc=[datetime]::UtcNow.ToString('o')
    foreach ($row in $rows) {
        $row.Utc=$utc; $row.BootKey=$BootKey
        Write-CMCsv -Path (Join-Path $Root 'Evidence/Logs/storage-health.csv') -Columns $script:StorageHealthColumns -Row $row
    }
    $lastPath=Join-Path $Root 'Evidence/State/storage-health-last.json'
    $previous=$null
    try { $previous=Read-CMJson $lastPath } catch { Write-CMLog $Root 'events' "Unreadable storage-health-last.json; comparison skipped: $_" 'WARNING' }
    $changes=@()
    if ($previous) { $changes=@(Compare-CMStorageHealth @($previous.Disks) $rows) }
    foreach ($change in $changes) { Write-CMLog $Root 'events' "Storage health change: $($change.Disk) $($change.Counter) $($change.Before) -> $($change.After)" 'WARNING' }
    Write-CMJson $lastPath @{ Utc=$utc; BootKey=$BootKey; Disks=$rows }
    return $changes
}

function New-CMIncident {
    param([string]$Root, [hashtable]$Config, $Boot, [object[]]$Events, $PreviousSession, [object[]]$StorageHealthChanges = @())
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
    foreach ($name in @('telemetry-v2.csv','heartbeat-v2.csv','temperatures.csv','storage-health.csv','events.jsonl','supervisor.log','events.log','telemetry.log')) {
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
        $preCrashHb = @($hbRows | Where-Object {
            $dto = [DateTimeOffset]::MinValue
            [DateTimeOffset]::TryParse($_.Utc, [ref]$dto) -and $dto.UtcDateTime -le $bootUtcDt
        })
        if ($preCrashHb.Count) {
            $lastHbUtcStr = $preCrashHb[-1].Utc
            $lastHbDto = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse($lastHbUtcStr, [ref]$lastHbDto)) {
                $lastHeartbeatUtc = $lastHbDto.UtcDateTime.ToString('o')
                $crashGapSeconds = [math]::Round(($bootUtcDt - $lastHbDto.UtcDateTime).TotalSeconds, 1)
            }
        }
    }

    # 4. Telemetry extremes in the last 15 minutes before crash
    $parseNum = {
        param($raw)
        if ($null -eq $raw -or $raw -eq '' -or $raw -eq 'N/A') { return $null }
        $clean = [string]$raw -replace '[^\d\.-]', ''
        $val = 0.0
        if ([double]::TryParse($clean, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$val)) { return $val }
        return $null
    }

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
        $anchorUtc = $bootUtcDt
        if ($lastHeartbeatUtc) {
            $aDto = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse($lastHeartbeatUtc, [ref]$aDto)) { $anchorUtc = $aDto.UtcDateTime }
        }
        $windowCutoff = $anchorUtc.AddMinutes(-15)
        $recentRows = @($telRows | Where-Object {
            $rDto = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse($_.Utc, [ref]$rDto)) {
                $rDto.UtcDateTime -ge $windowCutoff -and $rDto.UtcDateTime -le $anchorUtc
            } else { $false }
        })
        if ($recentRows.Count) {
            $preCrashExtremes.SampleCount = $recentRows.Count
            foreach ($r in $recentRows) {
                $cpu = & $parseNum $r.CpuUsagePct
                if ($null -ne $cpu -and ($null -eq $preCrashExtremes.MaxCpuUsagePct -or $cpu -gt $preCrashExtremes.MaxCpuUsagePct)) { $preCrashExtremes.MaxCpuUsagePct = $cpu }

                $ramAvail = & $parseNum $r.RamAvailableMB
                if ($null -ne $ramAvail -and ($null -eq $preCrashExtremes.MinRamAvailableMB -or $ramAvail -lt $preCrashExtremes.MinRamAvailableMB)) { $preCrashExtremes.MinRamAvailableMB = $ramAvail }

                $ramUsed = & $parseNum $r.RamUsedPct
                if ($null -ne $ramUsed -and ($null -eq $preCrashExtremes.MaxRamUsedPct -or $ramUsed -gt $preCrashExtremes.MaxRamUsedPct)) { $preCrashExtremes.MaxRamUsedPct = $ramUsed }

                $qLen = & $parseNum $r.DiskQueueLength
                if ($null -ne $qLen -and ($null -eq $preCrashExtremes.MaxDiskQueueLength -or $qLen -gt $preCrashExtremes.MaxDiskQueueLength)) { $preCrashExtremes.MaxDiskQueueLength = $qLen }

                if ($r.PSObject.Properties['IoLatencyMs']) {
                    $ioLat = & $parseNum $r.IoLatencyMs
                    if ($null -ne $ioLat -and ($null -eq $preCrashExtremes.MaxIoLatencyMs -or $ioLat -gt $preCrashExtremes.MaxIoLatencyMs)) { $preCrashExtremes.MaxIoLatencyMs = $ioLat }
                }

                if ($r.HardwareSensorsJson) {
                    try {
                        $s = $r.HardwareSensorsJson | ConvertFrom-Json
                        $v12 = & $parseNum $s.Plus12V
                        if ($null -ne $v12) {
                            if ($null -eq $preCrashExtremes.Min12V -or $v12 -lt $preCrashExtremes.Min12V) { $preCrashExtremes.Min12V = $v12 }
                            if ($null -eq $preCrashExtremes.Max12V -or $v12 -gt $preCrashExtremes.Max12V) { $preCrashExtremes.Max12V = $v12 }
                        }
                        $v5 = & $parseNum $s.Plus5V
                        if ($null -ne $v5) {
                            if ($null -eq $preCrashExtremes.Min5V -or $v5 -lt $preCrashExtremes.Min5V) { $preCrashExtremes.Min5V = $v5 }
                            if ($null -eq $preCrashExtremes.Max5V -or $v5 -gt $preCrashExtremes.Max5V) { $preCrashExtremes.Max5V = $v5 }
                        }
                        $v33 = & $parseNum $s.Plus33V
                        if ($null -ne $v33) {
                            if ($null -eq $preCrashExtremes.Min3V3 -or $v33 -lt $preCrashExtremes.Min3V3) { $preCrashExtremes.Min3V3 = $v33 }
                            if ($null -eq $preCrashExtremes.Max3V3 -or $v33 -gt $preCrashExtremes.Max3V3) { $preCrashExtremes.Max3V3 = $v33 }
                        }
                        $vCore = & $parseNum $s.Vcore
                        if ($null -ne $vCore) {
                            if ($null -eq $preCrashExtremes.MinVcore -or $vCore -lt $preCrashExtremes.MinVcore) { $preCrashExtremes.MinVcore = $vCore }
                            if ($null -eq $preCrashExtremes.MaxVcore -or $vCore -gt $preCrashExtremes.MaxVcore) { $preCrashExtremes.MaxVcore = $vCore }
                        }
                        $cTemp = & $parseNum $s.CpuTemp
                        if ($null -ne $cTemp -and ($null -eq $preCrashExtremes.MaxCpuTemp -or $cTemp -gt $preCrashExtremes.MaxCpuTemp)) { $preCrashExtremes.MaxCpuTemp = $cTemp }

                        $dTemp = & $parseNum $s.DiskTemp
                        if ($null -ne $dTemp -and ($null -eq $preCrashExtremes.MaxDiskTemp -or $dTemp -gt $preCrashExtremes.MaxDiskTemp)) { $preCrashExtremes.MaxDiskTemp = $dTemp }

                        $tzTemp = & $parseNum $s.ThermalZoneTemp
                        if ($null -ne $tzTemp -and ($null -eq $preCrashExtremes.MaxThermalZoneTemp -or $tzTemp -gt $preCrashExtremes.MaxThermalZoneTemp)) { $preCrashExtremes.MaxThermalZoneTemp = $tzTemp }
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
        $smartAnalysis = Compare-CMSmartSnapshots -CurrentSnapshot $curSmart -PreviousSnapshot $prevSmart -RestartClassification $classification.Type
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
        StorageHealthChanges=@($StorageHealthChanges)
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
        $lines+=@("SMART verdict: $($smartAnalysis.Verdict)", "Power loss suspected: $($smartAnalysis.PowerLossSuspected) (Confidence: $($smartAnalysis.Confidence))")
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
    if (@($StorageHealthChanges).Count) {
        $lines+=@('','--- Storage counters that grew since the last snapshot before this boot ---')
        $lines+=@($StorageHealthChanges | ForEach-Object { "$($_.Disk): $($_.Counter) $($_.Before) -> $($_.After)" })
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
    try { Export-CMEvtx -Directory (Join-Path $dir 'EVTX') -SinceUtc $since -ExtraChannels (Get-CMHardwareChannels $Config) }
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
    Export-CMEvtx -Directory (Join-Path $dir 'EVTX') -SinceUtc $since -ExtraChannels (Get-CMHardwareChannels $Config)
    $manifest=@(Get-ChildItem $dir -File -Recurse | ForEach-Object {
        [pscustomobject]@{ Path=$_.FullName.Substring($dir.Length+1); Bytes=$_.Length; SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    })
    Write-CMJson (Join-Path $dir 'manifest.json') @{ CapturedUtc=[datetime]::UtcNow.ToString('o'); Files=$manifest; FullHistory=[bool]$FullHistory; Note='Live snapshot: individual logs may advance during copying. Memory dumps and legacy logs are not copied.' }
    $zip="$dir.zip"
    Compress-Archive -LiteralPath $dir -DestinationPath $zip -CompressionLevel Optimal -ErrorAction Stop
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    return $zip
}
Export-ModuleMember -Function Invoke-CMNative, Get-CMInventory, Export-CMEvtx, ConvertFrom-CMReliabilityCounter, ConvertFrom-CMSmartctlJson, Get-CMStorageHealth, Compare-CMStorageHealth, Invoke-CMStorageHealthSnapshot, New-CMIncident, Export-CMDiagnostics
