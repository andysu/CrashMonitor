#Requires -Version 5.1
Write-Output '=== POST-TEST MONITOR STATUS ==='
& 'C:\CrashMonitor\Scripts\Get-MonitorStatus.ps1' -RootPath 'C:\CrashMonitor'

Write-Output '=== CURRENT CPU & RAM ==='
$cpu = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
$os = Get-CimInstance Win32_OperatingSystem
$freeMB = [math]::Round($os.FreePhysicalMemory / 1024, 1)
Write-Output "CPU: $($cpu.PercentProcessorTime)% | Free RAM: ${freeMB} MB"

Write-Output '=== WHEA CHECK (ENTIRE OCCT RUN) ==='
$since = (Get-Date).AddHours(-2)
$whea = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=$since } -ErrorAction SilentlyContinue
if ($whea) {
    Write-Output "WHEA Events found: $($whea.Count)"
    $whea | Select-Object Id, TimeCreated, Message | Format-Table
} else {
    Write-Output 'WHEA Hardware Errors: 0 (No hardware machine check errors)'
}

Write-Output '=== LATEST 3 TEMPERATURE ROWS ==='
Import-Csv 'C:\CrashMonitor\Evidence\Logs\temperatures.csv' -Delimiter ';' | Select-Object -Last 3 | Format-Table
