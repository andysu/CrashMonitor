#Requires -Version 5.1
$disk = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'"
$disks = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk | Where-Object { $_.Name -ne '_Total' }
$temp = Import-Csv 'C:\CrashMonitor\Evidence\Logs\temperatures.csv' -Delimiter ';' | Select-Object -Last 1

Write-Output "=== DISK ACTIVITY ==="
Write-Output "Total Read: $([math]::Round($disk.DiskReadBytesPersec / 1MB, 2)) MB/s | Total Write: $([math]::Round($disk.DiskWriteBytesPersec / 1MB, 2)) MB/s | Queue: $($disk.CurrentDiskQueueLength)"

foreach ($d in $disks) {
    Write-Output "Disk [$($d.Name)]: Read $([math]::Round($d.DiskReadBytesPersec / 1MB, 2)) MB/s | Write $([math]::Round($d.DiskWriteBytesPersec / 1MB, 2)) MB/s | Time: $($d.PercentDiskTime)%"
}

Write-Output "=== TEMPERATURES ==="
Write-Output "NVMe Ctrl: $($temp.NVMe_Controller_C)C | NVMe NAND: $($temp.NVMe_NAND_C)C | HDD: $($temp.HDD_C)C"
