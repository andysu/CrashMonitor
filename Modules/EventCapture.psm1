#Requires -Version 5.1
Import-Module (Join-Path $PSScriptRoot 'Common.psm1')

function ConvertFrom-CMEventXml {
    param([string]$Xml, [string]$Message = '')
    [xml]$doc = $Xml
    $ns = New-Object Xml.XmlNamespaceManager($doc.NameTable)
    $ns.AddNamespace('e','http://schemas.microsoft.com/win/2004/08/events/event')
    $sys = $doc.SelectSingleNode('/e:Event/e:System',$ns)
    $data = [ordered]@{}
    $index = 0
    foreach ($node in $doc.SelectNodes('/e:Event/e:EventData/e:Data',$ns)) {
        $name = $node.GetAttribute('Name')
        if (-not $name) { $name = "Data$index" }
        $data[$name] = $node.InnerText
        $index++
    }
    return [pscustomobject]@{
        Utc=$sys.TimeCreated.GetAttribute('SystemTime'); Channel=[string]$sys.Channel
        RecordId=[long]$sys.EventRecordID; EventId=[int]$sys.SelectSingleNode('e:EventID',$ns).InnerText
        Provider=$sys.Provider.GetAttribute('Name'); Level=[int]$sys.Level
        Computer=[string]$sys.Computer; Data=$data; Message=$Message
    }
}

function Get-CMEventXPath {
    param([long]$AfterRecord, [long]$ThroughRecord, [datetime]$SinceUtc, [bool]$Initial, [string]$Channel, [int]$MaxLevel = 4, [string]$EventDataFilter = '')
    $bounds = "EventRecordID > $AfterRecord and EventRecordID <= $ThroughRecord"
    if ($Initial) { $bounds = "TimeCreated[@SystemTime >= '$($SinceUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))'] and EventRecordID <= $ThroughRecord" }
    if ($Channel -eq 'System') {
        $filter = "(Level=1 or Level=2 or EventID=1074 or EventID=6005 or EventID=6006 or EventID=6008 or EventID=12 or EventID=13 or EventID=37 or EventID=129 or EventID=153 or EventID=157 or EventID=219 or EventID=2004 or Provider[@Name='Microsoft-Windows-WHEA-Logger'] or Provider[@Name='Microsoft-Windows-Kernel-Power'] or Provider[@Name='Microsoft-Windows-Kernel-Boot'] or Provider[@Name='Microsoft-Windows-Time-Service'] or Provider[@Name='Microsoft-Windows-WindowsUpdateClient'] or Provider[@Name='volmgr'])"
        # Warning/information-level hardware events, bound to their provider so other sources reusing the ID are not captured:
        # disk 51 paging I/O error; Ntfs 50 delayed write lost, 98 volume check, 140 flush failed; Display 4101 GPU TDR; Kernel-General 1 clock change;
        # Power-Troubleshooter 1 sleep/wake times (explains Ntfs 147 latencies that include a sleep).
        # The event log rejects an XPath with more than ~22 OR terms, so these go into a second Select of one QueryList:
        # Windows returns the union in record order, which keeps the RecordId cursor valid.
        $hardware = "((Provider[@Name='disk'] and EventID=51) or (Provider[@Name='Ntfs' or @Name='Microsoft-Windows-Ntfs'] and (EventID=50 or EventID=98 or EventID=140)) or (Provider[@Name='Display'] and EventID=4101) or (Provider[@Name='Microsoft-Windows-Kernel-General'] and EventID=1) or (Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1))"
        $selects = @("*[System[$bounds and $filter]]", "*[System[$bounds and $hardware]]") | ForEach-Object { "<Select Path='System'>$([Security.SecurityElement]::Escape($_))</Select>" }
        return "<QueryList><Query Id='0' Path='System'>$($selects -join '')</Query></QueryList>"
    } elseif ($Channel -eq 'Application') { $filter = '(Level=1 or Level=2 or EventID=1001 or EventID=2004 or Provider[@Name=''Microsoft-Windows-Resource-Exhaustion-Detector''])' }
    else { $filter = '(' + ((1..[math]::Max(1,[math]::Min(4,$MaxLevel)) | ForEach-Object { "Level=$_" }) -join ' or ') + ')' }
    if ($EventDataFilter) { return "*[System[$bounds and $filter] and EventData[$EventDataFilter]]" }
    return "*[System[$bounds and $filter]]"
}

function Get-CMEventChannels {
    # System and Application are required; optional and hardware channels are skipped when absent on this Windows build.
    param([hashtable]$Config)
    $channels = New-Object Collections.Generic.List[object]
    $seen = @{}
    foreach ($name in @('System','Application') + @($Config.OptionalEventChannels)) {
        if ($name -and -not $seen.ContainsKey($name)) { $seen[$name]=$true; $channels.Add([pscustomobject]@{ Name=[string]$name; MaxLevel=4; EventDataFilter='' }) }
    }
    foreach ($entry in @(Get-CMValue $Config 'HardwareEventChannels' @())) {
        $name = [string](Get-CMValue $entry 'Name')
        if (-not $name -or $seen.ContainsKey($name)) { continue }
        $seen[$name]=$true
        $channels.Add([pscustomobject]@{ Name=$name; MaxLevel=[int](Get-CMValue $entry 'MaxLevel' 4); EventDataFilter=[string](Get-CMValue $entry 'EventDataFilter' '') })
    }
    return $channels.ToArray()
}

function Save-CMEvent {
    param([string]$Root, [string]$Xml, [string]$Message = '')
    $ev = ConvertFrom-CMEventXml -Xml $Xml -Message $Message
    $channelDir = $ev.Channel -replace '[^a-zA-Z0-9_-]','_'
    $stamp = [datetime]::Parse($ev.Utc).ToUniversalTime().Ticks
    $path = Join-Path $Root "Evidence/Events/$channelDir/$($ev.RecordId)-$stamp.xml"
    if (-not (Test-Path -LiteralPath $path)) {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        # Write to a temporary file: a torn write must not count as captured evidence.
        $temp = "$path.tmp"
        $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($Xml)
        $stream=[IO.File]::Open($temp,'Create','Write','None')
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        [IO.File]::Move($temp,$path)
        Add-CMText -Path (Join-Path $Root 'Evidence/Logs/events.jsonl') -Text ($ev | ConvertTo-Json -Depth 12 -Compress)
    }
    return $ev
}

function Receive-CMEvents {
    param([string]$Root, [hashtable]$Config, $Boot)
    $all = New-Object Collections.Generic.List[object]
    foreach ($source in @(Get-CMEventChannels $Config)) {
        $channel = $source.Name
        $safe = $channel -replace '[^a-zA-Z0-9_-]','_'
        $checkpointPath = Join-Path $Root "Evidence/State/cursor-$safe.json"
        try {
            $latest = Get-WinEvent -LogName $channel -MaxEvents 1 -ErrorAction Stop
            $oldest = Get-WinEvent -LogName $channel -MaxEvents 1 -Oldest -ErrorAction Stop
        } catch {
            if ($_.Exception.Message -like '*No events were found*' -or (($info = Get-WinEvent -ListLog $channel -ErrorAction SilentlyContinue) -and $info.RecordCount -eq 0)) {
                continue
            }
            if ($channel -in @('System','Application')) { throw "Cannot read required channel ${channel}: $_" }
            continue
        }
        $cursor = $null
        try { $cursor = Read-CMJson $checkpointPath } catch { Write-CMLog $Root 'events' "Invalid checkpoint for $channel; using bounded backfill: $_" 'ERROR' }
        $initial = ($null -eq $cursor)
        $after = 0L
        if ($cursor) {
            $after = [long]$cursor.RecordId
            # A cleared/recreated log can exceed the old cursor before we notice.
            # Validate its last event timestamp, not just the latest numeric ID.
            try {
                $anchor = Get-WinEvent -LogName $channel -FilterXPath "*[System[EventRecordID=$after]]" -MaxEvents 1 -ErrorAction Stop
                if ($anchor.TimeCreated.ToUniversalTime().ToString('o') -ne $cursor.AnchorUtc) { $initial = $true }
            } catch { $initial = $true }
            if ($initial) { Write-CMLog $Root 'events' "Log reset/rollover or missing cursor anchor in $channel; backfilling available history. Previous record=$after, oldest=$($oldest.RecordId)." 'WARNING'; $after=0L }
        }
        $since = [datetime]::UtcNow.AddHours(-[double]$Config.EventBackfillHours)
        $bootStart = [datetime]::Parse($Boot.BootUtc).ToUniversalTime().AddMinutes(-30)
        if ($bootStart -lt $since) { $since = $bootStart }
        $query = Get-CMEventXPath -AfterRecord $after -ThroughRecord $latest.RecordId -SinceUtc $since -Initial $initial -Channel $channel -MaxLevel $source.MaxLevel -EventDataFilter $source.EventDataFilter
        $q = New-Object Diagnostics.Eventing.Reader.EventLogQuery($channel, [Diagnostics.Eventing.Reader.PathType]::LogName, $query)
        $reader = New-Object Diagnostics.Eventing.Reader.EventLogReader($q)
        $count = 0; $exhausted = $false; $lastUtc = $null
        try {
            while ($count -lt [int]$Config.EventBatchSize) {
                $record = $reader.ReadEvent()
                if ($null -eq $record) { $exhausted=$true; break }
                try {
                    $message = ''
                    try { $message = $record.FormatDescription() } catch { }
                    $ev = Save-CMEvent -Root $Root -Xml $record.ToXml() -Message $message
                    $all.Add($ev)
                    $after = [long]$record.RecordId
                    $lastUtc = $record.TimeCreated.ToUniversalTime().ToString('o')
                    $count++
                } finally { $record.Dispose() }
            }
        } finally { $reader.Dispose() }
        if ($exhausted) { $after=[long]$latest.RecordId; $lastUtc=$latest.TimeCreated.ToUniversalTime().ToString('o') }
        if ($null -ne $lastUtc) { Write-CMJson -Path $checkpointPath -Value @{ RecordId=$after; AnchorUtc=$lastUtc; Channel=$channel; UpdatedUtc=[datetime]::UtcNow.ToString('o') } }
    }
    return $all.ToArray()
}

function Get-CMHardwareEventCategory {
    # Groups captured events for the counters sent in the remote telemetry packet; $null = not a hardware signal.
    param($Record)
    $provider = [string]$Record.Provider; $channel = [string]$Record.Channel; $level = [int]$Record.Level
    if ($provider -eq 'Microsoft-Windows-WHEA-Logger' -or $channel -eq 'Microsoft-Windows-Kernel-WHEA/Errors') { return 'Whea' }
    if ($channel -eq 'Microsoft-Windows-Kernel-Power/Thermal-Operational' -or ($provider -eq 'Microsoft-Windows-Kernel-Processor-Power' -and [int]$Record.EventId -eq 37)) { return 'Thermal' }
    $id = [int]$Record.EventId
    if ($provider -eq 'Microsoft-Windows-Power-Troubleshooter' -and $id -eq 1) { return 'Sleep' }
    if ($provider -eq 'Microsoft-Windows-Ntfs' -and $id -eq 147) { return 'StorageLatency' }
    if ($provider -eq 'Microsoft-Windows-Ntfs' -and $id -eq 149) {
        # Hourly summary: its high-latency count repeats the 147 events, so only real failures count.
        $failures = 0
        foreach ($name in 'FailedWriteCount','FailedReadCount','BadClusterHotfixCount') { $failures += [int](Get-CMValue $Record.Data $name 0) }
        if ($failures -gt 0) { return 'Storage' }
        return $null
    }
    if ($channel -eq 'Microsoft-Windows-Storage-ClassPnP/Operational') { return 'Storage' }
    if ($provider -in @('disk','stornvme','storahci','storport','Ntfs','Microsoft-Windows-Ntfs') -and $level -ge 1 -and $level -le 3) { return 'Storage' }
    return $null
}

function Test-CMSleepInflatedLatency {
    # Ntfs 147 measures wall-clock time, so an I/O issued just before sleep "takes" the whole sleep
    # (18 018 263 ms over a 5 h S3 sleep on the workstation). Without the sleep it would be under the threshold.
    param($Latency, [object[]]$Sleeps)
    $end = ConvertTo-CMUtcDate $Latency.Utc
    $start = $end.AddMilliseconds(-[double]$Latency.LatencyMs)
    $sleptMs = 0.0
    foreach ($sleep in @($Sleeps)) {
        $from = ConvertTo-CMUtcDate $sleep.SleepUtc; $to = ConvertTo-CMUtcDate $sleep.WakeUtc
        $overlapStart = if ($from -gt $start) { $from } else { $start }
        $overlapEnd = if ($to -lt $end) { $to } else { $end }
        if ($overlapEnd -gt $overlapStart) { $sleptMs += ($overlapEnd - $overlapStart).TotalMilliseconds }
    }
    return ($sleptMs -gt 0 -and ([double]$Latency.LatencyMs - $sleptMs) -lt [double]$Latency.ThresholdMs)
}

function Update-CMHardwareEventCounts {
    # Per-boot counters kept in State so the telemetry worker can include them in every remote packet.
    # Sleep intervals (Power-Troubleshooter 1) can arrive after the Ntfs 147 events they explain,
    # so latency events are kept and the Storage count is recomputed against all known sleeps.
    param([string]$Root, $Boot, [object[]]$Events)
    $path = Join-Path $Root 'Evidence/State/hardware-event-counts.json'
    $state = $null
    try { $state = Read-CMJson $path } catch { }
    # A state file written before sleep-aware counting (no StorageDirect) cannot be recomputed: start the counters again.
    $reset = (-not $state -or $state.BootKey -ne $Boot.BootKey -or $null -eq (Get-CMValue $state 'StorageDirect'))
    $whea = 0; $thermal = 0; $direct = 0
    $latencies = New-Object Collections.Generic.List[object]; $sleeps = New-Object Collections.Generic.List[object]
    if (-not $reset) {
        $whea = [int]$state.Whea; $thermal = [int]$state.Thermal; $direct = [int]$state.StorageDirect
        foreach ($item in @(Get-CMValue $state 'LatencyEvents' @())) { if ($item) { $latencies.Add($item) } }
        foreach ($item in @(Get-CMValue $state 'Sleeps' @())) { if ($item) { $sleeps.Add($item) } }
    }
    $bootUtc = [datetime]::Parse($Boot.BootUtc).ToUniversalTime()
    $added = 0
    foreach ($ev in @($Events)) {
        $category = Get-CMHardwareEventCategory $ev
        if (-not $category) { continue }
        # Backfilled history from before this boot belongs to earlier boots.
        if ((ConvertTo-CMUtcDate $ev.Utc) -lt $bootUtc) { continue }
        switch ($category) {
            'Whea' { $whea++ }
            'Thermal' { $thermal++ }
            'Storage' { $direct++ }
            'Sleep' { $sleeps.Add([pscustomobject]@{ SleepUtc=(ConvertTo-CMUtcDate $ev.Data.SleepTime).ToString('o'); WakeUtc=(ConvertTo-CMUtcDate $ev.Data.WakeTime).ToString('o') }) }
            'StorageLatency' { $latencies.Add([pscustomobject]@{ Utc=(ConvertTo-CMUtcDate $ev.Utc).ToString('o'); LatencyMs=[double](Get-CMValue $ev.Data 'LatencyMs' 0); ThresholdMs=[double](Get-CMValue $ev.Data 'MaxLatencyMs' 30000); Volume=[string](Get-CMValue $ev.Data 'VolumeName' '') }) }
        }
        $added++
    }
    if (-not ($added -or $reset)) { return }
    $keptLatencies = @($latencies | Select-Object -Last 500); $keptSleeps = @($sleeps | Select-Object -Last 200)
    $inflated = @($keptLatencies | Where-Object { Test-CMSleepInflatedLatency $_ $keptSleeps }).Count
    Write-CMJson $path @{ BootKey=$Boot.BootKey; Whea=$whea; Storage=($direct + $keptLatencies.Count - $inflated); Thermal=$thermal; StorageDirect=$direct; SleepInflatedLatency=$inflated; LatencyEvents=$keptLatencies; Sleeps=$keptSleeps; UpdatedUtc=[datetime]::UtcNow.ToString('o') }
}

function Get-CMBootEvents {
    param([string]$Root, $Boot)
    # Read the actual boot interval directly; not a historic event near the previous heartbeat.
    $start = [datetime]::Parse($Boot.BootUtc).ToUniversalTime().AddHours(-24)
    $end = [datetime]::Parse($Boot.BootUtc).ToUniversalTime().AddMinutes(5)
    $result = New-Object Collections.Generic.List[object]
    foreach ($channel in @('System','Application')) {
        $from=$start.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        $through=$end.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        $query="*[System[TimeCreated[@SystemTime >= '$from' and @SystemTime <= '$through'] and (EventID=41 or EventID=6008 or EventID=1001 or EventID=1074 or EventID=6006 or EventID=12 or EventID=13 or EventID=46 or EventID=161 or Provider[@Name='Microsoft-Windows-WHEA-Logger'] or Provider[@Name='disk'] or Provider[@Name='stornvme'] or Provider[@Name='storahci'] or Provider[@Name='storport'] or (Provider[@Name='Ntfs' or @Name='Microsoft-Windows-Ntfs'] and (EventID=50 or EventID=140)) or (Provider[@Name='Display'] and EventID=4101))]]"
        try {
            foreach ($ev in @(Get-WinEvent -LogName $channel -FilterXPath $query -MaxEvents 2000 -ErrorAction Stop)) {
                $message=''; try { $message=$ev.Message } catch { }
                $result.Add((Save-CMEvent $Root $ev.ToXml() $message))
            }
        } catch {
            if ($_.FullyQualifiedErrorId -notmatch 'NoMatchingEventsFound') { throw }
        }
    }
    return $result.ToArray()
}

Export-ModuleMember -Function ConvertFrom-CMEventXml, Get-CMEventXPath, Get-CMEventChannels, Save-CMEvent, Receive-CMEvents, Get-CMHardwareEventCategory, Update-CMHardwareEventCounts, Get-CMBootEvents
