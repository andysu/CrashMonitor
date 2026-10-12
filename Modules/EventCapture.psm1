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
    param([long]$AfterRecord, [long]$ThroughRecord, [datetime]$SinceUtc, [bool]$Initial, [string]$Channel)
    $bounds = "EventRecordID > $AfterRecord and EventRecordID <= $ThroughRecord"
    if ($Initial) { $bounds = "TimeCreated[@SystemTime >= '$($SinceUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))'] and EventRecordID <= $ThroughRecord" }
    if ($Channel -eq 'System') {
        $filter = "(Level=1 or Level=2 or EventID=1074 or EventID=6005 or EventID=6006 or EventID=6008 or EventID=12 or EventID=13 or EventID=129 or EventID=153 or EventID=157 or Provider[@Name='Microsoft-Windows-WHEA-Logger'] or Provider[@Name='Microsoft-Windows-Kernel-Power'] or Provider[@Name='Microsoft-Windows-Time-Service'] or Provider[@Name='Microsoft-Windows-WindowsUpdateClient'] or Provider[@Name='volmgr'])"
    } elseif ($Channel -eq 'Application') { $filter = '(Level=1 or Level=2 or EventID=1001)' }
    else { $filter = '(Level=1 or Level=2 or Level=3)' }
    return "*[System[$bounds and $filter]]"
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
    foreach ($channel in @('System','Application') + @($Config.OptionalEventChannels)) {
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
        $query = Get-CMEventXPath -AfterRecord $after -ThroughRecord $latest.RecordId -SinceUtc $since -Initial $initial -Channel $channel
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

function Get-CMBootEvents {
    param([string]$Root, $Boot)
    # Read the actual boot interval directly; not a historic event near the previous heartbeat.
    $start = [datetime]::Parse($Boot.BootUtc).ToUniversalTime().AddHours(-24)
    $end = [datetime]::Parse($Boot.BootUtc).ToUniversalTime().AddMinutes(5)
    $result = New-Object Collections.Generic.List[object]
    foreach ($channel in @('System','Application')) {
        $from=$start.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        $through=$end.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        $query="*[System[TimeCreated[@SystemTime >= '$from' and @SystemTime <= '$through'] and (EventID=41 or EventID=6008 or EventID=1001 or EventID=1074 or EventID=6006 or EventID=12 or EventID=13 or EventID=46 or EventID=161 or Provider[@Name='Microsoft-Windows-WHEA-Logger'] or Provider[@Name='disk'] or Provider[@Name='stornvme'] or Provider[@Name='storahci'] or Provider[@Name='storport'])]]"
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

Export-ModuleMember -Function ConvertFrom-CMEventXml, Get-CMEventXPath, Save-CMEvent, Receive-CMEvents, Get-CMBootEvents
