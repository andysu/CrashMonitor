# =====================================================================
# CrashMonitor Module: VoltageMonitor.psm1
# Hardware Voltage (+12V, +5V, +3.3V, Vcore, Vbat) & Power Telemetry
# Uses LibreHardwareMonitorLib
# =====================================================================

$script:LibLoaded = $false
$script:ReaderObj = $null

function Initialize-CrashMonitorVoltageSensor {
    [CmdletBinding()]
    param(
        [string]$ToolsDir = "C:\CrashMonitor\Tools\LibreHardwareMonitor"
    )

    if ($script:LibLoaded -and $script:ReaderObj) { return $true }
    if ("CrashMonitorVoltage.VoltageReader" -as [type]) {
        try {
            if (-not $script:ReaderObj) {
                $script:ReaderObj = New-Object CrashMonitorVoltage.VoltageReader
            }
            $script:LibLoaded = $true
            return $true
        } catch { }
    }

    $dllPath = Join-Path -Path $ToolsDir -ChildPath "LibreHardwareMonitorLib.dll"
    $hidPath = Join-Path -Path $ToolsDir -ChildPath "HidSharp.dll"

    if (-not (Test-Path -Path $dllPath)) {
        return $false
    }

    try {
        Add-Type -Path $hidPath -ErrorAction SilentlyContinue
        Add-Type -Path (Join-Path -Path $ToolsDir -ChildPath "Newtonsoft.Json.dll") -ErrorAction SilentlyContinue
        Add-Type -Path (Join-Path -Path $ToolsDir -ChildPath "System.CodeDom.dll") -ErrorAction SilentlyContinue
        Add-Type -Path $dllPath -ErrorAction SilentlyContinue

        $code = @"
using System;
using System.Collections.Generic;
using LibreHardwareMonitor.Hardware;

namespace CrashMonitorVoltage {
    public class UpdateVisitor : IVisitor {
        public void VisitComputer(IComputer computer) {
            computer.Traverse(this);
        }
        public void VisitHardware(IHardware hardware) {
            hardware.Update();
            foreach (IHardware subHardware in hardware.SubHardware) {
                subHardware.Accept(this);
            }
        }
        public void VisitSensor(ISensor sensor) { }
        public void VisitParameter(IParameter parameter) { }
    }

    public class VoltageReader {
        private Computer computer;
        private UpdateVisitor visitor;

        public VoltageReader() {
            computer = new Computer {
                IsCpuEnabled = true,
                IsMotherboardEnabled = true,
                IsMemoryEnabled = false,
                IsGpuEnabled = false,
                IsStorageEnabled = true,
                IsControllerEnabled = false,
                IsNetworkEnabled = false
            };
            computer.Open();
            visitor = new UpdateVisitor();
        }

        public Dictionary<string, double> ReadAllSensors() {
            Dictionary<string, double> dict = new Dictionary<string, double>();
            try {
                computer.Accept(visitor);
                Action<IHardware> collect = null;
                collect = delegate(IHardware hw) {
                    foreach (ISensor s in hw.Sensors) {
                        if (s.Value.HasValue) {
                            string key = string.Format("{0}_{1}_{2}", hw.Name, s.SensorType, s.Name)
                                .Replace(" ", "_").Replace("#", "").Replace("+", "Plus_").Replace("/", "_");
                            dict[key] = Math.Round((double)s.Value.Value, 3);
                        }
                    }
                    foreach (IHardware sub in hw.SubHardware) {
                        collect(sub);
                    }
                };
                foreach (IHardware hw in computer.Hardware) {
                    collect(hw);
                }
            } catch {}
            return dict;
        }

        public Dictionary<string, double> ReadVoltagesAndPower() {
            return ReadAllSensors();
        }

        public void Close() {
            try { computer.Close(); } catch {}
        }
    }
}
"@
        $refAssemblies = @(
            "System.Management.dll",
            $dllPath,
            $hidPath
        )
        Add-Type -TypeDefinition $code -ReferencedAssemblies $refAssemblies -ErrorAction Stop
        $script:ReaderObj = New-Object CrashMonitorVoltage.VoltageReader
        $script:LibLoaded = $true
        return $true
    } catch {
        return $false
    }
}

function Get-CrashMonitorVoltageSnapshot {
    [CmdletBinding()]
    param(
        [string]$ToolsDir = "C:\CrashMonitor\Tools\LibreHardwareMonitor"
    )

    if (-not $script:LibLoaded) {
        $initRes = Initialize-CrashMonitorVoltageSensor -ToolsDir $ToolsDir
        if (-not $initRes) {
            return @{ Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"); Status = "DISABLED" }
        }
    }

    $snapshot = [ordered]@{
        Timestamp  = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Vcore      = "N/A"
        Plus33V    = "N/A"
        AVCC       = "N/A"
        "3VSB"     = "N/A"
        VBat       = "N/A"
        VTT        = "N/A"
        CpuPower   = "N/A"
        CpuTemp    = "N/A"
        DiskTemp   = "N/A"
        RawSummary = ""
        Status     = "OK"
    }

    try {
        $dict = $script:ReaderObj.ReadAllSensors()
        if ($dict -and $dict.Count -gt 0) {
            $summaryParts = @()
            foreach ($k in $dict.Keys) {
                $val = $dict[$k]
                $summaryParts += "${k}:${val}"
                if ($k -like "*Vcore*")       { $snapshot.Vcore   = $val }
                if ($k -like "*Plus_3.3V*")   { $snapshot.Plus33V = $val }
                if ($k -like "*AVCC*")        { $snapshot.AVCC    = $val }
                if ($k -like "*3VSB*")        { $snapshot["3VSB"] = $val }
                if ($k -like "*VBat*")        { $snapshot.VBat    = $val }
                if ($k -like "*VTT*")         { $snapshot.VTT     = $val }
                if ($k -like "*Power*CPU_Package*") { $snapshot.CpuPower = "${val}W" }
                if ($snapshot.CpuTemp -eq "N/A" -and ($k -like "*Temperature*CPU_Package*" -or $k -like "*Temperature*Core_Max*" -or $k -like "*Temperature*CPU_Core*")) { $snapshot.CpuTemp = "${val}C" }
                if ($snapshot.DiskTemp -eq "N/A" -and $k -like "*Temperature*" -and ($k -like "*SSD*" -or $k -like "*ST1000*" -or $k -like "*Disk*")) { $snapshot.DiskTemp = "${val}C" }
            }
            $snapshot.RawSummary = ($summaryParts -join "|")
        }
    } catch {
        $snapshot.Status = "ERROR"
    }

    return $snapshot
}

function Write-CrashMonitorVoltageLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogDirectory,

        [Parameter(Mandatory = $true)]
        [hashtable]$Snapshot,

        [string]$Delimiter = ";"
    )

    try {
        if (-not (Test-Path -Path $LogDirectory)) {
            New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
        }

        $vFile = Join-Path -Path $LogDirectory -ChildPath "voltage.csv"

        if (-not (Test-Path -Path $vFile)) {
            $header = ($Snapshot.Keys -join $Delimiter)
            Set-Content -Path $vFile -Value $header -Encoding UTF8 -Force
        }

        $rowValues = foreach ($k in $Snapshot.Keys) { $Snapshot[$k] }
        $line = ($rowValues -join $Delimiter)
        Add-Content -Path $vFile -Value $line -Encoding UTF8
        return $true
    } catch {
        return $false
    }
}

function Close-CrashMonitorVoltageSensor {
    [CmdletBinding()]
    param()
    if ($script:ReaderObj) {
        try { $script:ReaderObj.Close() } catch { }
        $script:ReaderObj = $null
    }
    $script:LibLoaded = $false
}

Export-ModuleMember -Function Initialize-CrashMonitorVoltageSensor, Get-CrashMonitorVoltageSnapshot, Write-CrashMonitorVoltageLog, Close-CrashMonitorVoltageSensor
