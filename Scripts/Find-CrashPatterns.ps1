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

# Strict provider validation to prevent other providers reusing these event IDs
$validEvents = New-Object System.Collections.Generic.List[object]
foreach ($ev in $rawEvents) {
    $p = $ev.ProviderName
    if ($ev.Id -in @(12, 13) -and $p -eq 'Microsoft-Windows-Kernel-General') { $validEvents.Add($ev); continue }
    if ($ev.Id -eq 41 -and $p -eq 'Microsoft-Windows-Kernel-Power') { $validEvents.Add($ev); continue }
    if ($ev.Id -in @(6005, 6006, 6008) -and $p -eq 'EventLog') { $validEvents.Add($ev); continue }
    if ($ev.Id -eq 1074 -and ($p -eq 'User32' -or $p -eq 'USER32')) { $validEvents.Add($ev); continue }
}

$eventsChronological = @($validEvents | Sort-Object TimeCreated)
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
            TerminationType = 'Active / Running'
            TerminationReason = ''
            Initiator = 'N/A'
            DayOfWeek = $ev.TimeCreated.DayOfWeek.ToString()
            HourOfDay = $ev.TimeCreated.Hour
            Event41 = $false
            Event6008 = $false
            Event1074 = $false
            BugcheckCode = $null
            Incident = 'None'
        }
    } elseif ($ev.Id -eq 1074) {
        if ($currentBoot) {
            $currentBoot.Event1074 = $true
            $procName = 'Unknown'; $userName = 'Unknown'
            if ($ev.Properties.Count -ge 1) { $procName = [string]$ev.Properties[0].Value }
            if ($ev.Properties.Count -ge 7) { $userName = [string]$ev.Properties[6].Value }
            $currentBoot.Initiator = "$userName ($procName)"
            $currentBoot.TerminationType = 'RequestedShutdown'
            $currentBoot.TerminationReason = if ($ev.Properties.Count -ge 5) { [string]$ev.Properties[4].Value } else { 'User requested' }
        }
    } elseif ($ev.Id -eq 13) {
        if ($currentBoot) {
            $currentBoot.ShutdownTimeLocal = $ev.TimeCreated
            $currentBoot.ShutdownTimeUtc = $ev.TimeCreated.ToUniversalTime()
            if ($currentBoot.TerminationType -eq 'Active / Running') {
                $currentBoot.TerminationType = 'CleanShutdown'
            }
        }
    } elseif ($ev.Id -eq 41) {
        # Kernel-Power 41 records that the PREVIOUS session shut down abnormally
        $targetSession = if ($boots.Count -gt 0) { $boots[$boots.Count - 1] } else { $null }
        $bcCode = $null
        try {
            $xml = [xml]$ev.ToXml()
            $ns = New-Object Xml.XmlNamespaceManager($xml.NameTable)
            $ns.AddNamespace('e','http://schemas.microsoft.com/win/2004/08/events/event')
            $bcNode = $xml.SelectSingleNode("//e:Data[@Name='BugcheckCode']", $ns)
            if ($bcNode -and [long]$bcNode.InnerText -gt 0) { $bcCode = [long]$bcNode.InnerText }
        } catch { }

        if ($targetSession) {
            $targetSession.Event41 = $true
            $targetSession.BugcheckCode = $bcCode
            if ($bcCode) {
                $targetSession.TerminationType = "BSOD Bugcheck (0x{0:X})" -f $bcCode
            } else {
                $targetSession.TerminationType = 'UnexpectedReset (Kernel-Power 41)'
            }
        }
    } elseif ($ev.Id -eq 6008) {
        # EventLog 6008 records that the PREVIOUS shutdown was unexpected
        $targetSession = if ($boots.Count -gt 0) { $boots[$boots.Count - 1] } else { $null }
        if ($targetSession) {
            $targetSession.Event6008 = $true
            if ($targetSession.TerminationType -notlike '*BSOD*' -and $targetSession.TerminationType -notlike '*Kernel-Power*') {
                $targetSession.TerminationType = 'DirtyShutdown (EventLog 6008)'
            }
        }
    }
}
if ($currentBoot) { $boots.Add([pscustomobject]$currentBoot) }

# Calculate uptimes based on start and termination timestamps
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

# Correlate with CrashMonitor incident packets on disk
$incidentsDir = Join-Path $RootPath 'Evidence/Incidents'
if (Test-Path -LiteralPath $incidentsDir) {
    $incDirs = @(Get-ChildItem -LiteralPath $incidentsDir -Directory -ErrorAction SilentlyContinue)
    foreach ($incFolder in $incDirs) {
        $repJson = Join-Path $incFolder.FullName 'report.json'
        if (Test-Path -LiteralPath $repJson) {
            try {
                $data = Get-Content -LiteralPath $repJson -Raw -Encoding UTF8 | ConvertFrom-Json
                $incBootUtc = [datetime]::MinValue
                if ($data.Boot -and $data.Boot.BootUtc -and [datetime]::TryParse($data.Boot.BootUtc, [ref]$incBootUtc)) {
                    foreach ($b in $boots) {
                        if ([math]::Abs(($b.BootTimeUtc - $incBootUtc.ToUniversalTime()).TotalSeconds) -le 120) {
                            $b.Incident = "$($data.Classification.Type) [$($incFolder.Name.Substring(0, [math]::Min(8, $incFolder.Name.Length)))]"
                            break
                        }
                    }
                }
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
        IncidentPacket = $_.Incident
    }
})
$summaryRows | Format-Table -AutoSize

# Crash pattern distributions (specifically for crashes / unclean terminations)
$uncleanSessions = @($boots | Where-Object { $_.TerminationType -match 'UnexpectedReset|DirtyShutdown|BSOD' })
$cleanSessions = @($boots | Where-Object { $_.TerminationType -match 'RequestedShutdown|CleanShutdown' })

Write-Host "`nStatistical Distributions & Patterns:" -ForegroundColor Green

if ($uncleanSessions.Count -gt 0) {
    Write-Host "`nCrash Distribution by Day of Week (Unclean Only):" -ForegroundColor Red
    $uncleanSessions | Group-Object DayOfWeek | Select-Object Name, Count | Sort-Object Count -Descending | Format-Table -AutoSize

    Write-Host "Crash Distribution by Hour of Day (Unclean Only):" -ForegroundColor Red
    $uncleanSessions | Group-Object HourOfDay | Select-Object @{N='Hour';E={ "{0:D2}:00" -f [int]$_.Name }}, Count | Sort-Object Count -Descending | Format-Table -AutoSize
} else {
    Write-Host "`nNo unclean resets or crashes detected in the event log." -ForegroundColor Green
    Write-Host "All-sessions distribution by Day of Week:" -ForegroundColor Yellow
    $boots | Group-Object DayOfWeek | Select-Object Name, Count | Sort-Object Count -Descending | Format-Table -AutoSize

    Write-Host "All-sessions distribution by Hour of Day:" -ForegroundColor Yellow
    $boots | Group-Object HourOfDay | Select-Object @{N='Hour';E={ "{0:D2}:00" -f [int]$_.Name }}, Count | Sort-Object Count -Descending | Format-Table -AutoSize
}

Write-Host "Total boot sessions recorded: $($boots.Count)" -ForegroundColor White
Write-Host "Orderly clean shutdowns: $($cleanSessions.Count)" -ForegroundColor White
Write-Host "Unclean resets / BSODs: $($uncleanSessions.Count)" -ForegroundColor $(if ($uncleanSessions.Count -gt 0) { 'Red' } else { 'Green' })

if ($ExportReport) {
    $archiveDir = Join-Path $RootPath 'Evidence/Archive'
    [void][IO.Directory]::CreateDirectory($archiveDir)
    $outPath = Join-Path $archiveDir 'crash-patterns-summary.txt'
    $reportLines = @(
        "CrashMonitor - Reboot & Crash Pattern Summary",
        "Generated: " + ([DateTime]::UtcNow.ToString('s')),
        "Total Sessions: " + $boots.Count,
        "Clean Shutdowns: " + $cleanSessions.Count,
        "Unclean Resets: " + $uncleanSessions.Count,
        "",
        "Sessions Table:"
    )
    $reportLines += ($summaryRows | Out-String)
    [IO.File]::WriteAllLines($outPath, [string[]]$reportLines, (New-Object Text.UTF8Encoding($false)))
    Write-Host "`nSummary report saved to: $outPath" -ForegroundColor Cyan
}
