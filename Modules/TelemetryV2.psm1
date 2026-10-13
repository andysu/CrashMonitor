#Requires -Version 5.1
Import-Module (Join-Path $PSScriptRoot 'Common.psm1')
# ProcessorPerformancePct is appended last so existing column positions stay valid for readers that index them.
$script:Columns = @('SchemaVersion','Utc','Local','UtcOffsetMinutes','BootKey','CpuUsagePct','RamAvailableMB','RamUsedPct','CommittedMB','CommitLimitMB','PoolNonpagedMB','PoolPagedMB','PagesPerSec','DiskQueueLength','DiskReadBytesPerSec','DiskWriteBytesPerSec','TopMemoryProcesses','DiskCountersJson','TemperatureStatus','HardwareSensorsJson','ErrorsJson','IoLatencyMs','DurationMs','ProcessorPerformancePct')

function Get-CMTelemetryColumns { return $script:Columns }

# Persistent PerformanceCounter objects: one sample costs ~80 ms instead of ~900 ms for the WMI formatted classes,
# and rates are averaged over the whole sampling interval. $null = not initialised; $false = unavailable, use WMI.
$script:FastCounters = $null
$script:TotalMemoryMB = $null
$script:DiskCounters = $null
$script:DiskInstanceKey = $null

function Initialize-CMPerformanceCounters {
    if ($null -ne $script:FastCounters) { return [bool]$script:FastCounters }
    try {
        $counters = [ordered]@{ Cpu = New-Object Diagnostics.PerformanceCounter('Processor', '% Processor Time', '_Total') }
        foreach ($pair in @(@('Available','Available Bytes'),@('Committed','Committed Bytes'),@('CommitLimit','Commit Limit'),@('PoolNonpaged','Pool Nonpaged Bytes'),@('PoolPaged','Pool Paged Bytes'),@('Pages','Pages/sec'))) {
            $counters[$pair[0]] = New-Object Diagnostics.PerformanceCounter('Memory', $pair[1])
        }
        # Below 100 under load means the CPU runs under its base clock: thermal or power-limit throttling.
        try { $counters['Performance'] = New-Object Diagnostics.PerformanceCounter('Processor Information', '% Processor Performance', '_Total') } catch { }
        foreach ($counter in $counters.Values) { [void]$counter.NextValue() }
        $script:TotalMemoryMB = [double](Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 10 -ErrorAction Stop).TotalVisibleMemorySize / 1024
        $script:FastCounters = $counters
        Update-CMDiskCounters
        return $true
    } catch {
        # English counter names can be missing on some localized systems; the WMI classes are language-independent.
        $script:FastCounters = $false
        return $false
    }
}

function Update-CMDiskCounters {
    # Recreates the per-disk counters only when the set of disks changes (e.g. a USB disk is attached).
    $names = @((New-Object Diagnostics.PerformanceCounterCategory('PhysicalDisk')).GetInstanceNames() | Sort-Object)
    $key = $names -join '|'
    if ($key -eq $script:DiskInstanceKey) { return }
    if ($script:DiskCounters) { foreach ($set in $script:DiskCounters.Values) { foreach ($pc in $set.Values) { $pc.Dispose() } } }
    $script:DiskCounters = [ordered]@{}
    foreach ($name in $names) {
        $set = [ordered]@{}
        foreach ($pair in @(@('CurrentDiskQueueLength','Current Disk Queue Length'),@('DiskReadBytesPersec','Disk Read Bytes/sec'),@('DiskWriteBytesPersec','Disk Write Bytes/sec'),@('PercentDiskTime','% Disk Time'))) {
            $pc = New-Object Diagnostics.PerformanceCounter('PhysicalDisk', $pair[1], $name)
            [void]$pc.NextValue()
            $set[$pair[0]] = $pc
        }
        $script:DiskCounters[$name] = $set
    }
    $script:DiskInstanceKey = $key
}

function Read-CMPerformanceCounters {
    param([System.Collections.IDictionary]$Row)
    $c = $script:FastCounters
    $Row.CpuUsagePct = [math]::Round([double]$c.Cpu.NextValue(), 1)
    if ($c.Contains('Performance')) { $Row.ProcessorPerformancePct = [math]::Round([double]$c.Performance.NextValue(), 1) }
    $Row.RamAvailableMB = [math]::Round([double]$c.Available.NextValue() / 1MB, 2)
    if ($script:TotalMemoryMB -gt 0) { $Row.RamUsedPct = [math]::Round(100 * (1 - $Row.RamAvailableMB / $script:TotalMemoryMB), 2) }
    foreach ($pair in @(@('CommittedMB','Committed'),@('CommitLimitMB','CommitLimit'),@('PoolNonpagedMB','PoolNonpaged'),@('PoolPagedMB','PoolPaged'))) {
        $Row[$pair[0]] = [math]::Round([double]$c[$pair[1]].NextValue() / 1MB, 2)
    }
    $Row.PagesPerSec = [math]::Round([double]$c.Pages.NextValue(), 2)
    Update-CMDiskCounters
    $disks = @(foreach ($name in $script:DiskCounters.Keys) {
        $set = $script:DiskCounters[$name]
        [pscustomobject][ordered]@{
            Name = $name
            CurrentDiskQueueLength = [math]::Round([double]$set.CurrentDiskQueueLength.NextValue(), 2)
            DiskReadBytesPersec = [math]::Round([double]$set.DiskReadBytesPersec.NextValue())
            DiskWriteBytesPersec = [math]::Round([double]$set.DiskWriteBytesPersec.NextValue())
            PercentDiskTime = [math]::Round([double]$set.PercentDiskTime.NextValue(), 1)
        }
    })
    $total = $disks | Where-Object Name -eq '_Total' | Select-Object -First 1
    if ($total) { $Row.DiskQueueLength = $total.CurrentDiskQueueLength; $Row.DiskReadBytesPerSec = $total.DiskReadBytesPersec; $Row.DiskWriteBytesPerSec = $total.DiskWriteBytesPersec }
    $Row.DiskCountersJson = ConvertTo-Json -InputObject $disks -Compress
}

function Get-CMCounterMode {
    if ($script:FastCounters) { return 'PerformanceCounter' }
    return 'WMI'
}

function Initialize-CMTelemetry {
    # The first performance-counter query in a process is the slowest (CIM session setup; on a cold boot also the
    # WMI performance provider load) and can exceed the 4 s per-sample timeout. One discarded query warms it up.
    # The persistent counters are created here too, so the first sample already has a full-interval average.
    param([int]$TimeoutSec = 30)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $null = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -OperationTimeoutSec $TimeoutSec -ErrorAction Stop
        [void](Initialize-CMPerformanceCounters)
        return [pscustomobject]@{ Success=$true; DurationMs=$timer.ElapsedMilliseconds; Error=''; CounterMode=(Get-CMCounterMode) }
    } catch {
        return [pscustomobject]@{ Success=$false; DurationMs=$timer.ElapsedMilliseconds; Error=[string]$_; CounterMode=(Get-CMCounterMode) }
    }
}

function ConvertTo-CMSensorPrefix {
    # Same normalisation as the sensor keys built in VoltageMonitor.psm1 (ReadAllSensors).
    param([string]$Name)
    return $Name.Replace(' ', '_').Replace('#', '').Replace('+', 'Plus_').Replace('/', '_')
}

$script:DiskInventory = $null
function Get-CMDiskInventory {
    # Read once per worker: disk models and buses do not change while the monitor runs.
    if ($null -eq $script:DiskInventory) {
        try { $script:DiskInventory = @(Get-PhysicalDisk -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ FriendlyName=[string]$_.FriendlyName; MediaType=[string]$_.MediaType; BusType=[string]$_.BusType } }) }
        catch { $script:DiskInventory = @() }
    }
    return $script:DiskInventory
}

function Get-CMStorageTemperatures {
    param([string]$RawSummary, $Disks = @())
    $nvmeNand = $null; $nvmeCtrl = $null; $hddTemp = $null
    $values = @{}
    if ($RawSummary) {
        foreach ($part in ($RawSummary -split '\|')) {
            if ($part -match 'Samsung.*Temperature_Temperature_1:(\d+(\.\d+)?)' -or $part -match 'Samsung.*Temperature_Temperature:(\d+(\.\d+)?)') {
                if ($null -eq $nvmeNand) { $nvmeNand = [double]$Matches[1] }
            }
            if ($part -match 'Samsung.*Temperature_Temperature_2:(\d+(\.\d+)?)') {
                $nvmeCtrl = [double]$Matches[1]
            }
            if ($part -match 'ST1000.*Temperature:(\d+(\.\d+)?)') {
                $hddTemp = [double]$Matches[1]
            }
            $i = $part.LastIndexOf(':')
            if ($i -gt 0) { $values[$part.Substring(0, $i)] = $part.Substring($i + 1) }
        }
    }
    # Other vendors only when the Samsung 980 / ST1000 rules above found nothing, so the server values are unchanged.
    if ($null -eq $nvmeNand -and $null -eq $nvmeCtrl) {
        $nvme = @($Disks | Where-Object { $_.BusType -eq 'NVMe' }) | Select-Object -First 1
        if ($nvme) {
            $prefix = ConvertTo-CMSensorPrefix $nvme.FriendlyName
            if ($values.ContainsKey("${prefix}_Temperature_Temperature")) { $nvmeNand = [double]$values["${prefix}_Temperature_Temperature"] }
            if ($values.ContainsKey("${prefix}_Temperature_Temperature_2")) { $nvmeCtrl = [double]$values["${prefix}_Temperature_Temperature_2"] }
        }
    }
    if ($null -eq $hddTemp) {
        foreach ($hdd in @($Disks | Where-Object { $_.MediaType -eq 'HDD' })) {
            $key = "$(ConvertTo-CMSensorPrefix $hdd.FriendlyName)_Temperature_Temperature"
            if ($values.ContainsKey($key)) { $hddTemp = [double]$values[$key]; break }
        }
    }
    return [pscustomobject]@{ NvmeNand=$nvmeNand; NvmeCtrl=$nvmeCtrl; Hdd=$hddTemp }
}

function Get-CMSensorAlerts {
    # Returns sensor key -> log message for every reading currently out of range.
    param($Sensors, [string[]]$IgnoredTemperatureSensors = @())
    $alerts = [ordered]@{}
    if (-not $Sensors.RawSummary) { return $alerts }
    foreach ($part in ($Sensors.RawSummary -split '\|')) {
        if ($part -match 'Temperature.*:(\d+(\.\d+)?)') {
            $deg = [double]$Matches[1]
            $key = $part.Substring(0, $part.LastIndexOf(':'))
            # Distance to TjMax is headroom below the throttle point, not a temperature: 70 there means a cool CPU.
            if ($deg -lt 70.0 -or $key -like '*Distance_to_TjMax*') { continue }
            # Configured per machine for Super I/O inputs that are not wired (they report e.g. 94-97C on an idle board).
            if (@($IgnoredTemperatureSensors | Where-Object { $key -like $_ }).Count) { continue }
            $alerts[$key] = "CRITICAL: High temperature warning: $part (${deg}C >= 70C)"
        }
    }
    # ATX specification tolerances +/- 5%
    foreach ($rail in @(@('Plus12V','+12V',11.40,12.60,'11.40V - 12.60V'),@('Plus5V','+5V',4.75,5.25,'4.75V - 5.25V'),@('Plus33V','+3.3V',3.135,3.465,'3.135V - 3.465V'))) {
        $value = $Sensors[$rail[0]]
        if ($value -ne 'N/A' -and [double]$value -gt 0) {
            $v = [double]$value
            if ($v -lt $rail[2] -or $v -gt $rail[3]) { $alerts[$rail[0]] = "WARNING: $($rail[1]) rail out of ATX spec: ${v}V (spec: $($rail[4]))" }
        }
    }
    return $alerts
}

$script:ActiveSensorAlerts = @{}
function Write-CMSensorAlertChanges {
    # Logs an alert when it starts and when it clears instead of on every sample; the readings stay in telemetry-v2.csv.
    param([string]$Root, [System.Collections.IDictionary]$Alerts)
    foreach ($key in @($Alerts.Keys)) {
        if (-not $script:ActiveSensorAlerts.ContainsKey($key)) { Write-CMLog $Root 'telemetry' $Alerts[$key] 'WARNING' }
    }
    foreach ($key in @($script:ActiveSensorAlerts.Keys)) {
        if (-not $Alerts.Contains($key)) { Write-CMLog $Root 'telemetry' "Sensor alert cleared: $key" 'INFO' }
    }
    $script:ActiveSensorAlerts = @{}
    foreach ($key in @($Alerts.Keys)) { $script:ActiveSensorAlerts[$key] = $Alerts[$key] }
}

function Get-CMTelemetry {
    param([string]$Root, [string]$CodeRoot, [hashtable]$Config, $Boot)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $now = [DateTimeOffset]::Now
    $row = [ordered]@{ SchemaVersion=2; Utc=$now.UtcDateTime.ToString('o'); Local=$now.ToString('o'); UtcOffsetMinutes=$now.Offset.TotalMinutes; BootKey=$Boot.BootKey }
    foreach ($name in $script:Columns) { if (-not $row.Contains($name)) { $row[$name]=$null } }
    $errors = New-Object Collections.Generic.List[string]
    $fast = $false
    if ([bool](Get-CMValue $Config 'UsePerformanceCounters' $true)) { $fast = Initialize-CMPerformanceCounters }
    if ($fast) {
        try { Read-CMPerformanceCounters $row }
        catch { $errors.Add("Performance counters: $_ (WMI used for this sample)"); $script:FastCounters = $null; $fast = $false }
    }
    if (-not $fast) {
    try {
        $cpu = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -OperationTimeoutSec 4 -ErrorAction Stop
        if ($null -ne $cpu) { $row.CpuUsagePct=[double]$cpu.PercentProcessorTime }
        else { $errors.Add('CPU counter unavailable') }
    } catch { $errors.Add("CPU: $_") }
    try {
        $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 4 -ErrorAction Stop
        $total = [double]$os.TotalVisibleMemorySize / 1024
        $row.RamAvailableMB=[math]::Round([double]$os.FreePhysicalMemory / 1024,2)
        if ($total -gt 0) { $row.RamUsedPct=[math]::Round(100*(1-$row.RamAvailableMB/$total),2) }
    } catch { $errors.Add("RAM: $_") }
    try {
        $mem = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -OperationTimeoutSec 4 -ErrorAction Stop
        if ($null -eq $mem) { throw 'Memory counters unavailable' }
        foreach ($pair in @(@('CommittedMB','CommittedBytes'),@('CommitLimitMB','CommitLimit'),@('PoolNonpagedMB','PoolNonpagedBytes'),@('PoolPagedMB','PoolPagedBytes'))) {
            $row[$pair[0]]=[math]::Round([double]$mem.($pair[1])/1MB,2)
        }
        $row.PagesPerSec=[double]$mem.PagesPersec
    } catch { $errors.Add("Memory counters: $_") }
    try {
        $disks = @(Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -OperationTimeoutSec 4 -ErrorAction Stop)
        if (-not $disks.Count) { throw 'Disk counters unavailable' }
        $totalDisk = $disks | Where-Object Name -eq '_Total' | Select-Object -First 1
        if ($totalDisk) {
            $row.DiskQueueLength=[double]$totalDisk.CurrentDiskQueueLength
            $row.DiskReadBytesPerSec=[double]$totalDisk.DiskReadBytesPersec
            $row.DiskWriteBytesPerSec=[double]$totalDisk.DiskWriteBytesPersec
        }
        $row.DiskCountersJson=ConvertTo-Json -InputObject @($disks | Select-Object Name,CurrentDiskQueueLength,DiskReadBytesPersec,DiskWriteBytesPersec,PercentDiskTime) -Compress
    } catch { $errors.Add("Disk counters: $_") }
    # Optional: older systems have no Processor Information class, which is not a collector failure.
    try {
        $info = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -OperationTimeoutSec 4 -ErrorAction Stop
        if ($null -ne $info) { $row.ProcessorPerformancePct=[double]$info.PercentProcessorPerformance }
    } catch { }
    }
    try {
        $allProc = @(Get-Process -ErrorAction Stop | Sort-Object WorkingSet64 -Descending)
        $top = @($allProc | Select-Object -First 10 | ForEach-Object {
            [pscustomobject]@{ Name=$_.ProcessName; Pid=$_.Id; WorkingSetMB=[math]::Round($_.WorkingSet64/1MB,2) }
        })
        $row.TopMemoryProcesses=ConvertTo-Json -InputObject $top -Compress

        try {
            $allProcList = @($allProc | ForEach-Object {
                $cpuSec = $null
                try { $cpuSec = [math]::Round($_.TotalProcessorTime.TotalSeconds, 2) } catch {}
                [pscustomobject]@{
                    Pid = $_.Id
                    Name = $_.ProcessName
                    WS_MB = [math]::Round($_.WorkingSet64 / 1MB, 2)
                    PM_MB = [math]::Round($_.PrivateMemorySize64 / 1MB, 2)
                    CPU_s = $cpuSec
                    Handles = $_.HandleCount
                    Threads = $_.Threads.Count
                }
            })
            $procSnapshot = [ordered]@{
                CapturedUtc = $now.UtcDateTime.ToString('o')
                CapturedLocal = $now.ToString('o')
                BootKey = $Boot.BootKey
                TotalProcesses = $allProcList.Count
                Processes = $allProcList
            }
            Write-CMJson -Path (Join-Path $Root 'Evidence/Logs/processes-latest.json') -Value $procSnapshot
        } catch { $errors.Add("ProcessSnapshot: $_") }
    } catch { $errors.Add("Processes: $_") }
    # Storage I/O latency probe: verifies filesystem responsiveness
    $ioLatencyMs = $null
    try {
        $ioTimer = [Diagnostics.Stopwatch]::StartNew()
        $probePath = Join-Path $Root 'Evidence/State/io-probe.tmp'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $probePath))
        $probeBytes = [byte[]]@(0..255)
        $probeStream = [IO.File]::Open($probePath, 'Create', 'Write', 'None')
        try {
            $probeStream.Write($probeBytes, 0, $probeBytes.Length)
            $probeStream.Flush($true)
        } finally {
            $probeStream.Dispose()
        }
        $ioLatencyMs = [double]$ioTimer.ElapsedMilliseconds
        if ($ioLatencyMs -ge 1000) {
            Write-CMLog $Root 'telemetry' "WARNING: High storage write latency on probe: ${ioLatencyMs}ms" 'WARNING'
        }
    } catch {
        $errors.Add("Storage probe failed: $_")
        Write-CMLog $Root 'telemetry' "ERROR: Storage probe write failure: $_" 'ERROR'
    }
    $row.IoLatencyMs = $ioLatencyMs
    $row.TemperatureStatus='NOT_MEASURED'
    $hardwareSensorsLogged = $false
    if ($Config.EnableHardwareSensors) {
        try {
            if (-not (Get-Module VoltageMonitor)) {
                $vmPath = Join-Path $CodeRoot 'Modules/VoltageMonitor.psm1'
                if (Test-Path -LiteralPath $vmPath) { Import-Module $vmPath -ErrorAction SilentlyContinue }
            }
            $sensors=Get-CrashMonitorVoltageSnapshot -ToolsDir (Join-Path $Root 'Tools/LibreHardwareMonitor')
            $row.HardwareSensorsJson=$sensors | ConvertTo-Json -Compress
            if ($sensors.CpuTemp -ne 'N/A' -or $sensors.DiskTemp -ne 'N/A' -or $sensors.RawSummary -match 'Temperature') {
                $row.TemperatureStatus = 'OK'
                $hardwareSensorsLogged = $true
            } elseif ($sensors.RawSummary) {
                $row.TemperatureStatus = 'SENSORS_ACTIVE'
                $hardwareSensorsLogged = $true
            } else {
                $errors.Add('Hardware sensors returned no actual values')
            }

            # Temperature (>= 70C) and ATX rail alerts, logged when they start and clear
            if ($sensors.RawSummary) {
                Write-CMSensorAlertChanges $Root (Get-CMSensorAlerts $sensors @(Get-CMValue $Config 'IgnoredTemperatureSensors' @()))
            }

            # Dedicated real-time temperatures.csv logger
            try {
                $tempAlert = ''
                $storage = Get-CMStorageTemperatures $sensors.RawSummary @(Get-CMDiskInventory)
                $nvmeNand = $storage.NvmeNand; $nvmeCtrl = $storage.NvmeCtrl; $hddTemp = $storage.Hdd
                if (($nvmeCtrl -ge 70.0) -or ($nvmeNand -ge 70.0)) { $tempAlert = 'CRITICAL_HIGH_TEMP' }
                elseif (($nvmeCtrl -ge 60.0) -or ($nvmeNand -ge 60.0)) { $tempAlert = 'WARNING_ELEVATED_TEMP' }
                $tempRow = [ordered]@{
                    Utc = $now.UtcDateTime.ToString('o')
                    Local = $now.ToString('o')
                    NVMe_NAND_C = $nvmeNand
                    NVMe_Controller_C = $nvmeCtrl
                    HDD_C = $hddTemp
                    Status = $row.TemperatureStatus
                    Alert = $tempAlert
                }
                Write-CMCsv -Path (Join-Path $Root 'Evidence/Logs/temperatures.csv') -Columns @('Utc','Local','NVMe_NAND_C','NVMe_Controller_C','HDD_C','Status','Alert') -Row $tempRow
            } catch { }
        } catch { $errors.Add("Hardware sensors: $_") }
    }

    # Safe WMI ACPI ThermalZone fallback when hardware sensors are disabled or unavailable
    if (-not $hardwareSensorsLogged) {
        try {
            $tz = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -OperationTimeoutSec 3 -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($tz -and $tz.CurrentTemperature -gt 2732) {
                $acpiTemp = [math]::Round(($tz.CurrentTemperature - 2732) / 10.0, 1)
                $critTemp = $null
                if ($tz.CriticalTripPoint -gt 2732) {
                    $critTemp = [math]::Round(($tz.CriticalTripPoint - 2732) / 10.0, 1)
                }
                $row.TemperatureStatus = 'ACPI_WMI'
                $acpiData = [ordered]@{
                    Source = 'MSAcpi_ThermalZoneTemperature'
                    ThermalZoneTemp = $acpiTemp
                    CriticalTripPoint = $critTemp
                    Instance = $tz.InstanceName
                }
                $row.HardwareSensorsJson = ConvertTo-Json -InputObject $acpiData -Compress
                
                $tempAlert = ''
                if ($acpiTemp -ge 70.0) {
                    $tempAlert = 'HIGH_TEMP'
                    $alertMsg = "High ACPI thermal zone temperature: ${acpiTemp}C >= 70C"
                    Write-CMLog $Root 'telemetry' "CRITICAL: $alertMsg" 'WARNING'
                }
                
                try {
                    $tempRow = [ordered]@{
                        Utc = $now.UtcDateTime.ToString('o')
                        Local = $now.ToString('o')
                        NVMe_NAND_C = $null
                        NVMe_Controller_C = $null
                        HDD_C = $null
                        Status = 'ACPI_WMI'
                        Alert = $tempAlert
                    }
                    Write-CMCsv -Path (Join-Path $Root 'Evidence/Logs/temperatures.csv') -Columns @('Utc','Local','NVMe_NAND_C','NVMe_Controller_C','HDD_C','Status','Alert') -Row $tempRow
                } catch { }
            }
        } catch { }
    }
    $row.ErrorsJson=ConvertTo-Json -InputObject @($errors.ToArray()) -Compress
    $row.DurationMs=$timer.ElapsedMilliseconds
    return $row
}

$script:UdpSequence = 0L
function New-CMTelemetryPacket {
    # The last values a remote receiver holds if this machine dies: load, hardware sensors and hardware event counts.
    param([System.Collections.IDictionary]$Row, [string]$Root = '')
    $script:UdpSequence++
    $packet = [ordered]@{
        SchemaVersion = 3; Type = 'telemetry'; Seq = $script:UdpSequence; Utc = $Row.Utc; BootKey = $Row.BootKey
        CpuPct = $Row.CpuUsagePct; RamPct = $Row.RamUsedPct; RamAvailMB = $Row.RamAvailableMB
        DiskQLen = $Row.DiskQueueLength; IoLatencyMs = $Row.IoLatencyMs; TempStatus = $Row.TemperatureStatus
    }
    if ($Row.HardwareSensorsJson) {
        try {
            $sensors = $Row.HardwareSensorsJson | ConvertFrom-Json
            foreach ($map in @(@('CpuTempC','CpuTemp'),@('CpuPowerW','CpuPower'),@('Vcore','Vcore'),@('Plus12V','Plus12V'),@('Plus5V','Plus5V'),@('Plus33V','Plus33V'),@('DiskTempC','DiskTemp'),@('ThermalZoneC','ThermalZoneTemp'))) {
                $value = [string](Get-CMValue $sensors $map[1] '')
                $value = $value.TrimEnd('W')
                $number = 0.0
                if ($value -and [double]::TryParse($value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { $packet[$map[0]] = $number }
            }
            # First spinning fan; Control_Fan_N is the PWM duty in %, not a speed.
            foreach ($m in [regex]::Matches([string]$sensors.RawSummary, '_Fan_Fan_\d+:(\d+(?:\.\d+)?)')) {
                $rpm = [double]::Parse($m.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
                if ($rpm -gt 0) { $packet['FanRpm'] = [math]::Round($rpm); break }
            }
        } catch { }
    }
    if ($Root) {
        try {
            $counts = Read-CMJson (Join-Path $Root 'Evidence/State/hardware-event-counts.json')
            if ($counts -and $counts.BootKey -eq $Row.BootKey) { $packet['Whea'] = $counts.Whea; $packet['StorageErrors'] = $counts.Storage; $packet['ThermalEvents'] = $counts.Thermal }
        } catch { }
    }
    return $packet
}

function Send-CMUdpHeartbeat {
    param([hashtable]$Config, [System.Collections.IDictionary]$Row, [string]$Root = '')
    if (-not $Config -or -not (Get-CMValue $Config 'EnableUdpHeartbeat' $false)) { return }
    try { Send-CMUdpPacket -Config $Config -Payload (New-CMTelemetryPacket -Row $Row -Root $Root) } catch { }
}

function Write-CMTelemetry {
    param([string]$Root, [System.Collections.IDictionary]$Row, [hashtable]$Config = $null)
    Write-CMCsv -Path (Join-Path $Root 'Evidence/Logs/telemetry-v2.csv') -Columns $script:Columns -Row $Row
    if ($Config) { Send-CMUdpHeartbeat -Config $Config -Row $Row -Root $Root }
}

function Close-CMTelemetrySensor {
    if ($script:FastCounters) { foreach ($pc in $script:FastCounters.Values) { try { $pc.Dispose() } catch { } } }
    if ($script:DiskCounters) { foreach ($set in $script:DiskCounters.Values) { foreach ($pc in $set.Values) { try { $pc.Dispose() } catch { } } } }
    $script:FastCounters = $null; $script:DiskCounters = $null; $script:DiskInstanceKey = $null
    try {
        if (Get-Command 'Close-CrashMonitorVoltageSensor' -ErrorAction SilentlyContinue) {
            Close-CrashMonitorVoltageSensor
        }
    } catch { }
}

Export-ModuleMember -Function Get-CMTelemetryColumns, Initialize-CMTelemetry, Get-CMCounterMode, Get-CMStorageTemperatures, Get-CMSensorAlerts, New-CMTelemetryPacket, Get-CMTelemetry, Write-CMTelemetry, Send-CMUdpHeartbeat, Close-CMTelemetrySensor
