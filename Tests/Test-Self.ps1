#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'Modules/Common.psm1')
Import-Module (Join-Path $root 'Modules/EventCapture.psm1')
Import-Module (Join-Path $root 'Modules/TelemetryV2.psm1')
$script:passed=0
function Assert-CM {
    param([bool]$Condition,[string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++; Write-Output "PASS: $Name"
}
function New-Fixture {
    param([int]$Id,[string]$Provider,[string]$Utc,[string]$Extra='', [int]$Record=123)
    return @"
<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><System><Provider Name="$Provider"/><EventID>$Id</EventID><Level>1</Level><TimeCreated SystemTime="$Utc"/><EventRecordID>$Record</EventRecordID><Channel>System</Channel><Computer>fixture</Computer></System><EventData>$Extra</EventData></Event>
"@
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('crashmonitor-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try {
    $parseFiles=@('CrashMonitor.ps1','Worker.ps1','Install.ps1','NightlyLogCleanup.ps1','RegisterNightlyTask.ps1','Modules/Common.psm1','Modules/EventCapture.psm1','Modules/TelemetryV2.psm1','Modules/Diagnostics.psm1','Modules/VoltageMonitor.psm1','Scripts/Export-Diagnostics.ps1','Scripts/Get-MonitorStatus.ps1','Scripts/Stop-Monitor.ps1','Tests/Test-Self.ps1','Tests/Test-Windows.ps1')
    foreach ($relative in $parseFiles) {
        $tokens=$null;$errors=$null
        [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $root $relative),[ref]$tokens,[ref]$errors)
        Assert-CM ($errors.Count -eq 0) "PowerShell parse: $relative ($($errors -join '; '))"
    }
    $xml=New-Fixture 41 'Microsoft-Windows-Kernel-Power' '2026-10-07T12:00:03Z' '<Data Name="BugcheckCode">292</Data><Data Name="PowerButtonTimestamp">0</Data>'
    $event=ConvertFrom-CMEventXml $xml
    Assert-CM ($event.EventId -eq 41 -and $event.RecordId -eq 123 -and $event.Data.BugcheckCode -eq '292') 'XML extracts provider, event ID, record ID and BugcheckCode'
    $boot=[datetime]::Parse('2026-10-07T12:00:00Z').ToUniversalTime()
    Assert-CM ((Get-CMRestartClassification @($event) $boot).Type -eq 'Bugcheck') 'Current boot with nonzero BugcheckCode is a stop error'
    $zero=ConvertFrom-CMEventXml (New-Fixture 41 'Microsoft-Windows-Kernel-Power' '2026-10-07T12:00:03Z' '<Data Name="BugcheckCode">0</Data>')
    Assert-CM ((Get-CMRestartClassification @($zero) $boot).Type -eq 'UnexpectedReset') 'Zero BugcheckCode does not assert PSU failure'
    $old=ConvertFrom-CMEventXml (New-Fixture 41 'Microsoft-Windows-Kernel-Power' '2026-10-06T12:00:03Z')
    Assert-CM ((Get-CMRestartClassification @($old) $boot).Type -eq 'Unknown') 'Previous-day Kernel-Power event is not attached to current boot'
    Assert-CM ((Get-CMRestartClassification @() $boot).Type -eq 'Unknown') 'Heartbeat gap alone is not a crash verdict'
    $request=ConvertFrom-CMEventXml (New-Fixture 1074 'User32' '2026-10-07T11:59:00Z')
    Assert-CM ((Get-CMRestartClassification @($request) $boot).Type -eq 'RequestedRestart') 'User32 restart request is recognized'
    Assert-CM ((Get-CMRestartClassification @($request) $boot $boot.AddMinutes(-10)).Type -eq 'RequestedRestart') 'Previous boot timestamp is handled as a nullable DateTime'
    $lateRequest=ConvertFrom-CMEventXml (New-Fixture 1074 'User32' '2026-10-07T10:00:00Z')
    Assert-CM ((Get-CMRestartClassification @($lateRequest) $boot).Type -eq 'Unknown') 'Old unrelated restart request does not classify a later boot'
    $bug=ConvertFrom-CMEventXml (New-Fixture 1001 'Microsoft-Windows-WER-SystemErrorReporting' '2026-10-07T12:00:10Z')
    Assert-CM ((Get-CMRestartClassification @($bug) $boot).Type -eq 'Bugcheck') 'WER stop-error event confirms bugcheck without Kernel-Power data'
    $wheaXml=New-Fixture 1 'Microsoft-Windows-WHEA-Logger' '2026-10-07T12:00:04Z' '<Data Name="RawData">435045520001</Data>' 124
    $whea=Save-CMEvent $temp $wheaXml 'Fatal hardware error'
    [void](Save-CMEvent $temp $wheaXml 'Fatal hardware error')
    $captured=@(Get-ChildItem (Join-Path $temp 'Evidence/Events') -Recurse -Filter '*.xml')
    Assert-CM ($captured.Count -eq 1 -and ([IO.File]::ReadAllText($captured[0].FullName)) -eq $wheaXml) 'Full WHEA XML is preserved and repeated capture is idempotent'
    Assert-CM ($whea.Data.RawData -eq '435045520001') 'WHEA RawData is preserved'
    Assert-CM (@(Get-Content (Join-Path $temp 'Evidence/Logs/events.jsonl')).Count -eq 1) 'Duplicate replay does not duplicate the event index'
    $checkpoint=Join-Path $temp 'cursor.json'
    Write-CMJson $checkpoint @{RecordId=42; AnchorUtc='2026-10-07T12:00:00Z'}
    Write-CMJson $checkpoint @{RecordId=43; AnchorUtc='2026-10-07T12:00:01Z'}
    Assert-CM ((Read-CMJson $checkpoint).RecordId -eq 43) 'Checkpoint survives serialization and atomic replacement'
    $query=Get-CMEventXPath 43 99 $boot $false 'System'
    Assert-CM ($query -match 'EventRecordID > 43' -and $query -match 'EventRecordID <= 99' -and $query -match 'WHEA') 'Incremental query is bounded and includes WHEA'
    $initial=Get-CMEventXPath 0 99 $boot $true 'System'
    Assert-CM ($initial -match 'TimeCreated' -and $initial -match '2026-10-07T12:00:00.000Z') 'First capture uses UTC backfill'
    $csv=Join-Path $temp 'roundtrip.csv'
    $row=@{Utc='2026-10-07T12:00:00Z'; Value=1.25; Message="quote `" semi; newline`nsecond line"; Missing=$null}
    $culture=[Threading.Thread]::CurrentThread.CurrentCulture
    try { [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('uk-UA'); Write-CMCsv $csv @('Utc','Value','Message','Missing') $row }
    finally { [Threading.Thread]::CurrentThread.CurrentCulture=$culture }
    $parsed=Import-Csv -LiteralPath $csv -Delimiter ';'
    Assert-CM ($parsed.Value -eq '1.25' -and $parsed.Message -eq $row.Message -and $parsed.Missing -eq '') 'CSV roundtrip handles invariant decimals, quotes, semicolons, newline and missing values'
    $rejected=$false;try { Write-CMCsv $csv @('Wrong') @{Wrong='x'} } catch { $rejected=$true }
    Assert-CM $rejected 'Schema mismatch is rejected without overwriting old data'
    $cols=@(Get-CMTelemetryColumns)
    Assert-CM ($cols.Count -eq 22 -and @($cols | Select-Object -Unique).Count -eq $cols.Count) 'Telemetry schema has fixed unique columns'
    $cfg=Get-CMConfig $temp $root
    Assert-CM (-not $cfg.EnableHardwareSensors -and $cfg.SchemaVersion -eq 2) 'Hardware driver probing is opt-in'
    # Mock only the OS data source; run the actual collector and CSV serializer.
    $oldCimFunction=Get-Item Function:global:Get-CimInstance -ErrorAction SilentlyContinue
    try {
        function global:Get-CimInstance {
            param([string]$ClassName,[string]$Filter,[int]$OperationTimeoutSec)
            switch ($ClassName) {
                'Win32_PerfFormattedData_PerfOS_Processor' { return [pscustomobject]@{PercentProcessorTime=37} }
                'Win32_OperatingSystem' { return [pscustomobject]@{FreePhysicalMemory=8388608;TotalVisibleMemorySize=33554432} }
                'Win32_PerfFormattedData_PerfOS_Memory' { return [pscustomobject]@{CommittedBytes=4294967296;CommitLimit=34359738368;PoolNonpagedBytes=134217728;PoolPagedBytes=268435456;PagesPersec=4} }
                'Win32_PerfFormattedData_PerfDisk_PhysicalDisk' { return [pscustomobject]@{Name='_Total';CurrentDiskQueueLength=2;DiskReadBytesPersec=1024;DiskWriteBytesPersec=2048;PercentDiskTime=3} }
                default { throw "Unexpected fixture class: $ClassName" }
            }
        }
        $metrics=Get-CMTelemetry $temp $root $cfg ([pscustomobject]@{BootKey='fixture'})
        Assert-CM ($metrics.CpuUsagePct -eq 37 -and $metrics.RamAvailableMB -eq 8192 -and $metrics.RamUsedPct -eq 75 -and $metrics.CommittedMB -eq 4096) 'Actual telemetry collector converts CIM memory units and CPU correctly'
        Assert-CM ($metrics.ErrorsJson -eq '[]' -and $metrics.TemperatureStatus -eq 'NOT_MEASURED' -and $metrics.DiskQueueLength -eq 2) 'Collector records unavailable temperature honestly and preserves disk queue'
        Write-CMTelemetry $temp $metrics
        $roundtrip=Import-Csv (Join-Path $temp 'Evidence/Logs/telemetry-v2.csv') -Delimiter ';'
        Assert-CM ($roundtrip.CpuUsagePct -eq '37' -and $roundtrip.RamUsedPct -eq '75' -and $roundtrip.BootKey -eq 'fixture') 'Actual telemetry collector roundtrips through the fixed CSV schema'
    } finally {
        Remove-Item Function:global:Get-CimInstance -ErrorAction SilentlyContinue
        if ($oldCimFunction) { Set-Item Function:global:Get-CimInstance $oldCimFunction.ScriptBlock }
    }
    $legacy=Join-Path $temp 'Logs';[void][IO.Directory]::CreateDirectory($legacy)
    [IO.File]::WriteAllText((Join-Path $legacy 'heartbeat.csv'),'legacy evidence')
    $cfg.MaxLogSizeMB=0.000001
    Invoke-CMRotation $temp $cfg
    Assert-CM (([IO.File]::ReadAllText((Join-Path $legacy 'heartbeat.csv'))) -eq 'legacy evidence') 'Rotation preserves all legacy evidence'
    Write-CMTelemetry $temp $metrics
    $afterRotation=Import-Csv (Join-Path $temp 'Evidence/Logs/telemetry-v2.csv') -Delimiter ';'
    Assert-CM ($afterRotation.RamAvailableMB -eq '8192') 'Rotation creates a fresh CSV with its complete header'
    # Exercise the incident builder with explicit OS/export fixtures, never Windows settings.
    Import-Module (Join-Path $root 'Modules/Diagnostics.psm1')
    $diagnostics=Get-Module Diagnostics
    & $diagnostics {
        $script:SavedInventoryFixture=${function:Get-CMInventory}
        $script:SavedExportFixture=${function:Export-CMEvtx}
        function script:Get-CMInventory { return @{Fixture=$true;Errors=@()} }
        function script:Export-CMEvtx { param($Directory,$SinceUtc); throw 'Fixture: EVTX unavailable on this platform' }
    }
    try {
        for ($i=0;$i -lt 350;$i++) { Write-CMTelemetry $temp $metrics }
        $fixtureBoot=[pscustomobject]@{BootKey='AAAAAAAAAAAAAAAAAAAAAAAA';BootUtc=$boot.ToString('o')}
        New-CMIncident -Root $temp -Config $cfg -Boot $fixtureBoot -Events @($event,$whea)
        $incident=Join-Path $temp 'Evidence/Incidents/AAAAAAAAAAAAAAAAAAAAAAAA'
        $report=Read-CMJson (Join-Path $incident 'report.json')
        Assert-CM ($report.Classification.Type -eq 'Bugcheck' -and $report.BootEvents.Count -eq 2) 'Actual incident builder preserves classification and event data'
        $csvTail=@(Import-Csv (Join-Path $incident 'telemetry-v2.csv') -Delimiter ';')
        Assert-CM ($csvTail.Count -eq 300 -and $csvTail[-1].RamAvailableMB -eq '8192') 'Incident CSV tail includes its header and 300 readable samples'
        $complete=Read-CMJson (Join-Path $incident 'complete.json')
        Assert-CM ($complete.ExportErrors.Count -eq 1) 'Failed EVTX export is explicitly recorded, not reported as successful'
        $before=(Get-FileHash (Join-Path $incident 'report.json')).Hash
        New-CMIncident -Root $temp -Config $cfg -Boot $fixtureBoot -Events @()
        Assert-CM ($before -eq (Get-FileHash (Join-Path $incident 'report.json')).Hash) 'Restarting a monitor in the same boot does not overwrite the incident'
    } finally {
        & $diagnostics {
            Set-Item Function:script:Get-CMInventory $script:SavedInventoryFixture
            Set-Item Function:script:Export-CMEvtx $script:SavedExportFixture
            Remove-Variable SavedInventoryFixture,SavedExportFixture -Scope Script
        }
    }
    Write-Output "Self-tests passed: $script:passed"
} finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
