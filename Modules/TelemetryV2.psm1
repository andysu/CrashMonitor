#Requires -Version 5.1
Import-Module (Join-Path $PSScriptRoot 'Common.psm1')
$script:Columns = @('SchemaVersion','Utc','Local','UtcOffsetMinutes','BootKey','CpuUsagePct','RamAvailableMB','RamUsedPct','CommittedMB','CommitLimitMB','PoolNonpagedMB','PoolPagedMB','PagesPerSec','DiskQueueLength','DiskReadBytesPerSec','DiskWriteBytesPerSec','TopMemoryProcesses','DiskCountersJson','TemperatureStatus','HardwareSensorsJson','ErrorsJson','IoLatencyMs','DurationMs')

function Get-CMTelemetryColumns { return $script:Columns }

function Get-CMTelemetry {
    param([string]$Root, [string]$CodeRoot, [hashtable]$Config, $Boot)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $now = [DateTimeOffset]::Now
    $row = [ordered]@{ SchemaVersion=2; Utc=$now.UtcDateTime.ToString('o'); Local=$now.ToString('o'); UtcOffsetMinutes=$now.Offset.TotalMinutes; BootKey=$Boot.BootKey }
    foreach ($name in $script:Columns) { if (-not $row.Contains($name)) { $row[$name]=$null } }
    $errors = New-Object Collections.Generic.List[string]
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

            # High temperature threshold detection (warning at >= 70C)
            if ($sensors.RawSummary) {
                foreach ($part in ($sensors.RawSummary -split '\|')) {
                    if ($part -match 'Temperature.*:(\d+(\.\d+)?)') {
                        $deg = [double]$Matches[1]
                        if ($deg -ge 70.0) {
                            $alertMsg = "High temperature warning: $part (${deg}C >= 70C)"
                            Write-CMLog $Root 'telemetry' "CRITICAL: $alertMsg" 'WARNING'
                        }
                    }
                }
            }

            # Voltage rail threshold detection (ATX specification tolerances +/- 5%)
            if ($sensors.RawSummary) {
                if ($sensors.Plus12V -ne 'N/A' -and [double]$sensors.Plus12V -gt 0) {
                    $v12 = [double]$sensors.Plus12V
                    if ($v12 -lt 11.40 -or $v12 -gt 12.60) {
                        Write-CMLog $Root 'telemetry' "WARNING: +12V rail out of ATX spec: ${v12}V (spec: 11.40V - 12.60V)" 'WARNING'
                    }
                }
                if ($sensors.Plus5V -ne 'N/A' -and [double]$sensors.Plus5V -gt 0) {
                    $v5 = [double]$sensors.Plus5V
                    if ($v5 -lt 4.75 -or $v5 -gt 5.25) {
                        Write-CMLog $Root 'telemetry' "WARNING: +5V rail out of ATX spec: ${v5}V (spec: 4.75V - 5.25V)" 'WARNING'
                    }
                }
                if ($sensors.Plus33V -ne 'N/A' -and [double]$sensors.Plus33V -gt 0) {
                    $v33 = [double]$sensors.Plus33V
                    if ($v33 -lt 3.135 -or $v33 -gt 3.465) {
                        Write-CMLog $Root 'telemetry' "WARNING: +3.3V rail out of ATX spec: ${v33}V (spec: 3.135V - 3.465V)" 'WARNING'
                    }
                }
            }

            # Dedicated real-time temperatures.csv logger
            try {
                $nvmeNand = $null; $nvmeCtrl = $null; $hddTemp = $null; $tempAlert = ''
                if ($sensors.RawSummary) {
                    foreach ($part in ($sensors.RawSummary -split '\|')) {
                        if ($part -match 'Samsung.*Temperature_Temperature_1:(\d+(\.\d+)?)' -or $part -match 'Samsung.*Temperature_Temperature:(\d+(\.\d+)?)') {
                            if ($null -eq $nvmeNand) { $nvmeNand = [double]$Matches[1] }
                        }
                        if ($part -match 'Samsung.*Temperature_Temperature_2:(\d+(\.\d+)?)') {
                            $nvmeCtrl = [double]$Matches[1]
                        }
                        if ($part -match 'ST1000.*Temperature:(\d+(\.\d+)?)') {
                            $hddTemp = [double]$Matches[1]
                        }
                    }
                }
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

function Send-CMUdpHeartbeat {
    param([hashtable]$Config, [System.Collections.IDictionary]$Row)
    if (-not $Config -or -not $Config.ContainsKey('EnableUdpHeartbeat') -or -not $Config.EnableUdpHeartbeat -or -not $Config.UdpHeartbeatHost) { return }
    try {
        $port = 514
        if ($Config.ContainsKey('UdpHeartbeatPort') -and [int]$Config.UdpHeartbeatPort -gt 0) { $port = [int]$Config.UdpHeartbeatPort }
        $packet = [ordered]@{
            SchemaVersion = 2
            Utc = $Row.Utc
            BootKey = $Row.BootKey
            CpuPct = $Row.CpuUsagePct
            RamPct = $Row.RamUsedPct
            RamAvailMB = $Row.RamAvailableMB
            DiskQLen = $Row.DiskQueueLength
            IoLatencyMs = $Row.IoLatencyMs
            TempStatus = $Row.TemperatureStatus
        }
        $json = ConvertTo-Json -InputObject $packet -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $client = New-Object Net.Sockets.UdpClient
        try {
            [void]$client.Send($bytes, $bytes.Length, [string]$Config.UdpHeartbeatHost, $port)
        } finally {
            $client.Dispose()
        }
    } catch { }
}

function Write-CMTelemetry {
    param([string]$Root, [System.Collections.IDictionary]$Row, [hashtable]$Config = $null)
    Write-CMCsv -Path (Join-Path $Root 'Evidence/Logs/telemetry-v2.csv') -Columns $script:Columns -Row $Row
    if ($Config) { Send-CMUdpHeartbeat -Config $Config -Row $Row }
}

function Close-CMTelemetrySensor {
    try {
        if (Get-Command 'Close-CrashMonitorVoltageSensor' -ErrorAction SilentlyContinue) {
            Close-CrashMonitorVoltageSensor
        }
    } catch { }
}

Export-ModuleMember -Function Get-CMTelemetryColumns, Get-CMTelemetry, Write-CMTelemetry, Send-CMUdpHeartbeat, Close-CMTelemetrySensor
