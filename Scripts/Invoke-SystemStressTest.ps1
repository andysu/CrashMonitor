#Requires -Version 5.1
[CmdletBinding()]
param(
    [int]$DurationMinutes = 60,
    [int]$CpuThreads = 6,
    [int]$RamTargetGB = 20,
    [double]$MaxSafeNvmeTempC = 75.0,
    [double]$MaxSafeCpuTempC = 90.0,
    [string]$RootPath = 'C:\CrashMonitor'
)

$ErrorActionPreference = 'Stop'
$stopFile = Join-Path $RootPath 'Evidence/State/stop-stress.txt'
$logFile = Join-Path $RootPath 'Evidence/Logs/stress-test.log'
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $logFile))
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $stopFile))
if (Test-Path -LiteralPath $stopFile) { Remove-Item -LiteralPath $stopFile -Force }

function Write-StressLog {
    param([string]$Text)
    $stamp = [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
    $msg = "[$stamp] $Text"
    Write-Output $msg
    Add-Content -LiteralPath $logFile -Value $msg -Encoding UTF8
}

Write-StressLog "=== Starting 1-Hour Stress Test (CPU $CpuThreads cores, RAM ${RamTargetGB}GB, Max NVMe Temp ${MaxSafeNvmeTempC}C) ==="
Write-StressLog "To stop manually at any time: create file $stopFile"

# 1. Allocate RAM buffer
Write-StressLog "Allocating ${RamTargetGB} GB RAM buffers for memory bus stress..."
$ramBlocks = [System.Collections.Generic.List[byte[]]]::new()
try {
    for ($i = 1; $i -le $RamTargetGB; $i++) {
        $block = New-Object byte[] (1024 * 1024 * 1024)
        for ($j = 0; $j -lt $block.Length; $j += 4096) { $block[$j] = [byte]($j % 255) }
        $ramBlocks.Add($block)
        Write-StressLog "Allocated block $i / ${RamTargetGB} GB"
    }
} catch {
    Write-StressLog "RAM allocation capped: $_"
}

# 2. Setup CPU stress worker runspaces
Write-StressLog "Spawning $CpuThreads parallel CPU stress runspaces..."
$runspacePool = [runspacefactory]::CreateRunspacePool(1, $CpuThreads)
$runspacePool.Open()
$sharedState = [hashtable]::Synchronized(@{ Stop = $false })

$cpuWork = {
    param($state)
    $sha = [System.Security.Cryptography.SHA512]::Create()
    $buf = [byte[]]::new(65536)
    [System.Random]::new().NextBytes($buf)
    while (-not $state.Stop) {
        $buf = $sha.ComputeHash($buf)
    }
    $sha.Dispose()
}

$tasks = [System.Collections.Generic.List[object]]::new()
for ($t = 0; $t -lt $CpuThreads; $t++) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $runspacePool
    [void]$ps.AddScript($cpuWork).AddArgument($sharedState)
    $handle = $ps.BeginInvoke()
    $tasks.Add([pscustomobject]@{ PowerShell = $ps; Handle = $handle })
}

# 3. Main supervision loop
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$targetMs = [long]$DurationMinutes * 60 * 1000
$aborted = $false
$abortReason = ''

try {
    while ($stopwatch.ElapsedMilliseconds -lt $targetMs) {
        if (Test-Path -LiteralPath $stopFile) {
            Write-StressLog "Manual stop signal detected ($stopFile). Stopping test."
            break
        }

        # Memory churn: touch pages to generate memory bus activity
        if ($ramBlocks.Count -gt 0) {
            $blkIdx = [System.Random]::new().Next(0, $ramBlocks.Count)
            $blk = $ramBlocks[$blkIdx]
            for ($k = 0; $k -lt [math]::Min($blk.Length, 10485760); $k += 4096) {
                $blk[$k] = [byte](($blk[$k] + 1) % 255)
            }
        }

        # Check temperatures from CrashMonitor
        $nvmeCtrl = $null
        $nvmeNand = $null
        $hddTemp = $null
        $cpuTemp = $null
        try {
            $tempCsv = Join-Path $RootPath 'Evidence/Logs/temperatures.csv'
            if (Test-Path -LiteralPath $tempCsv) {
                $h = Get-Content -LiteralPath $tempCsv -TotalCount 1 -ErrorAction SilentlyContinue
                $t = Get-Content -LiteralPath $tempCsv -Tail 1 -ErrorAction SilentlyContinue
                if ($h -and $t) {
                    $lastRow = ConvertFrom-Csv -InputObject @($h, $t) -Delimiter ';' | Select-Object -First 1
                    if ($lastRow) {
                        if ($lastRow.NVMe_Controller_C) { $nvmeCtrl = [double]$lastRow.NVMe_Controller_C }
                        if ($lastRow.NVMe_NAND_C) { $nvmeNand = [double]$lastRow.NVMe_NAND_C }
                        if ($lastRow.HDD_C) { $hddTemp = [double]$lastRow.HDD_C }
                    }
                }
            }
            $telemCsv = Join-Path $RootPath 'Evidence/Logs/telemetry-v2.csv'
            $tzTemp = $null
            if (Test-Path -LiteralPath $telemCsv) {
                $lastTelem = Get-Content -LiteralPath $telemCsv -Tail 1 -ErrorAction SilentlyContinue
                if ($lastTelem) {
                    $cols = $lastTelem.Split(';')
                    if ($cols.Count -ge 20) {
                        $rawJson = $cols[19].Trim('"').Replace('""', '"')
                        $hw = $rawJson | ConvertFrom-Json
                        if ($hw.RawSummary -match 'Temperature_CPU_Package:(\d+(\.\d+)?)') {
                            $cpuTemp = [double]$Matches[1]
                        } elseif ($hw.CpuTemp -and $hw.Source -ne 'MSAcpi_ThermalZoneTemperature') {
                            $cpuTemp = [double]($hw.CpuTemp -replace '[^\d.]', '')
                        }
                        if ($hw.ThermalZoneTemp) { $tzTemp = [double]$hw.ThermalZoneTemp }
                    }
                }
            }
        } catch { }

        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $freeRamMB = if ($os) { [math]::Round($os.FreePhysicalMemory / 1024, 1) } else { $null }

        $elapsed = $stopwatch.Elapsed
        $elapsedStr = "{0:D2}:{1:D2}:{2:D2}" -f $elapsed.Hours, $elapsed.Minutes, $elapsed.Seconds

        $cpuStr = if ($null -ne $cpuTemp) { "${cpuTemp}C" } elseif ($null -ne $tzTemp) { "ACPI-Zone:${tzTemp}C" } else { "N/A" }
        Write-StressLog "[$elapsedStr / ${DurationMinutes}:00:00] CPU: $cpuStr | NVMe Ctrl: ${nvmeCtrl}C | NVMe NAND: ${nvmeNand}C | HDD: ${hddTemp}C | Free RAM: ${freeRamMB} MB"

        # Safety tripwire: abort if NVMe or CPU temperature reaches dangerous threshold
        if ($null -ne $nvmeCtrl -and $nvmeCtrl -ge $MaxSafeNvmeTempC) {
            $aborted = $true
            $abortReason = "EMERGENCY THERMAL TRIPWIRE: NVMe Controller reached ${nvmeCtrl}C (threshold: ${MaxSafeNvmeTempC}C). Aborting to prevent SSD failure!"
            Write-StressLog $abortReason
            break
        }
        if ($null -ne $cpuTemp -and $cpuTemp -ge $MaxSafeCpuTempC) {
            $aborted = $true
            $abortReason = "EMERGENCY THERMAL TRIPWIRE: CPU reached ${cpuTemp}C (threshold: ${MaxSafeCpuTempC}C). Aborting to prevent CPU thermal throttling/damage!"
            Write-StressLog $abortReason
            break
        }

        Start-Sleep -Seconds 5
    }
} finally {
    Write-StressLog "Stopping CPU workers..."
    $sharedState.Stop = $true
    foreach ($task in $tasks) {
        try {
            [void]$task.PowerShell.EndInvoke($task.Handle)
            $task.PowerShell.Dispose()
        } catch { }
    }
    $runspacePool.Dispose()

    Write-StressLog "Releasing RAM buffers..."
    $ramBlocks.Clear()
    $ramBlocks = $null
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()

    $finalElapsed = $stopwatch.Elapsed
    $finalStr = "{0:D2}:{1:D2}:{2:D2}" -f $finalElapsed.Hours, $finalElapsed.Minutes, $finalElapsed.Seconds
    if ($aborted) {
        Write-StressLog "=== TEST ABORTED at $($finalStr): $abortReason ==="
    } else {
        Write-StressLog "=== TEST COMPLETED SUCCESSFULLY in $($finalStr) ==="
    }
}
