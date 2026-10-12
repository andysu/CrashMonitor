#Requires -Version 5.1
<#
.SYNOPSIS
    Finds and analyzes reboot patterns, unexpected resets, and shutdown trends on Windows Server.
.DESCRIPTION
    Correlates Windows Event Logs (41, 6008, 1074, 12, 13) and CrashMonitor incident packets
    to compute time-of-day, day-of-week, uptime distributions, and pre-crash telemetry trends.
.PARAMETER RootPath
    Root path of CrashMonitor. Defaults to C:\CrashMonitor.
.PARAMETER MaxEvents
    Maximum number of events to inspect from the System event log.
.PARAMETER ExportReport
    Switch to export the report to Evidence/Archive/crash-patterns-summary.txt.
#>
[CmdletBinding()]
param(
    [string]$RootPath = 'C:\CrashMonitor',
    [int]$MaxEvents = 1000,
    [switch]$ExportReport
)

$ErrorActionPreference = 'Stop'
$RootPath = [IO.Path]::GetFullPath($RootPath).TrimEnd('\')

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " CrashMonitor: Historical Reboot & Crash Pattern Analyzer       " -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "Root: $RootPath"
Write-Host "Querying System log (Kernel-General, Kernel-Power, EventLog, User32)..."

$filter = @{
    LogName = 'System'
    Id = @(12, 13, 41, 1074, 6005, 6006, 6008)
}

$rawEvents = @()
try {
    $rawEvents = @(Get-WinEvent -FilterHashtable $filter -MaxEvents $MaxEvents -ErrorAction Stop)
} catch {
    if ($_.Exception.Message -notlike '*No events were found*') {
        Write-Warning "Event query notice: $_"
    }
}

if (-not $rawEvents.Count) {
    Write-Host "No reboot or shutdown events found in the current System event log." -ForegroundColor Yellow
    return
}

$eventsChronological = @($rawEvents | Sort-Object TimeCreated)
$boots = New-Object System.Collections.Generic.List[object]
$currentBoot = $null

foreach ($ev in $eventsChronological) {
    if ($ev.Id -eq 12) {
        if ($currentBoot) { $boots.Add([pscustomobject]$currentBoot) }
        $currentBoot = [ordered]@{
            BootTimeLocal = $ev.TimeCreated
            BootTimeUtc = $ev.TimeCreated.ToUniversalTime()
            ShutdownTimeLocal = $null
            ShutdownTimeUtc = $null
            Uptime = $null
            TerminationType = 'Active / Unknown'
            TerminationReason = ''
            Initiator = ''
            DayOfWeek = $ev.TimeCreated.DayOfWeek.ToString()
            HourOfDay = $ev.TimeCreated.Hour
            Event41 = $false
            Event6008 = $false
            Event1074 = $false
            BugcheckCode = $null
        }
    } elseif ($currentBoot) {
        if ($ev.Id -eq 1074) {
            $currentBoot.Event1074 = $true
            $procName = 'Unknown'
            $userName = 'Unknown'
            if ($ev.Properties.Count -ge 7) {
                $procName = [string]$ev.Properties[0].Value
                $userName = [string]$ev.Properties[6].Value
            }
            $currentBoot.Initiator = "$userName ($procName)"
            $currentBoot.TerminationType = 'RequestedShutdown'
            $currentBoot.TerminationReason = if ($ev.Properties.Count -ge 5) { [string]$ev.Properties[4].Value } else { 'User requested' }
        } elseif ($ev.Id -eq 13) {
            $currentBoot.ShutdownTimeLocal = $ev.TimeCreated
            $currentBoot.ShutdownTimeUtc = $ev.TimeCreated.ToUniversalTime()
            if ($currentBoot.TerminationType -eq 'Active / Unknown') {
                $currentBoot.TerminationType = 'CleanShutdown'
            }
        } elseif ($ev.Id -eq 41) {
            $currentBoot.Event41 = $true
            $currentBoot.TerminationType = 'UnexpectedReset (Kernel-Power 41)'
            $xml = [xml]$ev.ToXml()
            $ns = New-Object Xml.XmlNamespaceManager($xml.NameTable)
            $ns.AddNamespace('e','http://schemas.microsoft.com/win/2004/08/events/event')
            $bcNode = $xml.SelectSingleNode("//e:Data[@Name='BugcheckCode']", $ns)
            if ($bcNode -and [long]$bcNode.InnerText -gt 0) {
                $currentBoot.BugcheckCode = [long]$bcNode.InnerText
                $currentBoot.TerminationType = "BSOD Bugcheck (0x{0:X})" -f [long]$bcNode.InnerText
            }
        } elseif ($ev.Id -eq 6008) {
            $currentBoot.Event6008 = $true
            if ($currentBoot.TerminationType -notlike '*BSOD*') {
                $currentBoot.TerminationType = 'DirtyShutdown (EventLog 6008)'
            }
        }
    }
}
if ($currentBoot) { $boots.Add([pscustomobject]$currentBoot) }

for ($i = 0; $i -lt $boots.Count; $i++) {
    $b = $boots[$i]
    $endTime = $b.ShutdownTimeLocal
    if (-not $endTime -and ($i + 1) -lt $boots.Count) {
        $endTime = $boots[$i + 1].BootTimeLocal
    }
    if ($endTime) {
        $span = $endTime - $b.BootTimeLocal
        $b.Uptime = [math]::Round($span.TotalHours, 2)
    }
}

$incidentsDir = Join-Path $RootPath 'Evidence/Incidents'
$incidentReports = @{}
if (Test-Path -LiteralPath $incidentsDir) {
    foreach ($incFolder in (Get-ChildItem -LiteralPath $incidentsDir -Directory -ErrorAction SilentlyContinue)) {
        $repJson = Join-Path $incFolder.FullName 'report.json'
        if (Test-Path -LiteralPath $repJson) {
            try {
                $data = Get-Content -LiteralPath $repJson -Raw -Encoding UTF8 | ConvertFrom-Json
                $incidentReports[$data.Boot.BootKey] = $data
            } catch { }
        }
    }
}

Write-Host "`nBoot History Sessions Summary:" -ForegroundColor Green
$summaryRows = @($boots | ForEach-Object {
    [pscustomobject]@{
        BootTime = $_.BootTimeLocal.ToString('yyyy-MM-dd HH:mm:ss')
        Day = $_.DayOfWeek.Substring(0, 3)
        Hour = "{0:D2}:00" -f $_.HourOfDay
        UptimeHours = if ($null -ne $_.Uptime) { $_.Uptime } else { 'Live' }
        Classification = $_.TerminationType
        Initiator = if ($_.Initiator) { $_.Initiator } else { 'N/A' }
    }
})
$summaryRows | Format-Table -AutoSize

Write-Host "`nStatistical Distributions & Patterns:" -ForegroundColor Green

$dayDist = $boots | Group-Object DayOfWeek | Select-Object Name, Count | Sort-Object Count -Descending
Write-Host "`nDistribution by Day of Week:" -ForegroundColor Yellow
$dayDist | Format-Table -AutoSize

$hourDist = $boots | Group-Object HourOfDay | Select-Object @{N='Hour';E={ "{0:D2}:00" -f [int]$_.Name }}, Count | Sort-Object Count -Descending
Write-Host "Distribution by Hour of Day:" -ForegroundColor Yellow
$hourDist | Format-Table -AutoSize

$uncleanCount = @($boots | Where-Object { $_.TerminationType -match 'UnexpectedReset|DirtyShutdown|BSOD' }).Count
$cleanCount = @($boots | Where-Object { $_.TerminationType -match 'RequestedShutdown|CleanShutdown' }).Count

Write-Host "Total boot sessions recorded: $($boots.Count)" -ForegroundColor White
Write-Host "Orderly clean shutdowns: $cleanCount" -ForegroundColor White
Write-Host "Unclean resets / BSODs: $uncleanCount" -ForegroundColor $(if ($uncleanCount -gt 0) { 'Red' } else { 'Green' })
Write-Host "Total incident reports on disk: $($incidentReports.Count)" -ForegroundColor White

if ($ExportReport) {
    $archiveDir = Join-Path $RootPath 'Evidence/Archive'
    [void][IO.Directory]::CreateDirectory($archiveDir)
    $outPath = Join-Path $archiveDir 'crash-patterns-summary.txt'
    $reportLines = @(
        "CrashMonitor - Reboot & Crash Pattern Summary",
        "Generated: " + ([DateTime]::UtcNow.ToString('s')),
        "Total Sessions: " + $boots.Count,
        "Clean Shutdowns: " + $cleanCount,
        "Unclean Resets: " + $uncleanCount,
        "Incidents in Evidence: " + $incidentReports.Count,
        "",
        "Sessions Table:"
    )
    $reportLines += ($summaryRows | Out-String)
    [IO.File]::WriteAllLines($outPath, [string[]]$reportLines, (New-Object Text.UTF8Encoding($false)))
    Write-Host "`nSummary report saved to: $outPath" -ForegroundColor Cyan
}
