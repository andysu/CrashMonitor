#Requires -Version 5.1
param([string]$RootPath = 'C:\CrashMonitor')

$os = Get-CimInstance Win32_OperatingSystem
$bootStr = $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss')
$occtProcs = @(Get-Process -Name '*occt*' -ErrorAction SilentlyContinue)

$tempCsv = Join-Path $RootPath 'Evidence/Logs/temperatures.csv'
$tempRow = $null
if (Test-Path -LiteralPath $tempCsv) {
    try {
        $lines = @(Get-Content -LiteralPath $tempCsv -Tail 2 -ErrorAction SilentlyContinue)
        if ($lines.Count -ge 2) {
            $header = (Get-Content -LiteralPath $tempCsv -TotalCount 1 -ErrorAction SilentlyContinue)
            $tempRow = ConvertFrom-Csv -InputObject @($header, $lines[-1]) -Delimiter ';' | Select-Object -First 1
        }
    } catch { }
}

[pscustomobject]@{
    ServerBoot  = $bootStr
    OcctCount   = $occtProcs.Count
    OcctPids    = ($occtProcs | ForEach-Object { "$($_.Name):$($_.Id)" }) -join ', '
    NVMe_Ctrl_C = if ($tempRow -and $tempRow.NVMe_Controller_C) { $tempRow.NVMe_Controller_C } else { 'N/A' }
    NVMe_NAND_C = if ($tempRow -and $tempRow.NVMe_NAND_C) { $tempRow.NVMe_NAND_C } else { 'N/A' }
    HDD_C       = if ($tempRow -and $tempRow.HDD_C) { $tempRow.HDD_C } else { 'N/A' }
    Status      = if ($tempRow -and $tempRow.Status) { $tempRow.Status } else { 'N/A' }
} | Format-List
