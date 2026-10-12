#Requires -Version 5.1
$os = Get-CimInstance Win32_OperatingSystem
$bootStr = $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss')
$occtProcs = @(Get-Process -Name '*occt*' -ErrorAction SilentlyContinue)
$tempRow = if (Test-Path 'C:\CrashMonitor\Evidence\Logs\temperatures.csv') {
    Import-Csv 'C:\CrashMonitor\Evidence\Logs\temperatures.csv' -Delimiter ';' | Select-Object -Last 1
} else { $null }

[pscustomobject]@{
    ServerBoot = $bootStr
    OcctCount = $occtProcs.Count
    OcctPids = ($occtProcs | ForEach-Object { "$($_.Name):$($_.Id)" }) -join ', '
    NVMe_Ctrl_C = if ($tempRow) { $tempRow.NVMe_Controller_C } else { 'N/A' }
    NVMe_NAND_C = if ($tempRow) { $tempRow.NVMe_NAND_C } else { 'N/A' }
    HDD_C = if ($tempRow) { $tempRow.HDD_C } else { 'N/A' }
} | Format-List
