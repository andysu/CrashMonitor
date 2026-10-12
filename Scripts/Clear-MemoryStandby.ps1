# =====================================================================
# CrashMonitor Script: Clear-MemoryStandby.ps1
# Clears Windows Standby Memory Cache using RAMMap
# =====================================================================

param(
    [string]$RootPath = "C:\CrashMonitor",
    [string]$LogFile = ""
)

if (-not $LogFile) {
    $LogFile = Join-Path $RootPath "Evidence/Logs/rammap_cleanup.log"
}

try {
    # Ensure EULA is accepted in registry
    $regPath = "HKCU:\Software\Sysinternals\RAMMap"
    if (-not (Test-Path $regPath)) {
        New-Item -Path "HKCU:\Software\Sysinternals" -Name "RAMMap" -Force | Out-Null
    }
    Set-ItemProperty -Path $regPath -Name "EulaAccepted" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue

    # Execute RAMMap to clear StandbyList
    $ramMapPath = Join-Path $RootPath "Tools/RAMMap.exe"
    if ([Environment]::Is64BitOperatingSystem -and (Test-Path (Join-Path $RootPath "Tools/RAMMap64.exe"))) {
        $ramMapPath = Join-Path $RootPath "Tools/RAMMap64.exe"
    }
    if (Test-Path $ramMapPath) {
        $p = Start-Process -FilePath $ramMapPath -ArgumentList "-AcceptEula", "-Empty", "StandbyList" -PassThru -NoNewWindow
        try {
            [void]$p.WaitForExit(10000)
        } finally {
            $p.Dispose()
        }
        
        $logDir = Split-Path $LogFile -Parent
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Standby memory cache cleared successfully." -Encoding UTF8
    } else {
        Write-Error "RAMMap executable not found in $(Join-Path $RootPath 'Tools')"
    }
}
catch {
    Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Error clearing Standby cache: $_" -Encoding UTF8
}
