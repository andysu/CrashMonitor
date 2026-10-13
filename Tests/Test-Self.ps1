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
    $scriptFiles=@(Get-ChildItem (Join-Path $root 'Scripts') -Filter '*.ps1' | ForEach-Object { "Scripts/$($_.Name)" })
    $parseFiles=@('CrashMonitor.ps1','Worker.ps1','Install.ps1','NightlyLogCleanup.ps1','RegisterNightlyTask.ps1','Modules/Common.psm1','Modules/EventCapture.psm1','Modules/TelemetryV2.psm1','Modules/Diagnostics.psm1','Modules/VoltageMonitor.psm1','Tests/Test-Self.ps1','Tests/Test-Windows.ps1') + $scriptFiles
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
    $pwrBtn=ConvertFrom-CMEventXml (New-Fixture 41 'Microsoft-Windows-Kernel-Power' '2026-10-07T12:00:03Z' '<Data Name="BugcheckCode">0</Data><Data Name="LongPowerButtonPressDetected">true</Data>')
    $btnClass=Get-CMRestartClassification @($pwrBtn) $boot
    Assert-CM ($btnClass.Type -eq 'UnexpectedReset' -and $btnClass.Explanation -match 'power button') 'Event 41 with power button press distinguishes power button from PSU drop'
    $sleepEv=ConvertFrom-CMEventXml (New-Fixture 41 'Microsoft-Windows-Kernel-Power' '2026-10-07T12:00:03Z' '<Data Name="BugcheckCode">0</Data><Data Name="SleepInProgress">1</Data>')
    $sleepClass=Get-CMRestartClassification @($sleepEv) $boot
    Assert-CM ($sleepClass.Type -eq 'UnexpectedReset' -and $sleepClass.Explanation -match 'sleep') 'Event 41 with SleepInProgress distinguishes sleep transition failure'
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
    Assert-CM ($cols.Count -eq 23 -and @($cols | Select-Object -Unique).Count -eq $cols.Count) 'Telemetry schema has fixed unique columns'
    $cfg=Get-CMConfig $temp $root
    Assert-CM (-not $cfg.EnableHardwareSensors -and $cfg.SchemaVersion -eq 2) 'Hardware driver probing is opt-in'
    Assert-CM ($cfg.SampleIntervalSeconds -eq 3 -and $cfg.EventPollSeconds -eq 3 -and $cfg.HeartbeatIntervalSeconds -eq 2) 'Fresh install samples telemetry and events every 3 s with a 2 s heartbeat'
    # Mock only the OS data source; run the actual collector and CSV serializer.
    $script:mockAcpiResult = $null
    $oldCimFunction=Get-Item Function:global:Get-CimInstance -ErrorAction SilentlyContinue
    try {
        function global:Get-CimInstance {
            param([string]$ClassName,[string]$Filter,[int]$OperationTimeoutSec,[string]$Namespace)
            switch ($ClassName) {
                'Win32_PerfFormattedData_PerfOS_Processor' { $script:mockCpuTimeout=$OperationTimeoutSec; if ($script:mockCpuFail) { throw 'Timed out' }; return [pscustomobject]@{PercentProcessorTime=37} }
                'Win32_OperatingSystem' { return [pscustomobject]@{FreePhysicalMemory=8388608;TotalVisibleMemorySize=33554432} }
                'Win32_PerfFormattedData_PerfOS_Memory' { return [pscustomobject]@{CommittedBytes=4294967296;CommitLimit=34359738368;PoolNonpagedBytes=134217728;PoolPagedBytes=268435456;PagesPersec=4} }
                'Win32_PerfFormattedData_PerfDisk_PhysicalDisk' { return [pscustomobject]@{Name='_Total';CurrentDiskQueueLength=2;DiskReadBytesPersec=1024;DiskWriteBytesPersec=2048;PercentDiskTime=3} }
                'MSAcpi_ThermalZoneTemperature' { return $script:mockAcpiResult }
                default { throw "Unexpected fixture class: $ClassName" }
            }
        }
        $script:mockAcpiResult = $null
        $metrics=Get-CMTelemetry $temp $root $cfg ([pscustomobject]@{BootKey='fixture'})
        Assert-CM ($metrics.CpuUsagePct -eq 37 -and $metrics.RamAvailableMB -eq 8192 -and $metrics.RamUsedPct -eq 75 -and $metrics.CommittedMB -eq 4096) 'Actual telemetry collector converts CIM memory units and CPU correctly'
        Assert-CM ($metrics.ErrorsJson -eq '[]' -and $metrics.TemperatureStatus -eq 'NOT_MEASURED' -and $metrics.DiskQueueLength -eq 2) 'Collector records unavailable temperature honestly and preserves disk queue'
        Write-CMTelemetry $temp $metrics
        $roundtrip=Import-Csv (Join-Path $temp 'Evidence/Logs/telemetry-v2.csv') -Delimiter ';'
        Assert-CM ($roundtrip.CpuUsagePct -eq '37' -and $roundtrip.RamUsedPct -eq '75' -and $roundtrip.BootKey -eq 'fixture') 'Actual telemetry collector roundtrips through the fixed CSV schema'

        # Deterministic ACPI thermal zone unit test using mocked CIM
        $script:mockAcpiResult = [pscustomobject]@{ CurrentTemperature=3052; CriticalTripPoint=3922; InstanceName='ACPI\ThermalZone\TZ00_0' }
        $acpiMetrics = Get-CMTelemetry $temp $root $cfg ([pscustomobject]@{BootKey='fixture'})
        Assert-CM ($acpiMetrics.TemperatureStatus -eq 'ACPI_WMI') 'Collector sets ACPI_WMI status when ACPI thermal zone is active'
        $acpiJson = $acpiMetrics.HardwareSensorsJson | ConvertFrom-Json
        Assert-CM ($acpiJson.ThermalZoneTemp -eq 32.0 -and $acpiJson.CriticalTripPoint -eq 119.0 -and $acpiJson.Source -eq 'MSAcpi_ThermalZoneTemperature') 'Collector converts ACPI tenths-of-kelvin to Celsius correctly'

        $script:mockCpuFail=$false; $script:mockCpuTimeout=$null
        $warmUp=Initialize-CMTelemetry
        Assert-CM ($warmUp.Success -and $warmUp.Error -eq '' -and $script:mockCpuTimeout -eq 30) 'Telemetry warm-up queries the CPU counter with a 30 s timeout'
        $script:mockCpuFail=$true
        try { $warmUp=Initialize-CMTelemetry } finally { $script:mockCpuFail=$false }
        Assert-CM (-not $warmUp.Success -and $warmUp.Error -match 'Timed out') 'Failed telemetry warm-up is reported, not thrown'
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
        $tempTestPath = Join-Path $temp 'Evidence/Logs/temperatures.csv'
        [IO.File]::WriteAllLines($tempTestPath, @('"Utc";"Local";"NVMe_NAND_C";"NVMe_Controller_C";"HDD_C";"Status";"Alert"','"2026-10-12T00:00:00Z";"2026-10-12T03:00:00+03:00";"45";"50";"35";"OK";""'))
        $fixtureBootUtc = [DateTime]::UtcNow.AddMinutes(5)
        $fixtureBoot = [pscustomobject]@{BootKey='AAAAAAAAAAAAAAAAAAAAAAAA';BootUtc=$fixtureBootUtc.ToString('o')}
        $fixtureEvent = ConvertFrom-CMEventXml (New-Fixture 41 'Microsoft-Windows-Kernel-Power' ($fixtureBootUtc.AddSeconds(3).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')) '<Data Name="BugcheckCode">292</Data><Data Name="PowerButtonTimestamp">0</Data>')
        New-CMIncident -Root $temp -Config $cfg -Boot $fixtureBoot -Events @($fixtureEvent,$whea)
        $incident=Join-Path $temp 'Evidence/Incidents/AAAAAAAAAAAAAAAAAAAAAAAA'
        $report=Read-CMJson (Join-Path $incident 'report.json')
        Assert-CM ($report.Classification.Type -eq 'Bugcheck' -and $report.BootEvents.Count -eq 2) 'Actual incident builder preserves classification and event data'
        Assert-CM ($null -ne $report.PreCrashMetrics) 'Incident builder computes and includes PreCrashMetrics in report.json'
        $csvTail=@(Import-Csv (Join-Path $incident 'telemetry-v2.csv') -Delimiter ';')
        Assert-CM ($csvTail.Count -eq 300 -and $csvTail[-1].RamAvailableMB -eq '8192') 'Incident CSV tail includes its header and 300 readable samples'
        Assert-CM (Test-Path (Join-Path $incident 'temperatures.csv')) 'Incident builder includes dedicated temperatures.csv in evidence package'
        $complete=Read-CMJson (Join-Path $incident 'complete.json')
        Assert-CM ($complete.ExportErrors.Count -eq 1) 'Failed EVTX export is explicitly recorded, not reported as successful'
        $before=(Get-FileHash (Join-Path $incident 'report.json')).Hash
        New-CMIncident -Root $temp -Config $cfg -Boot $fixtureBoot -Events @()
        Assert-CM ($before -eq (Get-FileHash (Join-Path $incident 'report.json')).Hash) 'Restarting a monitor in the same boot does not overwrite the incident'

        # Unit tests for Limit-CMCsvLog
        $trimTestCsv = Join-Path $temp 'trim-test.csv'
        $nowUtc = [DateTime]::UtcNow
        $lines = @('"SchemaVersion";"Utc";"Value"')
        for ($i = 0; $i -lt 200; $i++) {
            $lines += '"2";"{0}";"{1}"' -f ($nowUtc.AddHours(-5).AddSeconds($i).ToString('o')), $i
        }
        for ($i = 200; $i -lt 400; $i++) {
            $lines += '"2";"{0}";"{1}"' -f ($nowUtc.AddHours(-1).AddSeconds($i).ToString('o')), $i
        }
        [IO.File]::WriteAllLines($trimTestCsv, $lines)
        Limit-CMCsvLog -Path $trimTestCsv -RetentionHours 4 -MinKeepLines 50
        $afterTrim = @(Import-Csv $trimTestCsv -Delimiter ';')
        Assert-CM ($afterTrim.Count -eq 200 -and $afterTrim[0].Value -eq '200') 'Limit-CMCsvLog correctly trims rows older than RetentionHours using true UTC'

        $expiredCsv = Join-Path $temp 'expired-test.csv'
        $expLines = @('"SchemaVersion";"Utc";"Value"')
        for ($i = 0; $i -lt 500; $i++) {
            $expLines += '"2";"{0}";"{1}"' -f ($nowUtc.AddHours(-24).AddSeconds($i).ToString('o')), $i
        }
        [IO.File]::WriteAllLines($expiredCsv, $expLines)
        Limit-CMCsvLog -Path $expiredCsv -RetentionHours 4 -MinKeepLines 100
        $afterExpTrim = @(Import-Csv $expiredCsv -Delimiter ';')
        Assert-CM ($afterExpTrim.Count -eq 100 -and $afterExpTrim[-1].Value -eq '499') 'Limit-CMCsvLog keeps MinKeepLines when all rows are expired'

        # Unit tests for SMART snapshot comparison
        $s1 = [pscustomobject]@{ Disks = @([pscustomobject]@{ DeviceId='0'; PowerCycles=10; UnsafeShutdowns=2; StartStopCycleCount=$null; LoadUnloadCycleCount=$null }) }
        $s2 = [pscustomobject]@{ Disks = @([pscustomobject]@{ DeviceId='0'; PowerCycles=11; UnsafeShutdowns=3; StartStopCycleCount=$null; LoadUnloadCycleCount=$null }) }
        $cmp = Compare-CMSmartSnapshots -CurrentSnapshot $s2 -PreviousSnapshot $s1 -RestartClassification 'UnexpectedReset'
        Assert-CM ($cmp.PowerLossSuspected -eq $true -and $cmp.Confidence -eq 'High') 'SMART delta detects hardware power loss cycle increase'
        $cmpNoLoss = Compare-CMSmartSnapshots -CurrentSnapshot $s2 -PreviousSnapshot $s2 -RestartClassification 'UnexpectedReset'
        Assert-CM ($cmpNoLoss.PowerLossSuspected -eq $false -and $cmpNoLoss.Confidence -eq 'Moderate') 'Constant SMART counters confirm reset without power cycle'

        # SMART: Seagate head parking and spindowns do NOT trigger false power loss
        $sSeagatePrev = [pscustomobject]@{ Disks = @([pscustomobject]@{ DeviceId='0'; PowerCycles=100; UnsafeShutdowns=5; StartStopCycleCount=200; LoadUnloadCycleCount=1000 }) }
        $sSeagateCur  = [pscustomobject]@{ Disks = @([pscustomobject]@{ DeviceId='0'; PowerCycles=100; UnsafeShutdowns=5; StartStopCycleCount=201; LoadUnloadCycleCount=1015 }) }
        $cmpSeagate = Compare-CMSmartSnapshots -CurrentSnapshot $sSeagateCur -PreviousSnapshot $sSeagatePrev -RestartClassification 'UnexpectedReset'
        Assert-CM ($cmpSeagate.PowerLossSuspected -eq $false) 'HDD head parking and spin cycle deltas do not trigger false power loss'

        # SMART: Clean planned restart skips SMART evaluation
        $cmpClean = Compare-CMSmartSnapshots -CurrentSnapshot $s2 -PreviousSnapshot $s1 -RestartClassification 'RequestedRestart'
        Assert-CM ($cmpClean.Confidence -eq 'NotApplicable' -and $cmpClean.PowerLossSuspected -eq $false) 'Clean planned restart skips SMART delta evaluation'

        # SMART: Missing/null counters report InsufficientData honestly without blaming CPU
        $sNull1 = [pscustomobject]@{ Disks = @([pscustomobject]@{ DeviceId='0'; PowerCycles=$null; UnsafeShutdowns=$null }) }
        $sNull2 = [pscustomobject]@{ Disks = @([pscustomobject]@{ DeviceId='0'; PowerCycles=$null; UnsafeShutdowns=$null }) }
        $cmpNull = Compare-CMSmartSnapshots -CurrentSnapshot $sNull2 -PreviousSnapshot $sNull1 -RestartClassification 'UnexpectedReset'
        Assert-CM ($cmpNull.Confidence -eq 'InsufficientData' -and $cmpNull.PowerLossSuspected -eq $null) 'Missing SMART counters report InsufficientData honestly'

        # Dedicated unit test for atomic file replacement
        $atomicTestPath = Join-Path $temp 'atomic-replace.txt'
        [IO.File]::WriteAllText($atomicTestPath, 'OriginalContent')
        Limit-CMTextLog -Path $atomicTestPath -MaxLines 10
        Assert-CM (([IO.File]::ReadAllText($atomicTestPath)) -eq 'OriginalContent') 'Atomic replacement preserves content under limit'
        $multiLines = 1..25 | ForEach-Object { "Line $_" }
        [IO.File]::WriteAllLines($atomicTestPath, $multiLines)
        Limit-CMTextLog -Path $atomicTestPath -MaxLines 5
        $atomicTrimmed = @([IO.File]::ReadAllLines($atomicTestPath))
        Assert-CM ($atomicTrimmed.Length -eq 5 -and $atomicTrimmed[-1] -eq 'Line 25' -and -not (Test-Path ($atomicTestPath + '.trim.tmp')) -and -not (Test-Path ($atomicTestPath + '.trim.bak'))) 'Atomic text log trimming trims correctly and cleans swap files'
    } finally {
        & $diagnostics {
            Set-Item Function:script:Get-CMInventory $script:SavedInventoryFixture
            Set-Item Function:script:Export-CMEvtx $script:SavedExportFixture
            Remove-Variable SavedInventoryFixture,SavedExportFixture -Scope Script
        }
    }
    # Install.ps1 helpers: load only the function definitions via the AST; the installer itself never runs.
    $installAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Install.ps1'),[ref]$null,[ref]$null)
    $installFunctions=@($installAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] },$false))
    foreach ($fn in $installFunctions) { . ([scriptblock]::Create($fn.Extent.Text)) }
    Assert-CM ((@($installFunctions.Name) -join ',') -eq 'Assert-CMPackageManifest,Test-CMToolsChanged,Register-CMAutoStartTask') 'Install.ps1 exposes testable helper functions'

    $pkg=Join-Path $temp 'package';[void][IO.Directory]::CreateDirectory((Join-Path $pkg 'Modules'))
    $pkgFile=Join-Path $pkg 'Modules/Fixture.psm1'
    [IO.File]::WriteAllText($pkgFile,"line one`r`nline two`r`n")
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $lfFixtureHash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("line one`nline two`n")))).Replace('-','') } finally { $sha.Dispose() }
    $writeManifest={ param($Path,$Hash) [IO.File]::WriteAllText((Join-Path $pkg 'manifest.json'),(ConvertTo-Json @{Files=@(@{Path=$Path;Sha256=$Hash})} -Depth 4)) }
    $manifestError={ try { Assert-CMPackageManifest $pkg; return '' } catch { return $_.Exception.Message } }
    Assert-CM ((& $manifestError) -eq '') 'Manifest check skips a package without manifest.json'
    & $writeManifest 'Modules/Fixture.psm1' (Get-FileHash -LiteralPath $pkgFile -Algorithm SHA256).Hash.ToLower()
    Assert-CM ((& $manifestError) -eq '') 'Manifest check accepts a direct SHA-256 match'
    & $writeManifest 'Modules/Fixture.psm1' $lfFixtureHash
    Assert-CM ((& $manifestError) -eq '') 'Manifest check accepts a CRLF file whose manifest hash was taken with LF endings'
    [IO.File]::WriteAllText($pkgFile,"line one`r`nline 2`r`n")
    Assert-CM ((& $manifestError) -match 'checksum mismatch: Modules/Fixture.psm1') 'Manifest check rejects a modified file'
    & $writeManifest 'Modules/Missing.psm1' $lfFixtureHash
    Assert-CM ((& $manifestError) -match 'Package file missing: Modules/Missing.psm1') 'Manifest check rejects a missing file'
    & $writeManifest '../outside.ps1' $lfFixtureHash
    Assert-CM ((& $manifestError) -match 'Invalid path') 'Manifest check rejects path traversal'

    $toolsSource=Join-Path $temp 'tools-src';$toolsTarget=Join-Path $temp 'tools-dst'
    [void][IO.Directory]::CreateDirectory((Join-Path $toolsSource 'sub'))
    [IO.File]::WriteAllText((Join-Path $toolsSource 'a.dll'),'AAAA')
    [IO.File]::WriteAllText((Join-Path $toolsSource 'sub/b.dll'),'BBBB')
    Assert-CM (-not (Test-CMToolsChanged $toolsSource $toolsTarget)) 'Tools backup is skipped when no installed Tools directory exists'
    [void][IO.Directory]::CreateDirectory((Join-Path $toolsTarget 'sub'))
    Copy-Item (Join-Path $toolsSource 'a.dll') (Join-Path $toolsTarget 'a.dll')
    Assert-CM (Test-CMToolsChanged $toolsSource $toolsTarget) 'Tools backup is required when an installed tool file is missing'
    Copy-Item (Join-Path $toolsSource 'sub/b.dll') (Join-Path $toolsTarget 'sub/b.dll')
    Assert-CM (-not (Test-CMToolsChanged $toolsSource $toolsTarget)) 'Tools backup is skipped when installed tools are identical'
    [IO.File]::WriteAllText((Join-Path $toolsTarget 'sub/b.dll'),'BBBX')
    Assert-CM (Test-CMToolsChanged $toolsSource $toolsTarget) 'Tools backup is required when same-size tool content differs'

    # Mock the ScheduledTasks cmdlets; the real task is never created or changed.
    $taskMocks='New-ScheduledTaskAction','New-ScheduledTaskTrigger','New-ScheduledTaskPrincipal','New-ScheduledTaskSettingsSet','Register-ScheduledTask'
    try {
        function global:New-ScheduledTaskAction { param([string]$Execute,[string]$Argument,[string]$WorkingDirectory) [pscustomobject]@{Execute=$Execute;Argument=$Argument;WorkingDirectory=$WorkingDirectory} }
        function global:New-ScheduledTaskTrigger { param([switch]$AtStartup) [pscustomobject]@{AtStartup=[bool]$AtStartup} }
        function global:New-ScheduledTaskPrincipal { param([string]$UserId,[string]$LogonType,[string]$RunLevel) [pscustomobject]@{UserId=$UserId;LogonType=$LogonType;RunLevel=$RunLevel} }
        function global:New-ScheduledTaskSettingsSet { param([switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,[TimeSpan]$ExecutionTimeLimit,[int]$RestartCount,[TimeSpan]$RestartInterval,[string]$MultipleInstances) [pscustomobject]@{Batteries=($AllowStartIfOnBatteries -and $DontStopIfGoingOnBatteries);ExecutionTimeLimit=$ExecutionTimeLimit;RestartCount=$RestartCount;RestartInterval=$RestartInterval;MultipleInstances=$MultipleInstances} }
        function global:Register-ScheduledTask { param([string]$TaskName,$Action,$Trigger,$Principal,$Settings,[switch]$Force) $global:CMTestRegisteredTask=[pscustomobject]@{TaskName=$TaskName;Action=$Action;Trigger=$Trigger;Principal=$Principal;Settings=$Settings;Force=[bool]$Force} }
        $global:CMTestRegisteredTask=$null
        Register-CMAutoStartTask 'D:\CM Root'
        $task=$global:CMTestRegisteredTask
        Assert-CM ($task.TaskName -eq 'CrashMonitor_AutoStart' -and $task.Force -and $task.Trigger.AtStartup) 'AutoStart task is registered at startup under its fixed name'
        Assert-CM (($task.Action.Execute -replace '/','\') -like '*\System32\WindowsPowerShell\v1.0\powershell.exe' -and $task.Action.Argument -eq '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "D:\CM Root\CrashMonitor.ps1" -RootPath "D:\CM Root" -NonInteractive' -and $task.Action.WorkingDirectory -eq 'D:\CM Root') 'AutoStart task runs the supervisor with quoted RootPath'
        Assert-CM ($task.Principal.UserId -eq 'SYSTEM' -and $task.Principal.LogonType -eq 'ServiceAccount' -and $task.Principal.RunLevel -eq 'Highest') 'AutoStart task runs as SYSTEM with highest privileges'
        Assert-CM ($task.Settings.Batteries -and $task.Settings.ExecutionTimeLimit -eq [TimeSpan]::Zero -and $task.Settings.RestartCount -eq 3 -and $task.Settings.RestartInterval -eq [TimeSpan]::FromMinutes(1) -and $task.Settings.MultipleInstances -eq 'IgnoreNew') 'AutoStart task has no time limit, restarts on failure and ignores duplicate starts'
    } finally {
        foreach ($name in $taskMocks) { Remove-Item "Function:global:$name" -ErrorAction SilentlyContinue }
        Remove-Variable CMTestRegisteredTask -Scope Global -ErrorAction SilentlyContinue
    }

    # Scripts/Update-Manifest.ps1 runs on a temporary package; the repository manifest is never touched.
    $genRoot=Join-Path $temp 'manifest-package'
    foreach ($d in 'Scripts','Modules','Tools/sub','Evidence/Logs') { [void][IO.Directory]::CreateDirectory((Join-Path $genRoot $d)) }
    [IO.File]::WriteAllText((Join-Path $genRoot 'Main.ps1'),"'main'`r`n")
    [IO.File]::WriteAllText((Join-Path $genRoot 'Modules/M.psm1'),"'module'`r`n")
    [IO.File]::WriteAllText((Join-Path $genRoot 'Tools/sub/t.dll'),'TOOL')
    [IO.File]::WriteAllText((Join-Path $genRoot '.gitignore'),'Evidence/')
    [IO.File]::WriteAllText((Join-Path $genRoot 'README.md'),'docs')
    [IO.File]::WriteAllText((Join-Path $genRoot 'Evidence/Logs/telemetry-v2.csv'),'runtime')
    $genManifestPath=Join-Path $genRoot 'manifest.json'
    [IO.File]::WriteAllText($genManifestPath,'{"Package":"Fixture","Version":"9.9.9","GitCommit":"abc123","Files":[]}')
    $updateScript=Join-Path $root 'Scripts/Update-Manifest.ps1'
    & $updateScript -RootPath $genRoot | Out-Null
    $genManifest=Get-Content -LiteralPath $genManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-CM ((@($genManifest.Files | ForEach-Object { $_.Path }) -join ',') -eq '.gitignore,Main.ps1,Modules/M.psm1,Tools/sub/t.dll' -and $genManifest.FileCount -eq 4) 'Update-Manifest covers package files and skips docs and runtime evidence'
    Assert-CM ($genManifest.Package -eq 'Fixture' -and $genManifest.Version -eq '9.9.9' -and $genManifest.GitCommit -eq 'abc123') 'Update-Manifest preserves package name, version and Git commit'
    Assert-CM ((& { try { Assert-CMPackageManifest $genRoot; '' } catch { $_.Exception.Message } }) -eq '') 'Generated manifest passes the installer checksum validation'
    $genBefore=[IO.File]::ReadAllText($genManifestPath)
    $genAgain=@(& $updateScript -RootPath $genRoot)
    Assert-CM ($genAgain[-1] -match 'up to date' -and [IO.File]::ReadAllText($genManifestPath) -eq $genBefore) 'Update-Manifest leaves an up-to-date manifest untouched'
    [IO.File]::WriteAllText((Join-Path $genRoot 'Modules/M.psm1'),"'changed'`r`n")
    [IO.File]::WriteAllText((Join-Path $genRoot 'Scripts/New.ps1'),"'new'`r`n")
    Remove-Item -LiteralPath (Join-Path $genRoot 'Tools/sub/t.dll')
    $checkOut=@(& $updateScript -RootPath $genRoot -Check); $checkExit=$LASTEXITCODE
    Assert-CM ($checkExit -eq 1 -and ($checkOut -contains 'CHANGED: Modules/M.psm1') -and ($checkOut -contains 'ADDED: Scripts/New.ps1') -and ($checkOut -contains 'REMOVED: Tools/sub/t.dll') -and [IO.File]::ReadAllText($genManifestPath) -eq $genBefore) 'Update-Manifest -Check reports changes with exit code 1 without writing'
    & $updateScript -RootPath $genRoot | Out-Null
    $checkOut=@(& $updateScript -RootPath $genRoot -Check); $checkExit=$LASTEXITCODE
    Assert-CM ($checkExit -eq 0 -and $checkOut[-1] -match 'up to date') 'Regenerated manifest passes Update-Manifest -Check'
    Write-Output "Self-tests passed: $script:passed"
} finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
