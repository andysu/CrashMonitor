#Requires -Version 5.1
Import-Module (Join-Path $PSScriptRoot 'Common.psm1')
$script:Columns = @('SchemaVersion','Utc','Local','UtcOffsetMinutes','BootKey','CpuUsagePct','RamAvailableMB','RamUsedPct','CommittedMB','CommitLimitMB','PoolNonpagedMB','PoolPagedMB','PagesPerSec','DiskQueueLength','DiskReadBytesPerSec','DiskWriteBytesPerSec','TopMemoryProcesses','DiskCountersJson','TemperatureStatus','HardwareSensorsJson','ErrorsJson','DurationMs')

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
        $ioLatencyMs = $ioTimer.ElapsedMilliseconds
        if ($ioLatencyMs -ge 1000) {
            $errors.Add("High storage write latency: ${ioLatencyMs}ms")
            Write-CMLog $Root 'telemetry' "WARNING: High storage write latency on probe: ${ioLatencyMs}ms" 'WARNING'
        }
    } catch {
        $errors.Add("Storage probe failed: $_")
        Write-CMLog $Root 'telemetry' "ERROR: Storage probe write failure: $_" 'ERROR'
    }
    $row.TemperatureStatus='NOT_MEASURED'
    if ($Config.EnableHardwareSensors) {
        try {
            Import-Module (Join-Path $CodeRoot 'Modules/VoltageMonitor.psm1') -Force
            $sensors=Get-CrashMonitorVoltageSnapshot -ToolsDir (Join-Path $Root 'Tools/LibreHardwareMonitor')
            $row.HardwareSensorsJson=$sensors | ConvertTo-Json -Compress
            if ($sensors.CpuTemp -ne 'N/A' -or $sensors.DiskTemp -ne 'N/A' -or $sensors.RawSummary -match 'Temperature') {
                $row.TemperatureStatus = 'OK'
            } elseif ($sensors.RawSummary) {
                $row.TemperatureStatus = 'SENSORS_ACTIVE'
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
                            $errors.Add($alertMsg)
                            Write-CMLog $Root 'telemetry' "CRITICAL: $alertMsg" 'WARNING'
                        }
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
    $row.ErrorsJson=ConvertTo-Json -InputObject @($errors.ToArray()) -Compress
    $row.DurationMs=$timer.ElapsedMilliseconds
    return $row
}

function Write-CMTelemetry {
    param([string]$Root, [System.Collections.IDictionary]$Row)
    Write-CMCsv -Path (Join-Path $Root 'Evidence/Logs/telemetry-v2.csv') -Columns $script:Columns -Row $Row
}
Export-ModuleMember -Function Get-CMTelemetryColumns, Get-CMTelemetry, Write-CMTelemetry
