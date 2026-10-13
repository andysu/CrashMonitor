#Requires -Version 5.1
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)

function Get-CMValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    } elseif ($Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function ConvertTo-CMUtcDate {
    # PowerShell 7 ConvertFrom-Json already returns ISO dates as DateTime, 5.1 returns strings; accept both, culture-independent.
    param($Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    return [datetime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
}

function Write-CMJson {
    param([string]$Path, $Value)
    $dir = Split-Path -Parent $Path
    [void][IO.Directory]::CreateDirectory($dir)
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $bytes = $script:Utf8.GetBytes(($Value | ConvertTo-Json -Depth 24))
        $stream = [IO.File]::Open($temp, 'CreateNew', 'Write', 'None')
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        # File.Replace fails with a sharing violation while another process has the file open without delete
        # sharing (an antivirus scan, an external tool); such holds are brief, so retry before giving up.
        for ($attempt = 1; ; $attempt++) {
            try {
                if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
                else { [IO.File]::Move($temp, $Path) }
                break
            } catch {
                $ex = $_.Exception
                if ($ex.InnerException) { $ex = $ex.InnerException }
                if ($attempt -ge 6 -or -not ($ex -is [IO.IOException] -or $ex -is [UnauthorizedAccessException])) { throw }
                Start-Sleep -Milliseconds (50 * $attempt)
            }
        }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

# Readers allow writers to replace the file underneath them; File.ReadAllText (FileShare.Read) made the
# supervisor's reads of worker-*.json break the workers' Write-CMJson.
$script:JsonReadShare = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete

function Read-CMJson {
    param([string]$Path, $Default = $null)
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    # During File.Replace the target is briefly delete-pending and cannot be opened; retry for a moment.
    for ($attempt = 1; ; $attempt++) {
        try {
            $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $script:JsonReadShare)
            break
        } catch {
            $ex = $_.Exception
            if ($ex.InnerException) { $ex = $ex.InnerException }
            if ($ex -is [IO.FileNotFoundException]) { return $Default }
            if ($attempt -ge 6 -or -not ($ex -is [IO.IOException] -or $ex -is [UnauthorizedAccessException])) { throw }
            Start-Sleep -Milliseconds (20 * $attempt)
        }
    }
    try { $reader = New-Object IO.StreamReader($stream, $script:Utf8, $true); $text = $reader.ReadToEnd() } finally { $stream.Dispose() }
    # Corrupt checkpoints must be reported by the caller, never silently advanced.
    return ($text | ConvertFrom-Json -ErrorAction Stop)
}

function Add-CMText {
    param([string]$Path, [string]$Text)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    $bytes = $script:Utf8.GetBytes($Text + [Environment]::NewLine)
    $stream = [IO.File]::Open($Path, 'Append', 'Write', 'Read')
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}

function Write-CMLog {
    param([string]$Root, [string]$Role, [string]$Message, [string]$Level = 'INFO')
    Add-CMText -Path (Join-Path $Root "Evidence/Logs/$Role.log") -Text "[$([datetime]::UtcNow.ToString('o'))] [$Level] $Message"
}

function Set-CMProcessPriority {
    # Scheduled tasks start at BelowNormal (base priority 6) and children inherit it, so under full CPU load the
    # heartbeat slipped from 2 s to 4.2 s. Returns $true when the priority class was applied.
    param([Diagnostics.Process]$Process, [Diagnostics.ProcessPriorityClass]$Priority)
    try { $Process.PriorityClass = $Priority; return $true } catch { return $false }
}

function Send-CMUdpPacket {
    # Remote evidence survives a power loss that local disks may not. RFC 5424 syslog framing lets any syslog
    # collector (router, NAS) store the packet; Scripts/Receive-Heartbeat.ps1 reads the JSON body.
    param([hashtable]$Config, [System.Collections.IDictionary]$Payload)
    if (-not $Config -or -not (Get-CMValue $Config 'EnableUdpHeartbeat' $false) -or -not (Get-CMValue $Config 'UdpHeartbeatHost')) { return }
    try {
        $port = 514
        if ([int](Get-CMValue $Config 'UdpHeartbeatPort' 0) -gt 0) { $port = [int]$Config.UdpHeartbeatPort }
        $hostName = [Environment]::MachineName
        $Payload['Host'] = $hostName
        # <134> = facility local0, severity informational.
        $message = "<134>1 $([datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')) $hostName CrashMonitor - - - $(ConvertTo-Json -InputObject $Payload -Compress)"
        $bytes = [Text.Encoding]::UTF8.GetBytes($message)
        $client = New-Object Net.Sockets.UdpClient
        try { [void]$client.Send($bytes, $bytes.Length, [string]$Config.UdpHeartbeatHost, $port) } finally { $client.Dispose() }
    } catch { }
}

function Invoke-CMFileLock {
    param([string]$Path, [scriptblock]$Action)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $key=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Path).ToUpperInvariant())))).Replace('-','') }
    finally { $sha.Dispose() }
    $prefix=''
    if ($env:OS -eq 'Windows_NT') { $prefix='Global\' }
    $mutex=New-Object Threading.Mutex($false,($prefix+'CMFile_'+$key))
    $owned=$false
    try {
        try { $owned=$mutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $owned=$true }
        if (-not $owned) { throw "File lock timeout: $Path" }
        & $Action
    } finally { if ($owned) { $mutex.ReleaseMutex() };$mutex.Dispose() }
}

function Write-CMCsv {
    param([string]$Path, [string[]]$Columns, [System.Collections.IDictionary]$Row)
    Invoke-CMFileLock $Path {
    $encode = {
        param($v)
        if ($null -eq $v) { $s = '' }
        elseif ($v -is [IFormattable]) { $s = $v.ToString($null, [Globalization.CultureInfo]::InvariantCulture) }
        else { $s = [string]$v }
        return '"' + $s.Replace('"', '""') + '"'
    }
    $header = (@($Columns | ForEach-Object { & $encode $_ }) -join ';')
    if (Test-Path -LiteralPath $Path) {
        $reader = [IO.File]::OpenText($Path)
        try { $existing = $reader.ReadLine() } finally { $reader.Dispose() }
        if ($existing -ne $header) { throw "CSV schema mismatch: $Path" }
    } else { Add-CMText -Path $Path -Text $header }
    Add-CMText -Path $Path -Text (@($Columns | ForEach-Object { & $encode $Row[$_] }) -join ';')
    }
}

function Get-CMConfig {
    param([string]$Root, [string]$CodeRoot)
    $defaults = Get-Content -LiteralPath (Join-Path $CodeRoot 'Config/defaults-v2.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $config = @{}
    foreach ($p in $defaults.PSObject.Properties) { $config[$p.Name] = $p.Value }
    $path = Join-Path $Root 'Config/config.json'
    if (Test-Path -LiteralPath $path) {
        $custom = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        foreach ($p in $custom.PSObject.Properties) { $config[$p.Name] = $p.Value }
    }
    $config.RootPath = $Root
    foreach ($name in @('SampleIntervalSeconds','HeartbeatIntervalSeconds','EventPollSeconds','EventBackfillHours','EventBatchSize','WorkerStallSeconds','MaxLogSizeMB','MaxEventXmlFiles','MinFreeSpaceMB','MaxIncidents','MaxEvidenceMB')) {
        if ([double]$config[$name] -le 0) { throw "Configuration $name must be positive." }
    }
    return $config
}

function Get-CMBootInfo {
    $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 5 -ErrorAction Stop
    $bootUtc = $os.LastBootUpTime.ToUniversalTime()
    $identity = 'CIM:' + $bootUtc.ToString('o')
    try {
        $ev = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-Kernel-General'; Id=12 } -MaxEvents 1 -ErrorAction Stop
        # Event creation time is stable across subsequent wall-clock adjustments.
        $bootUtc = $ev.TimeCreated.ToUniversalTime()
        $identity = 'Event12:' + $ev.RecordId + ':' + $bootUtc.ToString('o')
    } catch { }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity)))).Replace('-','').Substring(0,24) }
    finally { $sha.Dispose() }
    return [pscustomobject]@{ BootKey=$key; BootUtc=$bootUtc.ToString('o'); CimBootUtc=$os.LastBootUpTime.ToUniversalTime().ToString('o') }
}

function Get-CMRestartClassification {
    param([object[]]$Events, [datetime]$BootUtc, [Nullable[datetime]]$PreviousBootUtc)
    $current = @($Events | Where-Object {
        $t = [datetime]::Parse($_.Utc).ToUniversalTime()
        $t -ge $BootUtc.AddSeconds(-10) -and $t -le $BootUtc.AddMinutes(5)
    })
    $kp = @($current | Where-Object { $_.Provider -eq 'Microsoft-Windows-Kernel-Power' -and $_.EventId -eq 41 })
    $bug = @($current | Where-Object { $_.Provider -match 'WER-SystemErrorReporting|BugCheck' -and $_.EventId -eq 1001 })
    $dirty = @($current | Where-Object { $_.Provider -eq 'EventLog' -and $_.EventId -eq 6008 })
    $code = 0L
    $powerButtonTimestamp = 0L
    $longPowerButton = 'false'
    $sleepInProgress = 0
    if ($kp.Count) {
        [void][long]::TryParse([string](Get-CMValue $kp[-1].Data 'BugcheckCode' '0'), [ref]$code)
        [void][long]::TryParse([string](Get-CMValue $kp[-1].Data 'PowerButtonTimestamp' '0'), [ref]$powerButtonTimestamp)
        $longPowerButton = [string](Get-CMValue $kp[-1].Data 'LongPowerButtonPressDetected' 'false')
        [void][int]::TryParse([string](Get-CMValue $kp[-1].Data 'SleepInProgress' '0'), [ref]$sleepInProgress)
    }
    if ($code -ne 0 -or $bug.Count) {
        return [pscustomobject]@{
            Type='Bugcheck'
            BugcheckCode=$code
            PowerButtonTimestamp=$powerButtonTimestamp
            LongPowerButtonPressDetected=$longPowerButton
            SleepInProgress=$sleepInProgress
            Explanation='Windows recorded a stop error. Inspect EventData and the memory dump; the faulty component is not identified here.'
        }
    }
    if ($kp.Count -or $dirty.Count) {
        $detail = 'Unclean shutdown confirmed. Power loss, hardware reset, watchdog, hang or an unrecorded bugcheck remain possible.'
        if ($longPowerButton -eq 'true' -or $powerButtonTimestamp -gt 0) {
            $detail = "Unclean shutdown triggered by hardware power button (LongPowerButtonPressDetected=$longPowerButton, PowerButtonTimestamp=$powerButtonTimestamp)."
        } elseif ($sleepInProgress -gt 0) {
            $detail = "Unclean shutdown occurred while sleep/hibernation transition was in progress (SleepInProgress=$sleepInProgress)."
        }
        return [pscustomobject]@{
            Type='UnexpectedReset'
            BugcheckCode=$code
            PowerButtonTimestamp=$powerButtonTimestamp
            LongPowerButtonPressDetected=$longPowerButton
            SleepInProgress=$sleepInProgress
            Explanation=$detail
        }
    }
    $lower = $BootUtc.AddMinutes(-30)
    if ($null -ne $PreviousBootUtc -and $PreviousBootUtc -gt $lower) { $lower = [datetime]$PreviousBootUtc }
    $planned = @($Events | Where-Object {
        $_.Provider -eq 'User32' -and $_.EventId -eq 1074 -and ([datetime]::Parse($_.Utc).ToUniversalTime()) -ge $lower -and ([datetime]::Parse($_.Utc).ToUniversalTime()) -lt $BootUtc
    })
    if ($planned.Count) {
        return [pscustomobject]@{
            Type='RequestedRestart'
            BugcheckCode=$null
            PowerButtonTimestamp=0L
            LongPowerButtonPressDetected='false'
            SleepInProgress=0
            Explanation='User32 recorded a shutdown/restart request. Inspect its process, account and reason; this does not establish whether every shutdown stage completed.'
        }
    }
    # A complete clean shutdown of the previous session, however long the machine then stayed off: a User32 1074
    # request followed by the event log (6006) or the kernel (Kernel-General 13) stopping, with no OS start in between.
    # Server, 2026-10-12 21:30 UTC: powered off from Settings and started 7 h later; this used to fall through to Unknown.
    # Unclean evidence (41/6008) and bugchecks are handled above and always take precedence.
    $previousStart = [datetime]::MinValue
    foreach ($ev in @($Events | Where-Object { $_.Provider -eq 'Microsoft-Windows-Kernel-General' -and [int]$_.EventId -eq 12 })) {
        $t = ConvertTo-CMUtcDate $ev.Utc
        if ($t -lt $BootUtc.AddSeconds(-10) -and $t -gt $previousStart) { $previousStart = $t }
    }
    if ($null -ne $PreviousBootUtc) { $prev = ([datetime]$PreviousBootUtc).ToUniversalTime(); if ($prev -lt $BootUtc.AddSeconds(-10) -and $prev -gt $previousStart) { $previousStart = $prev } }
    $request = @($Events | Where-Object { $_.Provider -eq 'User32' -and [int]$_.EventId -eq 1074 } | Where-Object { $t = ConvertTo-CMUtcDate $_.Utc; $t -gt $previousStart -and $t -lt $BootUtc } | Sort-Object { ConvertTo-CMUtcDate $_.Utc }) | Select-Object -Last 1
    if ($request) {
        $requestUtc = ConvertTo-CMUtcDate $request.Utc
        $stops = @($Events | Where-Object { ($_.Provider -eq 'EventLog' -and [int]$_.EventId -eq 6006) -or ($_.Provider -eq 'Microsoft-Windows-Kernel-General' -and [int]$_.EventId -eq 13) } | ForEach-Object { ConvertTo-CMUtcDate $_.Utc } | Where-Object { $_ -ge $requestUtc -and $_ -lt $BootUtc } | Sort-Object)
        if ($stops.Count) {
            $osStop = $stops[-1]
            # User32 1074: param1 process, param3 reason, param5 shutdown type, param7 account (texts are in the OS language).
            $data = $request.Data
            $explanation = "Clean shutdown of the previous session: requested by $(Get-CMValue $data 'param1' '?') (account $(Get-CMValue $data 'param7' '?')), type '$(Get-CMValue $data 'param5' '?')', reason '$(Get-CMValue $data 'param3' '?')'. Windows stopped at $($osStop.ToString('o')) and started again $([math]::Round(($BootUtc - $osStop).TotalMinutes, 1)) min later; no unexpected-shutdown evidence."
            return [pscustomobject]@{
                Type='RequestedShutdown'
                BugcheckCode=$null
                PowerButtonTimestamp=0L
                LongPowerButtonPressDetected='false'
                SleepInProgress=0
                Explanation=$explanation
            }
        }
    }
    return [pscustomobject]@{
        Type='Unknown'
        BugcheckCode=$null
        PowerButtonTimestamp=0L
        LongPowerButtonPressDetected='false'
        SleepInProgress=0
        Explanation='Insufficient boot evidence. A heartbeat gap alone is not proof of a crash.'
    }
}

function Limit-CMCsvLog {
    param([string]$Path, [int]$RetentionHours = 4, [int]$MinKeepLines = 300)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $cutoff = [DateTime]::UtcNow.AddHours(-$RetentionHours)
    Invoke-CMFileLock $Path {
        $lines = @([IO.File]::ReadAllLines($Path))
        if ($lines.Length -le ($MinKeepLines + 1)) { return }
        $header = $lines[0]
        $headerCols = $header.Split(';')
        $utcCol = -1
        for ($i = 0; $i -lt $headerCols.Length; $i++) {
            if ($headerCols[$i].Trim('"') -eq 'Utc') { $utcCol = $i; break }
        }
        if ($utcCol -lt 0) { $utcCol = 0 }

        $splitIdx = -1
        for ($i = 1; $i -lt ($lines.Length - $MinKeepLines); $i++) {
            $cols = $lines[$i].Split(';')
            if ($cols.Length -gt $utcCol) {
                $ts = $cols[$utcCol].Trim('"')
                $dto = [DateTimeOffset]::MinValue
                if ([DateTimeOffset]::TryParse($ts, [ref]$dto)) {
                    if ($dto.UtcDateTime -ge $cutoff) {
                        $splitIdx = $i
                        break
                    }
                }
            }
        }
        if ($splitIdx -lt 0) {
            $splitIdx = [math]::Max(1, $lines.Length - $MinKeepLines)
        }
        if ($splitIdx -gt 1) {
            $tempPath = $Path + '.trim.tmp'
            $backupPath = $Path + '.trim.bak'
            try {
                $writer = [IO.File]::CreateText($tempPath)
                try {
                    $writer.WriteLine($header)
                    for ($j = $splitIdx; $j -lt $lines.Length; $j++) {
                        $writer.WriteLine($lines[$j])
                    }
                    $writer.Flush()
                } finally {
                    $writer.Dispose()
                }
                if ([IO.File]::Exists($backupPath)) { [void][IO.File]::Delete($backupPath) }
                try {
                    [void][IO.File]::Replace($tempPath, $Path, $backupPath, $true)
                } catch {
                    # If target file is transiently locked by live reader, don't abort rotation
                }
            } finally {
                if ([IO.File]::Exists($tempPath)) { [void][IO.File]::Delete($tempPath) }
                if ([IO.File]::Exists($backupPath)) { [void][IO.File]::Delete($backupPath) }
            }
        }
    }
}

function Limit-CMTextLog {
    param([string]$Path, [int]$MaxLines = 2000)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Invoke-CMFileLock $Path {
        $lines = @([IO.File]::ReadAllLines($Path))
        if ($lines.Length -gt $MaxLines) {
            $keep = $lines[($lines.Length - $MaxLines)..($lines.Length - 1)]
            $tempPath = $Path + '.trim.tmp'
            $backupPath = $Path + '.trim.bak'
            try {
                [IO.File]::WriteAllLines($tempPath, $keep)
                if ([IO.File]::Exists($backupPath)) { [void][IO.File]::Delete($backupPath) }
                try {
                    [void][IO.File]::Replace($tempPath, $Path, $backupPath, $true)
                } catch {
                    # If target file is transiently locked, don't abort rotation
                }
            } finally {
                if ([IO.File]::Exists($tempPath)) { [void][IO.File]::Delete($tempPath) }
                if ([IO.File]::Exists($backupPath)) { [void][IO.File]::Delete($backupPath) }
            }
        }
    }
}

function Invoke-CMRotation {
    param([string]$Root, [hashtable]$Config)
    $base = Join-Path $Root 'Evidence'
    $archive = Join-Path $base 'Archive'
    [void][IO.Directory]::CreateDirectory($archive)

    $retentionHours = 4
    if ($Config -and $Config.ContainsKey('RetentionHours') -and [double]$Config.RetentionHours -gt 0) {
        $retentionHours = [int]$Config.RetentionHours
    }

    # 1. Trim continuous CSV logs to RetentionHours
    foreach ($csvName in @('telemetry-v2.csv', 'heartbeat-v2.csv', 'temperatures.csv')) {
        $csvPath = Join-Path $base "Logs/$csvName"
        Limit-CMCsvLog -Path $csvPath -RetentionHours $retentionHours
    }

    # 2. Trim runtime text logs
    foreach ($logName in @('telemetry.log', 'events.log', 'supervisor.log')) {
        $logPath = Join-Path $base "Logs/$logName"
        Limit-CMTextLog -Path $logPath -MaxLines 2000
    }

    # 3. Size-based archival
    foreach ($file in @(Get-ChildItem (Join-Path $base 'Logs') -File -ErrorAction SilentlyContinue)) {
        if ($file.Length -ge ([long]$Config.MaxLogSizeMB * 1MB)) {
            $target = Join-Path $archive ($file.BaseName + '-' + [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6) + $file.Extension)
            try { Invoke-CMFileLock $file.FullName { Move-Item -LiteralPath $file.FullName -Destination $target -ErrorAction Stop } } catch { }
        }
    }
    # Only v2-owned evidence is managed; legacy Logs/Reports are never touched.
    $xml = @(Get-ChildItem (Join-Path $base 'Events') -Filter '*.xml' -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
    $xml | Select-Object -Skip ([int]$Config.MaxEventXmlFiles) | Remove-Item -Force -ErrorAction SilentlyContinue
    $incidents = @(Get-ChildItem (Join-Path $base 'Incidents') -Directory -ErrorAction SilentlyContinue | Where-Object Name -Match '^[A-F0-9]{24}$' | Sort-Object LastWriteTimeUtc -Descending)
    $incidents | Select-Object -Skip ([int]$Config.MaxIncidents) | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $archives = @(Get-ChildItem $archive -File | Sort-Object LastWriteTimeUtc -Descending)
    $total = 0L
    $archiveCutoff = [DateTime]::UtcNow.AddHours(-$retentionHours)
    foreach ($file in $archives) {
        $total += $file.Length
        if ($file.LastWriteTimeUtc -lt $archiveCutoff -or $total -gt ([long]$Config.MaxEvidenceMB * 1MB)) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }
    }
}

function Get-CMSmartSnapshot {
    param([string]$ToolsDir = 'C:\CrashMonitor\Tools')
    $snapshot = [ordered]@{
        Utc = [DateTime]::UtcNow.ToString('o')
        Source = 'CIM'
        Disks = @()
    }
    # Check for smartctl first if available
    $smartctlPath = Join-Path $ToolsDir 'smartmontools\smartctl.exe'
    if (-not (Test-Path -LiteralPath $smartctlPath)) {
        $cmd = Get-Command 'smartctl.exe' -ErrorAction SilentlyContinue
        if ($cmd) { $smartctlPath = $cmd.Source }
    }
    # Not "$Args": that name is PowerShell's automatic variable, so such a parameter is always empty and smartctl got no arguments.
    function Invoke-ExecutableWithTimeout([string]$ExePath, [string]$Arguments, [int]$TimeoutMs = 15000) {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $ExePath
        $psi.Arguments = $Arguments
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = [Diagnostics.Process]::Start($psi)
        if ($null -eq $proc) { return $null }
        $out = $null
        try {
            # Read while the process runs: a full stdout pipe would otherwise block smartctl until the timeout.
            $read = $proc.StandardOutput.ReadToEndAsync()
            if ($proc.WaitForExit($TimeoutMs)) {
                $out = $read.Result
            } else {
                try { $proc.Kill() } catch { }
            }
        } finally { $proc.Dispose() }
        return $out
    }

    if (Test-Path -LiteralPath $smartctlPath) {
        try {
            # --scan-open spins up idle HDDs, which can take several seconds.
            $rawJson = Invoke-ExecutableWithTimeout -ExePath $smartctlPath -Arguments '--scan-open -j'
            $scanOut = if ($rawJson) { $rawJson | ConvertFrom-Json } else { $null }
            if ($scanOut -and $scanOut.devices) {
                $snapshot.Source = 'smartctl'
                foreach ($dev in $scanOut.devices) {
                    $devJson = Invoke-ExecutableWithTimeout -ExePath $smartctlPath -Arguments "-a $($dev.name) -j"
                    $devInfo = if ($devJson) { $devJson | ConvertFrom-Json } else { $null }
                    if (-not $devInfo) { continue }
                    $diskData = [ordered]@{
                        Device = $dev.name
                        Type = $dev.type
                        Model = $devInfo.model_name
                        Serial = [string]$devInfo.serial_number
                        PowerCycles = $null
                        UnsafeShutdowns = $null
                        PowerOnHours = $null
                        Temperature = $null
                    }
                    if ($devInfo.power_cycle_count) { $diskData.PowerCycles = [long]$devInfo.power_cycle_count }
                    if ($devInfo.power_on_time -and $devInfo.power_on_time.hours) { $diskData.PowerOnHours = [long]$devInfo.power_on_time.hours }
                    if ($devInfo.temperature -and $devInfo.temperature.current) { $diskData.Temperature = [double]$devInfo.temperature.current }
                    # NVMe attributes
                    if ($devInfo.nvme_smart_health_information_log) {
                        $nvme = $devInfo.nvme_smart_health_information_log
                        # 0 is a valid baseline: a later 1 is exactly the power loss this comparison looks for.
                        if ($null -ne $nvme.unsafe_shutdowns) { $diskData.UnsafeShutdowns = [long]$nvme.unsafe_shutdowns }
                        if ($null -ne $nvme.power_cycles) { $diskData.PowerCycles = [long]$nvme.power_cycles }
                    }
                    # ATA SMART attributes (ID 12 Power_Cycle_Count, ID 192 Power-Off_Retract_Count)
                    if ($devInfo.ata_smart_attributes -and $devInfo.ata_smart_attributes.table) {
                        $loadUnload = $null
                        foreach ($attr in $devInfo.ata_smart_attributes.table) {
                            if ($attr.id -eq 12) { $diskData.PowerCycles = [long]$attr.raw.value }
                            if ($attr.id -eq 192) { $diskData.UnsafeShutdowns = [long]$attr.raw.value }
                            if ($attr.id -eq 193) { $loadUnload = [long]$attr.raw.value }
                        }
                        # Some drives (Toshiba DT01ACA100) repeat the load/unload count (193) in 192: not an emergency-retract counter.
                        if ($null -ne $diskData.UnsafeShutdowns -and $diskData.UnsafeShutdowns -gt 0 -and $diskData.UnsafeShutdowns -eq $loadUnload) { $diskData.UnsafeShutdowns = $null }
                    }
                    $snapshot.Disks += [pscustomobject]$diskData
                }
                return [pscustomobject]$snapshot
            }
        } catch { }
    }
    # Fallback to Windows Storage CIM
    try {
        $cimOpt = New-CimSessionOption
        $physDisks = @(Get-CimInstance -Namespace 'root/Microsoft/Windows/Storage' -ClassName 'MSFT_PhysicalDisk' -OperationTimeoutSec 5 -ErrorAction SilentlyContinue)
        $relCounters = @(Get-CimInstance -Namespace 'root/Microsoft/Windows/Storage' -ClassName 'MSFT_StorageReliabilityCounter' -OperationTimeoutSec 5 -ErrorAction SilentlyContinue)
        foreach ($pd in $physDisks) {
            $rc = $relCounters | Where-Object { $_.DeviceId -eq $pd.DeviceId } | Select-Object -First 1
            $diskData = [ordered]@{
                DeviceId = [string]$pd.DeviceId
                FriendlyName = [string]$pd.FriendlyName
                MediaType = [string]$pd.MediaType
                BusType = [string]$pd.BusType
                StartStopCycleCount = if ($rc -and $null -ne $rc.StartStopCycleCount) { [long]$rc.StartStopCycleCount } else { $null }
                LoadUnloadCycleCount = if ($rc -and $null -ne $rc.LoadUnloadCycleCount) { [long]$rc.LoadUnloadCycleCount } else { $null }
                PowerOnHours = if ($rc -and $null -ne $rc.PowerOnHours) { [long]$rc.PowerOnHours } else { $null }
                ReadErrorsTotal = if ($rc -and $null -ne $rc.ReadErrorsTotal) { [long]$rc.ReadErrorsTotal } else { $null }
                WriteErrorsTotal = if ($rc -and $null -ne $rc.WriteErrorsTotal) { [long]$rc.WriteErrorsTotal } else { $null }
                Temperature = if ($rc -and $null -ne $rc.Temperature) { [double]$rc.Temperature } else { $null }
            }
            $snapshot.Disks += [pscustomobject]$diskData
        }
    } catch { }
    return [pscustomobject]$snapshot
}

function Compare-CMSmartSnapshots {
    param($CurrentSnapshot, $PreviousSnapshot, [string]$RestartClassification = '')
    $analysis = [ordered]@{
        EvaluatedUtc = [DateTime]::UtcNow.ToString('o')
        Classification = $RestartClassification
        PowerCyclesIncreased = $false
        UnsafeShutdownsIncreased = $false
        PowerLossSuspected = $null
        Confidence = 'InsufficientData'
        Verdict = 'No comparative SMART baseline'
        DiskDeltas = @()
    }
    if (-not $CurrentSnapshot -or -not $PreviousSnapshot) { return [pscustomobject]$analysis }

    if ($RestartClassification -and $RestartClassification -notin @('UnexpectedReset', 'Unknown')) {
        $analysis.PowerLossSuspected = $false
        $analysis.Confidence = 'NotApplicable'
        $analysis.Verdict = "SMART delta evaluation skipped: orderly planned reboot ($RestartClassification)"
        $analysis['HardwarePowerLossConfirmed'] = $false
        return [pscustomobject]$analysis
    }

    $validMetricsCount = 0

    foreach ($cur in $CurrentSnapshot.Disks) {
        $identifier = if ($cur.DeviceId) { $cur.DeviceId } else { $cur.Device }
        $prev = $null
        # smartctl device names (/dev/sda) can change between boots, e.g. with a USB disk attached: match by serial first.
        if ($cur.Serial) {
            foreach ($p in $PreviousSnapshot.Disks) { if ($p.Serial -and $p.Serial -eq $cur.Serial) { $prev = $p; break } }
        }
        if (-not $prev) {
            foreach ($p in $PreviousSnapshot.Disks) {
                $pId = if ($p.DeviceId) { $p.DeviceId } else { $p.Device }
                if ($pId -eq $identifier -and -not ($cur.Serial -and $p.Serial -and $p.Serial -ne $cur.Serial)) { $prev = $p; break }
            }
        }
        if ($prev) {
            $delta = [ordered]@{
                Disk = $identifier
                Model = if ($cur.FriendlyName) { $cur.FriendlyName } else { $cur.Model }
                PowerCyclesDelta = $null
                UnsafeShutdownsDelta = $null
            }

            # Only evaluate actual power cycle count (SMART 12 or NVMe power_cycles)
            if ($cur.PowerCycles -ne $null -and $prev.PowerCycles -ne $null) {
                $delta.PowerCyclesDelta = [long]$cur.PowerCycles - [long]$prev.PowerCycles
                if ($delta.PowerCyclesDelta -gt 0) { $analysis.PowerCyclesIncreased = $true }
                $validMetricsCount++
            }

            # Only evaluate actual unsafe shutdowns (SMART 192 Power-Off_Retract_Count or NVMe unsafe_shutdowns)
            # NEVER use LoadUnloadCycleCount (193 head parking) or StartStopCycleCount (4 spindown)
            if ($cur.UnsafeShutdowns -ne $null -and $prev.UnsafeShutdowns -ne $null) {
                $delta.UnsafeShutdownsDelta = [long]$cur.UnsafeShutdowns - [long]$prev.UnsafeShutdowns
                if ($delta.UnsafeShutdownsDelta -gt 0) { $analysis.UnsafeShutdownsIncreased = $true }
                $validMetricsCount++
            }

            $analysis.DiskDeltas += [pscustomobject]$delta
        }
    }

    if ($validMetricsCount -eq 0) {
        $analysis.PowerLossSuspected = $null
        $analysis.Confidence = 'InsufficientData'
        $analysis.Verdict = 'Insufficient SMART data to determine physical power state (counters not reported by storage driver)'
    } elseif ($analysis.PowerCyclesIncreased -and $analysis.UnsafeShutdownsIncreased) {
        $analysis.PowerLossSuspected = $true
        $analysis.Confidence = 'High'
        $analysis.Verdict = 'High likelihood of physical power interruption (both power cycles and unsafe shutdowns incremented across reboot)'
    } elseif ($analysis.PowerCyclesIncreased -or $analysis.UnsafeShutdownsIncreased) {
        $analysis.PowerLossSuspected = $true
        $analysis.Confidence = 'Moderate'
        $analysis.Verdict = 'Potential physical power interruption detected (disk cycle or emergency retract counter incremented across reboot)'
    } else {
        $analysis.PowerLossSuspected = $false
        $analysis.Confidence = 'Moderate'
        $analysis.Verdict = 'No disk power cycle detected despite unexpected reset (disk power remained continuous across reset; suspect watchdog, kernel freeze or internal reset)'
    }

    # Backward compatibility for any consumers reading HardwarePowerLossConfirmed
    $analysis['HardwarePowerLossConfirmed'] = ($analysis.PowerLossSuspected -eq $true)

    return [pscustomobject]$analysis
}

Export-ModuleMember -Function *-CM*
