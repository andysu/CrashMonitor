#Requires -Version 5.1
param([string]$RootPath = 'C:\CrashMonitor')

Write-Output '=== POST-TEST MONITOR STATUS ==='
$statusScript = Join-Path $PSScriptRoot 'Get-MonitorStatus.ps1'
if (Test-Path -LiteralPath $statusScript) {
    & $statusScript -RootPath $RootPath
} else {
    Write-Warning "Get-MonitorStatus.ps1 not found at $statusScript"
}

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
$tempCsv = Join-Path $RootPath 'Evidence/Logs/temperatures.csv'
if (Test-Path -LiteralPath $tempCsv) {
    $header = Get-Content -LiteralPath $tempCsv -TotalCount 1
    $tail = @(Get-Content -LiteralPath $tempCsv -Tail 3)
    if ($tail.Count) {
        ConvertFrom-Csv -InputObject (@($header) + $tail) -Delimiter ';' | Format-Table
    }
} else {
    Write-Output "No temperatures.csv found at $tempCsv"
}
