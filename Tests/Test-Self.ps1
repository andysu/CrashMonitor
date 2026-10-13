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
    $decoded=[Net.WebUtility]::HtmlDecode($query)
    Assert-CM ($decoded -match 'EventRecordID > 43' -and $decoded -match 'EventRecordID <= 99' -and $decoded -match 'WHEA') 'Incremental query is bounded and includes WHEA'
    $initial=Get-CMEventXPath 0 99 $boot $true 'System'
    Assert-CM ($initial -match 'TimeCreated' -and $initial -match '2026-10-07T12:00:00.000Z') 'First capture uses UTC backfill'
    # The real event log engine rejects an XPath with more than ~22 OR terms ("The specified query is invalid"),
    # so every generated query is validated by Windows itself, not by string matching.
    $acceptsQuery={ param($q) try { (New-Object Diagnostics.Eventing.Reader.EventLogReader((New-Object Diagnostics.Eventing.Reader.EventLogQuery('System',[Diagnostics.Eventing.Reader.PathType]::LogName,$q)))).Dispose(); $true } catch { $false } }
    Assert-CM ($query.StartsWith('<QueryList>') -and ([regex]::Matches($query,'<Select ').Count -eq 2) -and $decoded -match "Provider\[@Name='disk'\] and EventID=51" -and $decoded -match 'EventID=140' -and $decoded -match 'EventID=4101' -and (& $acceptsQuery $query) -and (& $acceptsQuery $initial)) 'System query adds disk 51, Ntfs 50/98/140, Display 4101, clock change as a second Select accepted by Windows'
    $channelCfg=@{ OptionalEventChannels=@('Extra/Operational','Microsoft-Windows-Kernel-WHEA/Errors'); HardwareEventChannels=(Get-CMConfig $temp $root).HardwareEventChannels }
    $channels=@(Get-CMEventChannels $channelCfg)
    Assert-CM ((@($channels | ForEach-Object Name) -join ',') -eq 'System,Application,Extra/Operational,Microsoft-Windows-Kernel-WHEA/Errors,Microsoft-Windows-Kernel-WHEA/Operational,Microsoft-Windows-Kernel-Power/Thermal-Operational,Microsoft-Windows-Ntfs/Operational,Microsoft-Windows-Storage-ClassPnP/Operational' -and $channels[3].MaxLevel -eq 4) 'Default hardware channels are read once each, after System, Application and optional channels'
    $classPnp=$channels | Where-Object Name -eq 'Microsoft-Windows-Storage-ClassPnP/Operational'
    $classQuery=Get-CMEventXPath 0 99 $boot $false $classPnp.Name $classPnp.MaxLevel $classPnp.EventDataFilter
    Assert-CM ($classQuery -match '\(Level=1 or Level=2\)' -and $classQuery -notmatch 'Level=3' -and $classQuery -match "SenseKey'\]!='2' or Data\[@Name='AdditionalSenseCode'\]!='58'" -and $classQuery -match "SenseKey'\]!='5'") 'ClassPnP keeps errors but drops card-reader "no media" and unsupported-command noise'
    Assert-CM (@($channels | Where-Object { $_.Name -notin @('System','Application') } | Where-Object { -not (& $acceptsQuery (Get-CMEventXPath 0 99 $boot $true $_.Name $_.MaxLevel $_.EventDataFilter)) }).Count -eq 0) 'Every hardware channel query is accepted by the Windows event log engine'
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
    Assert-CM ($cols.Count -eq 24 -and $cols[-1] -eq 'ProcessorPerformancePct' -and $cols[19] -eq 'HardwareSensorsJson' -and @($cols | Select-Object -Unique).Count -eq $cols.Count) 'Telemetry schema has fixed unique columns'
    $cfg=Get-CMConfig $temp $root
    Assert-CM ($cfg.UsePerformanceCounters -eq $true) 'Persistent performance counters are the default collector'
    # The WMI collector stays the fallback; these tests drive it through mocked CIM classes.
    $cfg.UsePerformanceCounters=$false
    Assert-CM (-not $cfg.EnableHardwareSensors -and $cfg.SchemaVersion -eq 2) 'Hardware driver probing is opt-in'
    Assert-CM ($cfg.SampleIntervalSeconds -eq 3 -and $cfg.EventPollSeconds -eq 3 -and $cfg.HeartbeatIntervalSeconds -eq 2) 'Fresh install samples telemetry and events every 3 s with a 2 s heartbeat'
    # Mock only the OS data source; run the actual collector and CSV serializer.
    $script:mockAcpiResult = $null
    $oldCimFunction=Get-Item Function:\Get-CimInstance -ErrorAction SilentlyContinue
    try {
        function global:Get-CimInstance {
            param([string]$ClassName,[string]$Filter,[int]$OperationTimeoutSec,[string]$Namespace)
            switch ($ClassName) {
                'Win32_PerfFormattedData_PerfOS_Processor' { $script:mockCpuTimeout=$OperationTimeoutSec; if ($script:mockCpuFail) { throw 'Timed out' }; return [pscustomobject]@{PercentProcessorTime=37} }
                'Win32_OperatingSystem' { return [pscustomobject]@{FreePhysicalMemory=8388608;TotalVisibleMemorySize=33554432} }
                'Win32_PerfFormattedData_PerfOS_Memory' { return [pscustomobject]@{CommittedBytes=4294967296;CommitLimit=34359738368;PoolNonpagedBytes=134217728;PoolPagedBytes=268435456;PagesPersec=4} }
                'Win32_PerfFormattedData_PerfDisk_PhysicalDisk' { return [pscustomobject]@{Name='_Total';CurrentDiskQueueLength=2;DiskReadBytesPersec=1024;DiskWriteBytesPersec=2048;PercentDiskTime=3} }
                'Win32_PerfFormattedData_Counters_ProcessorInformation' { return [pscustomobject]@{PercentProcessorPerformance=95} }
                'MSAcpi_ThermalZoneTemperature' { return $script:mockAcpiResult }
                default { throw "Unexpected fixture class: $ClassName" }
            }
        }
        $script:mockAcpiResult = $null
        $metrics=Get-CMTelemetry $temp $root $cfg ([pscustomobject]@{BootKey='fixture'})
        Assert-CM ($metrics.CpuUsagePct -eq 37 -and $metrics.RamAvailableMB -eq 8192 -and $metrics.RamUsedPct -eq 75 -and $metrics.CommittedMB -eq 4096) 'Actual telemetry collector converts CIM memory units and CPU correctly'
        Assert-CM ($metrics.ProcessorPerformancePct -eq 95) 'WMI fallback records % Processor Performance for throttling detection'
        $fallbackCfg=$cfg.Clone(); $fallbackCfg.UsePerformanceCounters=$true
        & (Get-Module TelemetryV2) { $script:FastCounters=$false }
        $fallbackMetrics=Get-CMTelemetry $temp $root $fallbackCfg ([pscustomobject]@{BootKey='fixture'})
        & (Get-Module TelemetryV2) { $script:FastCounters=$null }
        Assert-CM ($fallbackMetrics.CpuUsagePct -eq 37 -and $fallbackMetrics.RamAvailableMB -eq 8192 -and $fallbackMetrics.ErrorsJson -eq '[]') 'Collector falls back to WMI when performance counters are unavailable'
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

        # Hardware sensor mapping. The Intel set mirrors the server (i5-9400, NCT6796D, Samsung 980, ST1000) and its
        # expected values were captured from the code before AMD support was added: they must never change.
        # The AMD set is a real snapshot from a Ryzen 3 3200G / ASUS TUF GAMING A520M-PLUS II (NCT6798D) workstation.
        $intelSensors=@'
Nuvoton_NCT6796D_Control_Fan_1:60
Nuvoton_NCT6796D_Voltage_Vcore:0.904
Nuvoton_NCT6796D_Voltage_Voltage_2:1.016
Nuvoton_NCT6796D_Voltage_AVCC:3.392
Nuvoton_NCT6796D_Voltage_Plus_3.3V:3.344
Nuvoton_NCT6796D_Voltage_Voltage_5:1.024
Nuvoton_NCT6796D_Voltage_Voltage_6:2.024
Nuvoton_NCT6796D_Voltage_3VSB:3.392
Nuvoton_NCT6796D_Voltage_VBat:3.104
Nuvoton_NCT6796D_Voltage_VTT:1.056
Nuvoton_NCT6796D_Temperature_Temperature_1:35
Nuvoton_NCT6796D_Temperature_Temperature_2:40
Nuvoton_NCT6796D_Fan_Fan_2:1320.5
Intel_Core_i5-9400_Load_CPU_Total:12.5
Intel_Core_i5-9400_Temperature_CPU_Core_1:38
Intel_Core_i5-9400_Temperature_CPU_Core_2:39
Intel_Core_i5-9400_Temperature_CPU_Core_1_Distance_to_TjMax:62
Intel_Core_i5-9400_Temperature_CPU_Core_2_Distance_to_TjMax:61
Intel_Core_i5-9400_Temperature_CPU_Package:42
Intel_Core_i5-9400_Temperature_Core_Max:41
Intel_Core_i5-9400_Power_CPU_Package:18.512
Intel_Core_i5-9400_Power_CPU_Cores:10.204
Intel_Core_i5-9400_Voltage_CPU_Core:0.85
Samsung_SSD_980_1TB_Temperature_Temperature:41
Samsung_SSD_980_1TB_Level_Available_Spare:100
Samsung_SSD_980_1TB_Temperature_Temperature_2:52
ST1000DM010-2EP102_Temperature_Temperature:34
'@
        $amdSensors=@'
Nuvoton_NCT6798D_Voltage_Vcore:0.464
Nuvoton_NCT6798D_Voltage_Voltage_2:1.008
Nuvoton_NCT6798D_Voltage_AVCC:3.376
Nuvoton_NCT6798D_Voltage_Plus_3.3V:3.344
Nuvoton_NCT6798D_Voltage_Voltage_6:0.888
Nuvoton_NCT6798D_Voltage_3VSB:3.376
Nuvoton_NCT6798D_Voltage_VBat:3.312
Nuvoton_NCT6798D_Voltage_VTT:0.896
Nuvoton_NCT6798D_Temperature_Temperature_1:35
Nuvoton_NCT6798D_Temperature_Temperature_3:94
Nuvoton_NCT6798D_Temperature_Temperature_6:97
Nuvoton_NCT6798D_Fan_Fan_2:1220.615
AMD_Ryzen_3_3200G_with_Radeon_Vega_Graphics_Load_CPU_Total:26.103
AMD_Ryzen_3_3200G_with_Radeon_Vega_Graphics_Power_Package:10.455
AMD_Ryzen_3_3200G_with_Radeon_Vega_Graphics_Voltage_Core_1_VID:1.188
AMD_Ryzen_3_3200G_with_Radeon_Vega_Graphics_Temperature_Core_(Tctl_Tdie):37
AMD_Ryzen_3_3200G_with_Radeon_Vega_Graphics_Voltage_Core_(SVI2_TFN):1.175
IR-SSDPR-S25A-120_Temperature_Temperature:33
KINGSTON_SNV2S500G_Temperature_Temperature:38
KINGSTON_SNV2S500G_Level_Available_Spare:100
KINGSTON_SNV2S500G_Temperature_Temperature_2:47
TOSHIBA_DT01ACA100_Temperature_Temperature:34
ST1000DM010-2EP102_Temperature_Temperature:32
'@
        $toSensorDict={ param($text) $d=[ordered]@{}; foreach ($line in ($text -split "`r?`n")) { if ($line) { $i=$line.LastIndexOf(':'); $d[$line.Substring(0,$i)]=[double]::Parse($line.Substring($i+1),[Globalization.CultureInfo]::InvariantCulture) } }; $d }
        $sensorReader=[pscustomobject]@{Data=$null}; $sensorReader | Add-Member ScriptMethod ReadAllSensors { $this.Data }
        Import-Module (Join-Path $root 'Modules/VoltageMonitor.psm1') -Force
        $voltage=Get-Module VoltageMonitor
        & $voltage { param($r) $script:ReaderObj=$r; $script:LibLoaded=$true } $sensorReader
        $workstationDisks=@([pscustomobject]@{FriendlyName='IR-SSDPR-S25A-120';MediaType='SSD';BusType='SATA'},[pscustomobject]@{FriendlyName='KINGSTON SNV2S500G';MediaType='SSD';BusType='NVMe'},[pscustomobject]@{FriendlyName='ST1000DM010-2EP102';MediaType='HDD';BusType='SATA'},[pscustomobject]@{FriendlyName='TOSHIBA DT01ACA100';MediaType='HDD';BusType='SATA'})
        try {
            $sensorReader.Data=& $toSensorDict $intelSensors
            $intel=Get-CrashMonitorVoltageSnapshot
            Assert-CM ($intel.Vcore -eq 0.904 -and $intel.Plus12V -eq 12.192 -and $intel.Plus5V -eq 5.06 -and $intel.Plus33V -eq 3.344 -and $intel.AVCC -eq 3.392 -and $intel['3VSB'] -eq 3.392 -and $intel.VBat -eq 3.104 -and $intel.VTT -eq 1.056) 'Server sensors: NCT6796D rails including derived +12V/+5V are unchanged'
            Assert-CM ($intel.CpuTemp -eq 38 -and $intel.CpuPower -eq '18.512W' -and $intel.DiskTemp -eq 41 -and $intel.Status -eq 'OK') 'Server sensors: i5-9400 temperature/power and Samsung 980 disk temperature are unchanged'
            $intelStorage=Get-CMStorageTemperatures $intel.RawSummary $workstationDisks
            Assert-CM ($intelStorage.NvmeNand -eq 41 -and $intelStorage.NvmeCtrl -eq 52 -and $intelStorage.Hdd -eq 34) 'Server sensors: Samsung 980 and ST1000 keep priority in temperatures.csv over other NVMe/HDD disks'
            Assert-CM (@((Get-CMSensorAlerts $intel).Keys).Count -eq 0) 'Server sensors: normal readings raise no alerts'
            $sensorReader.Data=& $toSensorDict ($intelSensors -replace 'CPU_Package:42','CPU_Package:85' -replace 'Distance_to_TjMax:62','Distance_to_TjMax:75')
            $hot=Get-CMSensorAlerts (Get-CrashMonitorVoltageSnapshot)
            Assert-CM ((@($hot.Keys) -join ',') -eq 'Intel_Core_i5-9400_Temperature_CPU_Package') 'Hot CPU package alerts; Distance to TjMax is headroom and never alerts'

            $sensorReader.Data=& $toSensorDict $amdSensors
            $amd=Get-CrashMonitorVoltageSnapshot
            Assert-CM ($amd.CpuTemp -eq 37 -and $amd.CpuPower -eq '10.455W' -and $amd.Vcore -eq 1.175) 'AMD sensors: Tctl/Tdie, package power and SVI2 core voltage are mapped'
            Assert-CM ($amd.Plus12V -eq 'N/A' -and $amd.Plus5V -eq 'N/A' -and $amd.Plus33V -eq 3.344) 'AMD sensors: rails without a known divider stay N/A instead of guessed'
            $amdStorage=Get-CMStorageTemperatures $amd.RawSummary $workstationDisks
            Assert-CM ($amdStorage.NvmeNand -eq 38 -and $amdStorage.NvmeCtrl -eq 47 -and $amdStorage.Hdd -eq 32) 'temperatures.csv records any NVMe vendor when no Samsung 980 is present'
            $noSeagate=Get-CMStorageTemperatures ($amd.RawSummary -replace '\|?ST1000DM010-2EP102_Temperature_Temperature:32','') $workstationDisks
            Assert-CM ($noSeagate.Hdd -eq 34) 'temperatures.csv records any HDD vendor when no ST1000 is present'
            Assert-CM ((@((Get-CMSensorAlerts $amd).Keys) -join ',') -eq 'Nuvoton_NCT6798D_Temperature_Temperature_3,Nuvoton_NCT6798D_Temperature_Temperature_6') 'Unwired Super I/O inputs alert until they are listed in IgnoredTemperatureSensors'
            Assert-CM (@((Get-CMSensorAlerts $amd @('*NCT6798D_Temperature_Temperature_3','*NCT6798D_Temperature_Temperature_6')).Keys).Count -eq 0) 'IgnoredTemperatureSensors silences only the listed inputs'
            # telemetry-v2.csv: full sensor list every SensorFullSummaryIntervalSeconds, essential entries in between.
            $slimRoot=Join-Path $temp 'slim'
            & (Get-Module TelemetryV2) { $script:LastFullSensorSummaryUtc=[datetime]::MinValue }
            $slimRow=[ordered]@{ SchemaVersion=2; Utc='2026-10-13T10:00:00.0000000Z'; BootKey='S'; HardwareSensorsJson=(($amd | ConvertTo-Json -Compress) -replace 'Nuvoton_NCT6798D_Fan_Fan_2','Load_CPU_Total:5|Nuvoton_NCT6798D_Fan_Fan_2') }
            Write-CMTelemetry $slimRoot $slimRow @{ SensorFullSummaryIntervalSeconds=30 }
            Write-CMTelemetry $slimRoot $slimRow @{ SensorFullSummaryIntervalSeconds=30 }
            $slimRows=@(Import-Csv (Join-Path $slimRoot 'Evidence/Logs/telemetry-v2.csv') -Delimiter ';' | ForEach-Object { $_.HardwareSensorsJson | ConvertFrom-Json })
            Assert-CM ($slimRows[0].RawSummary -match 'Load_CPU_Total' -and $slimRows[1].RawSummary -notmatch 'Load_' -and $slimRows[1].RawSummary -match 'Temperature_Core_\(Tctl_Tdie\):37' -and $slimRows[1].RawSummary -match 'Fan_Fan_2:1220' -and $slimRows[1].RawSummaryScope -eq 'Essential' -and $slimRows[1].Vcore -eq 1.175) 'telemetry-v2.csv keeps the full sensor list periodically and temperatures, voltages, power and fans in every row'
            $packetRoot=Join-Path $temp 'packet'
            Write-CMJson (Join-Path $packetRoot 'Evidence/State/hardware-event-counts.json') @{ BootKey='BOOTP'; Whea=2; Storage=5; Thermal=1 }
            $packetRow=[ordered]@{ Utc='2026-10-13T10:00:00.0000000Z'; BootKey='BOOTP'; CpuUsagePct=12; RamUsedPct=80; RamAvailableMB=2048; DiskQueueLength=0; IoLatencyMs=4; TemperatureStatus='OK'; HardwareSensorsJson=($amd | ConvertTo-Json -Compress) }
            $packet=New-CMTelemetryPacket -Row $packetRow -Root $packetRoot
            Assert-CM ($packet.Type -eq 'telemetry' -and $packet.CpuTempC -eq 37 -and $packet.CpuPowerW -eq 10.455 -and $packet.Vcore -eq 1.175 -and $packet.FanRpm -eq 1221 -and -not $packet.Contains('Plus12V') -and $packet.Whea -eq 2 -and $packet.StorageErrors -eq 5 -and $packet.ThermalEvents -eq 1) 'Remote telemetry packet carries CPU temperature/power, Vcore, fan and per-boot hardware event counts; N/A rails are omitted'
            $packetRow.BootKey='OTHER'
            Assert-CM (-not (New-CMTelemetryPacket -Row $packetRow -Root $packetRoot).Contains('Whea')) 'Hardware event counts from another boot are not sent'
            $watchAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Scripts/Watch-LiveSensors.ps1'),[ref]$null,[ref]$null)
            . ([scriptblock]::Create(($watchAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-CMFanSummary' },$false) | Select-Object -First 1).Extent.Text))
            Assert-CM ((Get-CMFanSummary $intel.RawSummary) -eq 'Fan2 1321 RPM' -and (Get-CMFanSummary $amd.RawSummary) -eq 'Fan2 1221 RPM') 'Watch-LiveSensors shows spinning fans in RPM and skips PWM control percentages'
            Assert-CM ((Get-CMFanSummary 'Chip_Fan_Fan_1:0|Chip_Control_Fan_1:60') -eq 'N/A' -and (Get-CMFanSummary '') -eq 'N/A') 'Watch-LiveSensors shows N/A when no fan is spinning'

            # Alerts reach telemetry.log once when they start and once when they clear, not on every sample.
            $alertRoot=Join-Path $temp 'alerts'
            $hwCfg=$cfg.Clone(); $hwCfg.EnableHardwareSensors=$true
            function global:Get-PhysicalDisk { param($ErrorAction) $workstationDisks }
            & (Get-Module TelemetryV2) { $script:DiskInventory=$null; $script:ActiveSensorAlerts=@{} }
            1..3 | ForEach-Object { [void](Get-CMTelemetry $alertRoot $root $hwCfg ([pscustomobject]@{BootKey='fixture'})) }
            $alertLog=@(Get-Content (Join-Path $alertRoot 'Evidence/Logs/telemetry.log'))
            Assert-CM ($alertLog.Count -eq 2 -and @($alertLog | Where-Object { $_ -match '\[WARNING\] CRITICAL: High temperature warning: Nuvoton_NCT6798D_Temperature_Temperature_[36]' }).Count -eq 2) 'Active sensor alerts are logged once, not on every sample'
            $sensorReader.Data=& $toSensorDict ($amdSensors -replace 'Temperature_3:94','Temperature_3:40')
            [void](Get-CMTelemetry $alertRoot $root $hwCfg ([pscustomobject]@{BootKey='fixture'}))
            $alertLog=@(Get-Content (Join-Path $alertRoot 'Evidence/Logs/telemetry.log'))
            Assert-CM ($alertLog.Count -eq 3 -and $alertLog[-1] -match '\[INFO\] Sensor alert cleared: Nuvoton_NCT6798D_Temperature_Temperature_3$') 'A cleared sensor alert is logged once'
            $tempRows=@(Import-Csv (Join-Path $alertRoot 'Evidence/Logs/temperatures.csv') -Delimiter ';')
            Assert-CM ($tempRows.Count -eq 4 -and $tempRows[-1].NVMe_NAND_C -eq '38' -and $tempRows[-1].NVMe_Controller_C -eq '47' -and $tempRows[-1].HDD_C -eq '32') 'Collector writes NVMe and HDD temperatures for non-server hardware'
        } finally {
            & $voltage { $script:ReaderObj=$null; $script:LibLoaded=$false }
            Remove-Module VoltageMonitor -ErrorAction SilentlyContinue
            Remove-Item Function:\Get-PhysicalDisk -ErrorAction SilentlyContinue
            & (Get-Module TelemetryV2) { $script:DiskInventory=$null; $script:ActiveSensorAlerts=@{} }
        }
    } finally {
        Remove-Item Function:\Get-CimInstance -ErrorAction SilentlyContinue
        if ($oldCimFunction) { Set-Item Function:\Get-CimInstance $oldCimFunction.ScriptBlock }
    }
    # Real persistent counters on this machine (no mocks): sane values, per-disk breakdown, no collector errors.
    & (Get-Module TelemetryV2) { $script:FastCounters=$null; $script:DiskInstanceKey=$null }
    $fastCfg=$cfg.Clone(); $fastCfg.UsePerformanceCounters=$true
    $fastMetrics=Get-CMTelemetry $temp $root $fastCfg ([pscustomobject]@{BootKey='fixture'})
    if ((Get-CMCounterMode) -eq 'PerformanceCounter') {
        $fastDisks=@($fastMetrics.DiskCountersJson | ConvertFrom-Json | ForEach-Object { $_ })
        Assert-CM ($fastMetrics.CpuUsagePct -ge 0 -and $fastMetrics.CpuUsagePct -le 100 -and $fastMetrics.RamAvailableMB -gt 0 -and $fastMetrics.RamUsedPct -gt 0 -and $fastMetrics.RamUsedPct -lt 100 -and $fastMetrics.CommittedMB -gt 0 -and $fastMetrics.ProcessorPerformancePct -gt 0 -and @($fastDisks | Where-Object Name -eq '_Total').Count -eq 1 -and $fastMetrics.ErrorsJson -eq '[]') 'Persistent performance counters give CPU, RAM, commit, per-disk and % Processor Performance values'
    } else {
        Assert-CM ($fastMetrics.ErrorsJson -eq '[]' -and $null -ne $fastMetrics.CpuUsagePct) 'Performance counters unavailable on this system; the WMI fallback collected the sample'
    }
    Close-CMTelemetrySensor
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
        function script:Export-CMEvtx { param($Directory,$SinceUtc,$ExtraChannels); throw 'Fixture: EVTX unavailable on this platform' }
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

        # SMART: smartctl device names swapped between boots must not be compared as the same disk
        $swPrev = [pscustomobject]@{ Disks = @([pscustomobject]@{ Device='/dev/sda'; Serial='AAA'; PowerCycles=10; UnsafeShutdowns=5 },[pscustomobject]@{ Device='/dev/sdb'; Serial='BBB'; PowerCycles=100; UnsafeShutdowns=50 }) }
        $swCur  = [pscustomobject]@{ Disks = @([pscustomobject]@{ Device='/dev/sda'; Serial='BBB'; PowerCycles=100; UnsafeShutdowns=50 },[pscustomobject]@{ Device='/dev/sdb'; Serial='AAA'; PowerCycles=10; UnsafeShutdowns=5 }) }
        $cmpSwap = Compare-CMSmartSnapshots -CurrentSnapshot $swCur -PreviousSnapshot $swPrev -RestartClassification 'UnexpectedReset'
        Assert-CM ($cmpSwap.PowerLossSuspected -eq $false -and @($cmpSwap.DiskDeltas | Where-Object { $_.PowerCyclesDelta -ne 0 }).Count -eq 0) 'SMART deltas match disks by serial when smartctl device names change between boots'

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
    # Storage health: smartctl JSON (ATA and NVMe) and Windows reliability counters, merged per disk, compared across snapshots.
    $ataJson='{"model_name":"ST1000DM010-2EP102","serial_number":"ZN10TCNW","smart_status":{"passed":true},"temperature":{"current":33},"power_on_time":{"hours":41234},"power_cycle_count":1520,"ata_smart_attributes":{"table":[{"id":5,"raw":{"value":0}},{"id":12,"raw":{"value":1520}},{"id":187,"raw":{"value":0}},{"id":188,"raw":{"value":2}},{"id":192,"raw":{"value":210}},{"id":197,"raw":{"value":8}},{"id":198,"raw":{"value":8}},{"id":199,"raw":{"value":3}}]}}'
    $nvmeJson='{"model_name":"KINGSTON SNV2S500G","serial_number":"50026B7283291D3E5","smart_status":{"passed":true},"temperature":{"current":38},"nvme_smart_health_information_log":{"critical_warning":0,"available_spare":100,"percentage_used":7,"power_cycles":900,"power_on_hours":5000,"unsafe_shutdowns":45,"media_errors":0,"num_err_log_entries":12}}'
    $ata=ConvertFrom-CMSmartctlJson ($ataJson | ConvertFrom-Json) '/dev/sda'
    Assert-CM ($ata.ReallocatedSectors -eq 0 -and $ata.PendingSectors -eq 8 -and $ata.OfflineUncorrectable -eq 8 -and $ata.CrcErrors -eq 3 -and $ata.CommandTimeouts -eq 2 -and $ata.UnsafeShutdowns -eq 210 -and $ata.PowerCycles -eq 1520 -and $ata.PowerOnHours -eq 41234 -and $ata.SmartPassed -eq $true) 'smartctl ATA attributes 5/12/187/188/192/197/198/199 are mapped'
    $packedAta=ConvertFrom-CMSmartctlJson (($ataJson -replace '"id":188,"raw":\{"value":2\}','"id":188,"raw":{"value":8590065669}') | ConvertFrom-Json) '/dev/sda'
    Assert-CM ($packedAta.CommandTimeouts -eq 5) 'Seagate packed attribute 188 (raw "2 2 5") is read as 5 command timeouts'
    $toshiba=ConvertFrom-CMSmartctlJson (($ataJson -replace '"id":192,"raw":\{"value":210\}','"id":192,"raw":{"value":51281}},{"id":193,"raw":{"value":51281}') | ConvertFrom-Json) '/dev/sdb'
    Assert-CM ($null -eq $toshiba.UnsafeShutdowns -and $toshiba.LoadUnloadCycles -eq 51281 -and $ata.UnsafeShutdowns -eq 210) 'Attribute 192 equal to the load/unload count (193) is not read as unsafe shutdowns'
    # The smartctl runner inside Get-CMSmartSnapshot: arguments must arrive and a large output must not block the process.
    $commonAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Modules/Common.psm1'),[ref]$null,[ref]$null)
    . ([scriptblock]::Create(($commonAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-ExecutableWithTimeout' },$true) | Select-Object -First 1).Extent.Text))
    $cmdExe=Join-Path $env:SystemRoot 'System32/cmd.exe'
    $echoed=Invoke-ExecutableWithTimeout -ExePath $cmdExe -Arguments '/c echo smartctl-args-ok' -TimeoutMs 10000
    $bulk=Invoke-ExecutableWithTimeout -ExePath $cmdExe -Arguments '/c for /L %i in (1,1,3000) do @echo 0123456789012345678901234567890123' -TimeoutMs 10000
    Assert-CM ($echoed -match 'smartctl-args-ok' -and $bulk.Length -gt 90000) 'Boot SMART runner passes arguments to smartctl and reads large output without blocking'
    $nvme=ConvertFrom-CMSmartctlJson ($nvmeJson | ConvertFrom-Json) '/dev/nvme0'
    Assert-CM ($nvme.BusType -eq 'NVMe' -and $nvme.MediaErrors -eq 0 -and $nvme.ErrorLogEntries -eq 12 -and $nvme.UnsafeShutdowns -eq 45 -and $nvme.WearPct -eq 7 -and $nvme.AvailableSparePct -eq 100 -and $nvme.CriticalWarning -eq 0) 'smartctl NVMe health log is mapped'
    $storageDisks=@([pscustomobject]@{DeviceId='2';FriendlyName='ST1000DM010-2EP102';SerialNumber='ZN10TCNW';BusType='SATA';MediaType='HDD';HealthStatus='Healthy'},[pscustomobject]@{DeviceId='3';FriendlyName='KINGSTON SNV2S500G';SerialNumber='0000_0000_0000_0000_0026_B728_3291_D3E5.';BusType='NVMe';MediaType='SSD';HealthStatus='Healthy'})
    $global:CMTestCounters=@{ '2'=[pscustomobject]@{Temperature=33;ReadErrorsTotal=0;ReadErrorsUncorrected=0;ReadLatencyMax=120}; '3'=[pscustomobject]@{Temperature=38;TemperatureMax=77;Wear=0} }
    $global:CMTestStorageDisks=$storageDisks
    function global:Get-PhysicalDisk { [CmdletBinding()] param() $global:CMTestStorageDisks }
    function global:Get-StorageReliabilityCounter { [CmdletBinding()] param([Parameter(ValueFromPipeline=$true)]$InputObject) process { $global:CMTestCounters[[string]$InputObject.DeviceId] } }
    & $diagnostics { param($a,$n) $script:SavedSmartctlPath=${function:Get-CMSmartctlPath}; $script:SavedInvokeSmartctl=${function:Invoke-CMSmartctl}; $script:SmartFixture=@{a=$a;n=$n}; function script:Get-CMSmartctlPath { param($ToolsDir) $null } } $ataJson $nvmeJson
    try {
        $storageRoot=Join-Path $temp 'storage'
        $first=@(Invoke-CMStorageHealthSnapshot -Root $storageRoot -ToolsDir $storageRoot -BootKey 'BOOT1')
        $storageCsv=@(Import-Csv (Join-Path $storageRoot 'Evidence/Logs/storage-health.csv') -Delimiter ';')
        Assert-CM ($first.Count -eq 0 -and $storageCsv.Count -eq 2 -and $storageCsv[0].Source -eq 'CIM' -and $storageCsv[0].ReadLatencyMaxMs -eq '120' -and $storageCsv[1].TemperatureMaxC -eq '77' -and $storageCsv[0].Utc) 'First storage snapshot writes one CSV row per disk from reliability counters'
        $global:CMTestCounters['2'].ReadErrorsUncorrected=4
        $global:CMTestStorageDisks[1].HealthStatus='Warning'
        $second=@(Invoke-CMStorageHealthSnapshot -Root $storageRoot -ToolsDir $storageRoot -BootKey 'BOOT2')
        $storageLog=@(Get-Content (Join-Path $storageRoot 'Evidence/Logs/events.log'))
        Assert-CM ($second.Count -eq 2 -and ($second | Where-Object { $_.Counter -eq 'ReadErrorsUncorrected' -and $_.Before -eq 0 -and $_.After -eq 4 }) -and ($second | Where-Object { $_.Counter -eq 'Health' -and $_.After -eq 'Warning' }) -and @($storageLog | Where-Object { $_ -match '\[WARNING\] Storage health change: ST1000DM010-2EP102 \(ZN10TCNW\) ReadErrorsUncorrected 0 -> 4' }).Count -eq 1) 'Grown error counters and health changes are returned and logged once'
        & $diagnostics { function script:Get-CMSmartctlPath { param($ToolsDir) 'smartctl-fixture' }; function script:Invoke-CMSmartctl { param($Path,$Arguments) if ($Arguments -like '--scan*') { '{"devices":[{"name":"/dev/sda","type":"sat"},{"name":"/dev/nvme0","type":"nvme"}]}' } elseif ($Arguments -like '*/dev/sda*') { $script:SmartFixture.a } else { $script:SmartFixture.n } } }
        $merged=@(Get-CMStorageHealth $storageRoot)
        Assert-CM ($merged.Count -eq 2 -and $merged[0].Source -eq 'CIM+smartctl' -and $merged[0].CrcErrors -eq 3 -and $merged[0].ReadLatencyMaxMs -eq 120 -and $merged[1].Source -eq 'CIM+smartctl' -and $merged[1].ErrorLogEntries -eq 12 -and $merged[1].TemperatureMaxC -eq 77) 'smartctl data merges into the matching disk by serial, or by model when NVMe serials differ'
        $grown=@(Compare-CMStorageHealth @($merged) @(ConvertFrom-CMSmartctlJson (($ataJson -replace '"id":199,"raw":\{"value":3\}','"id":199,"raw":{"value":5}' -replace '"passed":true','"passed":false') | ConvertFrom-Json) '/dev/sda'))
        Assert-CM ((@($grown | ForEach-Object Counter) -join ',') -eq 'CrcErrors,SmartPassed' -and $grown[0].Before -eq 3 -and $grown[0].After -eq 5) 'CRC error growth and a failed SMART status are reported'
        Assert-CM ($null -ne $report.PSObject.Properties['StorageHealthChanges']) 'Incident report.json carries StorageHealthChanges'
    } finally {
        & $diagnostics { Set-Item Function:script:Get-CMSmartctlPath $script:SavedSmartctlPath; Set-Item Function:script:Invoke-CMSmartctl $script:SavedInvokeSmartctl; Remove-Variable SavedSmartctlPath,SavedInvokeSmartctl,SmartFixture -Scope Script }
        Remove-Item Function:\Get-PhysicalDisk,Function:\Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        Remove-Variable CMTestCounters,CMTestStorageDisks -Scope Global -ErrorAction SilentlyContinue
    }

    # Hardware event counters for the remote packet: per boot, only hardware signals, history before the boot ignored.
    $countRoot=Join-Path $temp 'counts'
    $countBoot=[pscustomobject]@{ BootKey='BOOTC'; BootUtc='2026-10-13T08:00:00Z' }
    $countEvents=@(
        [pscustomobject]@{ Provider='Microsoft-Windows-WHEA-Logger'; Channel='System'; Level=3; EventId=19; Utc='2026-10-13T09:00:00Z' },
        [pscustomobject]@{ Provider='Microsoft-Windows-WHEA-Logger'; Channel='System'; Level=3; EventId=19; Utc='2026-10-13T07:00:00Z' },
        [pscustomobject]@{ Provider='Microsoft-Windows-StorageClassPnP'; Channel='Microsoft-Windows-Storage-ClassPnP/Operational'; Level=2; EventId=500; Utc='2026-10-13T09:01:00Z' },
        [pscustomobject]@{ Provider='Microsoft-Windows-Ntfs'; Channel='System'; Level=4; EventId=98; Utc='2026-10-13T09:02:00Z' },
        [pscustomobject]@{ Provider='Microsoft-Windows-Kernel-Processor-Power'; Channel='System'; Level=3; EventId=37; Utc='2026-10-13T09:03:00Z' })
    Update-CMHardwareEventCounts -Root $countRoot -Boot $countBoot -Events $countEvents
    Update-CMHardwareEventCounts -Root $countRoot -Boot $countBoot -Events @($countEvents[0])
    $countState=Read-CMJson (Join-Path $countRoot 'Evidence/State/hardware-event-counts.json')
    Assert-CM ($countState.Whea -eq 2 -and $countState.Storage -eq 1 -and $countState.Thermal -eq 1) 'Hardware event counters add WHEA, storage and throttling events of this boot only'
    Update-CMHardwareEventCounts -Root $countRoot -Boot ([pscustomobject]@{ BootKey='NEXT'; BootUtc='2026-10-13T10:00:00Z' }) -Events @()
    Assert-CM ((Read-CMJson (Join-Path $countRoot 'Evidence/State/hardware-event-counts.json')).Whea -eq 0) 'Hardware event counters restart on a new boot'
    # Ntfs 147 latency that is really an S3 sleep (workstation, 2026-10-13: 00:03:12Z -> 05:03:36Z, LatencyMs 18018263).
    $sleepRoot=Join-Path $temp 'sleep-counts'
    $sleepBoot=[pscustomobject]@{ BootKey='BOOTS'; BootUtc='2026-10-07T23:53:00Z' }
    $ntfs147={ param($utc,$ms) [pscustomobject]@{ Provider='Microsoft-Windows-Ntfs'; Channel='Microsoft-Windows-Ntfs/Operational'; Level=3; EventId=147; Utc=$utc; Data=[pscustomobject]@{ LatencyMs=$ms; MaxLatencyMs=30000; VolumeName='E:' } } }
    $wake=[pscustomobject]@{ Provider='Microsoft-Windows-Power-Troubleshooter'; Channel='System'; Level=4; EventId=1; Utc='2026-10-13T05:03:38Z'; Data=[pscustomobject]@{ SleepTime='2026-10-13T00:03:12.1451258Z'; WakeTime='2026-10-13T05:03:36.8986281Z' } }
    $summaryOnly=[pscustomobject]@{ Provider='Microsoft-Windows-Ntfs'; Channel='Microsoft-Windows-Ntfs/Operational'; Level=3; EventId=149; Utc='2026-10-13T06:01:28Z'; Data=[pscustomobject]@{ HighLatencyCount=1; FailedWriteCount=0; FailedReadCount=0; BadClusterHotfixCount=0 } }
    $summaryFailed=[pscustomobject]@{ Provider='Microsoft-Windows-Ntfs'; Channel='Microsoft-Windows-Ntfs/Operational'; Level=3; EventId=149; Utc='2026-10-13T07:01:28Z'; Data=[pscustomobject]@{ HighLatencyCount=0; FailedWriteCount=0; FailedReadCount=2; BadClusterHotfixCount=0 } }
    Assert-CM ((Get-CMHardwareEventCategory $wake) -eq 'Sleep' -and (Get-CMHardwareEventCategory (& $ntfs147 '2026-10-13T05:03:40Z' 18018263)) -eq 'StorageLatency' -and $null -eq (Get-CMHardwareEventCategory $summaryOnly) -and (Get-CMHardwareEventCategory $summaryFailed) -eq 'Storage') 'Sleep, Ntfs 147 latency and Ntfs 149 failures are classified; a latency-only 149 summary is not counted twice'
    Update-CMHardwareEventCounts -Root $sleepRoot -Boot $sleepBoot -Events @((& $ntfs147 '2026-10-13T05:03:40Z' 18018263))
    $beforeWake=(Read-CMJson (Join-Path $sleepRoot 'Evidence/State/hardware-event-counts.json')).Storage
    Update-CMHardwareEventCounts -Root $sleepRoot -Boot $sleepBoot -Events @($wake, $summaryOnly)
    $afterWake=Read-CMJson (Join-Path $sleepRoot 'Evidence/State/hardware-event-counts.json')
    Assert-CM ($beforeWake -eq 1 -and $afterWake.Storage -eq 0 -and $afterWake.SleepInflatedLatency -eq 1) 'An Ntfs 147 latency explained by a sleep reported later is removed from StorageErrors'
    Update-CMHardwareEventCounts -Root $sleepRoot -Boot $sleepBoot -Events @((& $ntfs147 '2026-10-13T08:00:00Z' 45000), (& $ntfs147 '2026-10-13T05:04:40Z' (18018263+60000)), $summaryFailed)
    Assert-CM ((Read-CMJson (Join-Path $sleepRoot 'Evidence/State/hardware-event-counts.json')).Storage -eq 3) 'Real stalls stay counted, including one that continued 60 s past the wake-up'
    Write-CMJson (Join-Path $sleepRoot 'Evidence/State/hardware-event-counts.json') @{ BootKey='BOOTS'; Whea=0; Storage=7; Thermal=0 }
    Update-CMHardwareEventCounts -Root $sleepRoot -Boot $sleepBoot -Events @()
    Assert-CM ((Read-CMJson (Join-Path $sleepRoot 'Evidence/State/hardware-event-counts.json')).Storage -eq 0) 'A counter state from before sleep-aware counting is restarted instead of carrying inflated values'

    # Remote heartbeat receiver: pure state logic, then a real UDP loopback run of Scripts/Receive-Heartbeat.ps1.
    $receiverPath=Join-Path $root 'Scripts/Receive-Heartbeat.ps1'
    $receiverAst=[Management.Automation.Language.Parser]::ParseFile($receiverPath,[ref]$null,[ref]$null)
    foreach ($fn in @($receiverAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in @('ConvertFrom-CMHeartbeatPacket','Update-CMHeartbeatState','Test-CMHeartbeatSilence') },$false))) { . ([scriptblock]::Create($fn.Extent.Text)) }
    $syslogLine='<134>1 2026-10-13T10:00:00.000Z SRV1 CrashMonitor - - - {"SchemaVersion":3,"Type":"hb","Seq":7,"BootKey":"B1","Host":"SRV1"}'
    $parsedPacket=ConvertFrom-CMHeartbeatPacket $syslogLine
    Assert-CM ($parsedPacket.Host -eq 'SRV1' -and $parsedPacket.Type -eq 'hb' -and $parsedPacket.Seq -eq 7 -and $null -eq (ConvertFrom-CMHeartbeatPacket 'not a packet') -and $null -eq (ConvertFrom-CMHeartbeatPacket '{"x":1}')) 'Receiver parses syslog-framed CrashMonitor packets and ignores foreign traffic'
    $rxState=@{}; $t0=[datetime]'2026-10-13T10:00:00Z'
    $rx=@(Update-CMHeartbeatState $rxState $parsedPacket $t0)
    $rx+=@(Update-CMHeartbeatState $rxState ([pscustomobject]@{ Host='SRV1'; Type='telemetry'; BootKey='B1'; Utc='2026-10-13T10:00:01Z'; CpuTempC=91; Plus12V=11.2; Whea=3 }) $t0.AddSeconds(1))
    $rx+=@(Test-CMHeartbeatSilence $rxState $t0.AddSeconds(5) 10)
    Assert-CM ($rx.Count -eq 0) 'Receiver stays quiet while packets arrive within the silence threshold'
    $silence=@(Test-CMHeartbeatSilence $rxState $t0.AddSeconds(12) 10) + @(Test-CMHeartbeatSilence $rxState $t0.AddSeconds(20) 10)
    Assert-CM ($silence.Count -eq 1 -and $silence[0].Event -eq 'SILENCE' -and $silence[0].Detail -match 'CpuTempC=91' -and $silence[0].Detail -match 'Plus12V=11.2' -and $silence[0].Detail -match 'Whea=3') 'Receiver reports SILENCE once with the last readings before the host went quiet'
    $back=@(Update-CMHeartbeatState $rxState ([pscustomobject]@{ Host='SRV1'; Type='hb'; BootKey='B2' }) $t0.AddSeconds(90))
    Assert-CM ((@($back | ForEach-Object Event) -join ',') -eq 'RESUMED,REBOOT' -and $back[1].Detail -match 'B1 -> B2') 'Receiver reports RESUMED and REBOOT when packets return with a new BootKey'
    $udpPort=Get-Random -Minimum 50000 -Maximum 60000
    $rxDir=Join-Path $temp 'receiver'
    $receiver=Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$receiverPath`"",'-Port',$udpPort,'-OutputDirectory',"`"$rxDir`"",'-SilenceSeconds','2','-DurationSeconds','7','-BindAddress','127.0.0.1') -PassThru -WindowStyle Hidden
    try {
        Start-Sleep -Seconds 3
        $udpCfg=@{ EnableUdpHeartbeat=$true; UdpHeartbeatHost='127.0.0.1'; UdpHeartbeatPort=$udpPort }
        Send-CMUdpPacket -Config $udpCfg -Payload ([ordered]@{ SchemaVersion=3; Type='hb'; Seq=1; Utc=[datetime]::UtcNow.ToString('o'); BootKey='LOOP' })
        Send-CMUdpHeartbeat -Config $udpCfg -Row ([ordered]@{ Utc=[datetime]::UtcNow.ToString('o'); BootKey='LOOP'; CpuUsagePct=3 })
        [void]$receiver.WaitForExit(15000)
    } finally { if (-not $receiver.HasExited) { $receiver.Kill() } }
    $rxHost=[Environment]::MachineName -replace '[^A-Za-z0-9_.-]','_'
    $rxRows=@(Import-Csv (Join-Path $rxDir "heartbeat-$rxHost.csv") -Delimiter ';' -ErrorAction SilentlyContinue)
    $rxEvents=@(Import-Csv (Join-Path $rxDir 'heartbeat-events.csv') -Delimiter ';' -ErrorAction SilentlyContinue)
    Assert-CM ($rxRows.Count -eq 2 -and $rxRows[0].Type -eq 'hb' -and $rxRows[1].Type -eq 'telemetry' -and $rxRows[1].BootKey -eq 'LOOP' -and @($rxEvents | Where-Object Event -eq 'SILENCE').Count -eq 1) 'Monitor packets reach Receive-Heartbeat.ps1 over UDP loopback and silence is recorded'

    # Install.ps1 helpers: load only the function definitions via the AST; the installer itself never runs.
    $installAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Install.ps1'),[ref]$null,[ref]$null)
    $installFunctions=@($installAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] },$false))
    foreach ($fn in $installFunctions) { . ([scriptblock]::Create($fn.Extent.Text)) }
    Assert-CM ((@($installFunctions.Name) -join ',') -eq 'Assert-CMPackageManifest,Test-CMToolsChanged,Set-CMRootAcl,Register-CMAutoStartTask') 'Install.ps1 exposes testable helper functions'

    # Root ACL on a temporary tree; the owner keeps WRITE_DAC, so icacls /reset restores access for cleanup.
    $aclRoot=Join-Path $temp 'acl-root'
    [void][IO.Directory]::CreateDirectory((Join-Path $aclRoot 'Modules'))
    [IO.File]::WriteAllText((Join-Path $aclRoot 'Modules/Fixture.psm1'),'fixture')
    try {
        Set-CMRootAcl $aclRoot
        $sidOf={ param($rule) $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
        $rootAcl=Get-Acl -LiteralPath $aclRoot
        $rootRules=@($rootAcl.Access | ForEach-Object { '{0}={1}' -f (& $sidOf $_),$_.FileSystemRights } | Sort-Object)
        Assert-CM ($rootAcl.AreAccessRulesProtected -and ($rootRules -join ',') -eq 'S-1-5-18=FullControl,S-1-5-32-544=FullControl,S-1-5-32-545=ReadAndExecute, Synchronize') 'Install root ACL drops inheritance and grants only Administrators, SYSTEM and read-only Users'
        $writeRights=[Security.AccessControl.FileSystemRights]'WriteData,AppendData,WriteExtendedAttributes,WriteAttributes,Delete,ChangePermissions,TakeOwnership'
        $fileRules=@((Get-Acl -LiteralPath (Join-Path $aclRoot 'Modules/Fixture.psm1')).Access)
        $nonAdminWrite=@($fileRules | Where-Object { (& $sidOf $_) -notin @('S-1-5-18','S-1-5-32-544') -and ($_.FileSystemRights -band $writeRights) })
        Assert-CM ($fileRules.Count -eq 3 -and @($fileRules | Where-Object { -not $_.IsInherited }).Count -eq 0 -and $nonAdminWrite.Count -eq 0) 'Existing package files inherit the root ACL and are not writable by ordinary users'
    } finally { & icacls.exe $aclRoot /reset /T /C /Q | Out-Null }

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
        foreach ($name in $taskMocks) { Remove-Item "Function:\$name" -ErrorAction SilentlyContinue }
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
