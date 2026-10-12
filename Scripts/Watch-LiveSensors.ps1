#Requires -Version 5.1
param(
    [int]$Samples = 1,
    [string]$RootPath = 'C:\CrashMonitor'
)

for ($i = 0; $i -lt $Samples; $i++) {
    $now = Get-Date
    $cpu = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
    $os = Get-CimInstance Win32_OperatingSystem
    $totalMem = [math]::Round($os.TotalVisibleMemorySize / 1024, 1)
    $freeMem = [math]::Round($os.FreePhysicalMemory / 1024, 1)
    $usedMemPct = [math]::Round(100 * (1 - $freeMem / $totalMem), 1)

    $tempCsv = Join-Path $RootPath 'Evidence/Logs/temperatures.csv'
    $tempRow = $null
    if (Test-Path -LiteralPath $tempCsv) {
        try {
            $h = Get-Content -LiteralPath $tempCsv -TotalCount 1 -ErrorAction SilentlyContinue
            $t = Get-Content -LiteralPath $tempCsv -Tail 1 -ErrorAction SilentlyContinue
            if ($h -and $t) {
                $tempRow = ConvertFrom-Csv -InputObject @($h, $t) -Delimiter ';' | Select-Object -First 1
            }
        } catch { }
    }

    $nvmeCtrl = if ($tempRow -and $tempRow.NVMe_Controller_C) { $tempRow.NVMe_Controller_C } else { 'N/A' }
    $nvmeNand = if ($tempRow -and $tempRow.NVMe_NAND_C) { $tempRow.NVMe_NAND_C } else { 'N/A' }
    $hdd = if ($tempRow -and $tempRow.HDD_C) { $tempRow.HDD_C } else { 'N/A' }

    $telemetryCsv = Join-Path $RootPath 'Evidence/Logs/telemetry-v2.csv'
    $vcore = 'N/A'; $cpuPower = 'N/A'; $cpuPkg = 'N/A'; $fanRpm = 'N/A'
    if (Test-Path -LiteralPath $telemetryCsv) {
        $lastRow = Get-Content -LiteralPath $telemetryCsv -Tail 1 -ErrorAction SilentlyContinue
        if ($lastRow) {
            $cols = $lastRow.Split(';')
            if ($cols.Count -ge 20) {
                try {
                    $rawJson = $cols[19].Trim('"').Replace('""', '"')
                    $hw = $rawJson | ConvertFrom-Json
                    if ($hw.Vcore) { $vcore = "$($hw.Vcore)V" }
                    if ($hw.CpuPower) { $cpuPower = "$($hw.CpuPower)" }
                    if ($hw.RawSummary -match 'Temperature_CPU_Package:(\d+(\.\d+)?)') { $cpuPkg = "$([math]::Round([double]$Matches[1]))C" }
                    elseif ($hw.CpuTemp -and $hw.Source -ne 'MSAcpi_ThermalZoneTemperature') { $cpuPkg = "$($hw.CpuTemp)C" }
                    elseif ($hw.ThermalZoneTemp) { $cpuPkg = "$($hw.ThermalZoneTemp)C (Zone)" }
                } catch { }
            }
        }
    }

    $occt = Get-Process -Name '*occt*' -ErrorAction SilentlyContinue | Select-Object -First 1
    $occtStatus = if ($occt) { "Running (PID: $($occt.Id), CPU: $([math]::Round($occt.CPU, 1))s, RAM: $([math]::Round($occt.WorkingSet64 / 1MB, 1))MB)" } else { "Not Running" }

    Write-Output "[$($now.ToString('HH:mm:ss'))] CPU: $($cpu.PercentProcessorTime)% (${cpuPkg}, ${cpuPower}, Vcore:${vcore}) | Fan: $fanRpm | RAM: $usedMemPct% ($freeMem MB free) | NVMe: Ctrl ${nvmeCtrl}C / NAND ${nvmeNand}C | HDD: ${hdd}C | OCCT: $occtStatus"

    if ($Samples -gt 1 -and $i -lt ($Samples - 1)) {
        Start-Sleep -Seconds 3
    }
}
