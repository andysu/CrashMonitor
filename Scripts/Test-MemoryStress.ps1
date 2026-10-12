# =====================================================================
# CrashMonitor Script: Test-MemoryStress.ps1
# Extreme RAM stress test script targeting ~0 MB free RAM
# =====================================================================

param(
    [int]$HoldSeconds = 20
)

Write-Host "=== CrashMonitor Extreme Memory Stress Test (Targeting 0 MB free RAM) ==="
$blocks = [System.Collections.Generic.List[byte[]]]::new()

try {
    $allocatedGB = 0
    # Step 1: Allocate 1 GB blocks while free RAM > 1 GB
    while ($true) {
        $os = Get-CimInstance Win32_OperatingSystem
        $freeMB = [math]::Round($os.FreePhysicalMemory / 1KB, 2)
        if ($freeMB -lt 1024) { break }
        
        try {
            $block = New-Object byte[] (1024 * 1024 * 1024)
            for ($j = 0; $j -lt $block.Length; $j += 4096) { $block[$j] = 1 }
            $blocks.Add($block)
            $allocatedGB++
            Write-Host "Allocated: $allocatedGB GB | Free RAM remaining: $freeMB MB"
        }
        catch {
            Write-Warning "Allocation capped at 1GB block level: $_"
            break
        }
        Start-Sleep -Milliseconds 150
    }

    # Step 2: Allocate smaller blocks to push free RAM down to ~0 MB
    Write-Host "`nPushing free RAM down towards 0 MB with fine allocation..."
    $fineStep = 0
    while ($fineStep -lt 50) {
        $fineStep++
        $os = Get-CimInstance Win32_OperatingSystem
        $freeMB = [math]::Round($os.FreePhysicalMemory / 1KB, 2)
        Write-Host "Fine step $fineStep | Free RAM remaining: $freeMB MB"
        if ($freeMB -lt 30) {
            Write-Host "RAM fully exhausted! Free RAM: $freeMB MB."
            break
        }
        try {
            $targetBytes = [math]::Min(($freeMB * 1024 * 1024 * 0.7), (256 * 1024 * 1024))
            if ($targetBytes -lt (5 * 1024 * 1024)) { break }
            $block = New-Object byte[] ([int]$targetBytes)
            for ($j = 0; $j -lt $block.Length; $j += 4096) { $block[$j] = 1 }
            $blocks.Add($block)
        }
        catch {
            Write-Warning "Memory limit reached: $_"
            break
        }
        Start-Sleep -Milliseconds 100
    }

    $finalOS = Get-CimInstance Win32_OperatingSystem
    $finalFreeMB = [math]::Round($finalOS.FreePhysicalMemory / 1KB, 2)
    Write-Host "`nPeak extreme memory allocation achieved! Final Free RAM: $finalFreeMB MB."
    Write-Host "Holding peak allocation for $HoldSeconds seconds..."
    Start-Sleep -Seconds $HoldSeconds
}
catch {
    Write-Warning "Stress test exception: $_"
}
finally {
    Write-Host "`nReleasing all allocated RAM..."
    $blocks.Clear()
    $blocks = $null
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    Write-Host "Memory released cleanly."
}
