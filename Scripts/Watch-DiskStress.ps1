#Requires -Version 5.1
param([string]$RootPath = 'C:\CrashMonitor')

$disk = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'"
$disks = @(Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk | Where-Object { $_.Name -ne '_Total' })

$tempCsv = Join-Path $RootPath 'Evidence/Logs/temperatures.csv'
$temp = $null
if (Test-Path -LiteralPath $tempCsv) {
    try {
        $header = Get-Content -LiteralPath $tempCsv -TotalCount 1 -ErrorAction SilentlyContinue
        $tail = Get-Content -LiteralPath $tempCsv -Tail 1 -ErrorAction SilentlyContinue
        if ($header -and $tail) {
            $temp = ConvertFrom-Csv -InputObject @($header, $tail) -Delimiter ';' | Select-Object -First 1
        }
    } catch { }
}

Write-Output "=== DISK ACTIVITY ==="
Write-Output "Total Read: $([math]::Round($disk.DiskReadBytesPersec / 1MB, 2)) MB/s | Total Write: $([math]::Round($disk.DiskWriteBytesPersec / 1MB, 2)) MB/s | Queue: $($disk.CurrentDiskQueueLength)"

foreach ($d in $disks) {
    Write-Output "Disk [$($d.Name)]: Read $([math]::Round($d.DiskReadBytesPersec / 1MB, 2)) MB/s | Write $([math]::Round($d.DiskWriteBytesPersec / 1MB, 2)) MB/s | Time: $($d.PercentDiskTime)%"
}

Write-Output "=== TEMPERATURES ==="
$nvmeCtrl = if ($temp -and $temp.NVMe_Controller_C) { $temp.NVMe_Controller_C } else { 'N/A' }
$nvmeNand = if ($temp -and $temp.NVMe_NAND_C) { $temp.NVMe_NAND_C } else { 'N/A' }
$hddTemp  = if ($temp -and $temp.HDD_C) { $temp.HDD_C } else { 'N/A' }
Write-Output "NVMe Ctrl: ${nvmeCtrl}C | NVMe NAND: ${nvmeNand}C | HDD: ${hddTemp}C"
