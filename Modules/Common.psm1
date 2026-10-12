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

function Write-CMJson {
    param([string]$Path, $Value)
    $dir = Split-Path -Parent $Path
    [void][IO.Directory]::CreateDirectory($dir)
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $bytes = $script:Utf8.GetBytes(($Value | ConvertTo-Json -Depth 24))
        $stream = [IO.File]::Open($temp, 'CreateNew', 'Write', 'None')
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Read-CMJson {
    param([string]$Path, $Default = $null)
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    # Corrupt checkpoints must be reported by the caller, never silently advanced.
    return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop)
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
    if ($kp.Count) { [void][long]::TryParse([string](Get-CMValue $kp[-1].Data 'BugcheckCode' '0'), [ref]$code) }
    if ($code -ne 0 -or $bug.Count) {
        return [pscustomobject]@{ Type='Bugcheck'; BugcheckCode=$code; Explanation='Windows recorded a stop error. Inspect EventData and the memory dump; the faulty component is not identified here.' }
    }
    if ($kp.Count -or $dirty.Count) {
        return [pscustomobject]@{ Type='UnexpectedReset'; BugcheckCode=$code; Explanation='Unclean shutdown confirmed. Power loss, hardware reset, watchdog, hang or an unrecorded bugcheck remain possible.' }
    }
    $lower = $BootUtc.AddMinutes(-30)
    if ($null -ne $PreviousBootUtc -and $PreviousBootUtc -gt $lower) { $lower = [datetime]$PreviousBootUtc }
    $planned = @($Events | Where-Object {
        $_.Provider -eq 'User32' -and $_.EventId -eq 1074 -and ([datetime]::Parse($_.Utc).ToUniversalTime()) -ge $lower -and ([datetime]::Parse($_.Utc).ToUniversalTime()) -lt $BootUtc
    })
    if ($planned.Count) { return [pscustomobject]@{ Type='RequestedRestart'; BugcheckCode=$null; Explanation='User32 recorded a shutdown/restart request. Inspect its process, account and reason; this does not establish whether every shutdown stage completed.' } }
    return [pscustomobject]@{ Type='Unknown'; BugcheckCode=$null; Explanation='Insufficient boot evidence. A heartbeat gap alone is not proof of a crash.' }
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

        $splitIdx = 1
        for ($i = 1; $i -lt ($lines.Length - $MinKeepLines); $i++) {
            $cols = $lines[$i].Split(';')
            if ($cols.Length -gt $utcCol) {
                $ts = $cols[$utcCol].Trim('"')
                $dt = [DateTime]::MinValue
                if ([DateTime]::TryParse($ts, [ref]$dt)) {
                    if ($dt -ge $cutoff) {
                        $splitIdx = $i
                        break
                    }
                }
            }
        }
        if ($splitIdx -gt 1) {
            $tempPath = $Path + '.trim.tmp'
            $writer = [IO.File]::CreateText($tempPath)
            try {
                $writer.WriteLine($header)
                for ($j = $splitIdx; $j -lt $lines.Length; $j++) {
                    $writer.WriteLine($lines[$j])
                }
            } finally {
                $writer.Dispose()
            }
            [void][IO.File]::Copy($tempPath, $Path, $true)
            [void][IO.File]::Delete($tempPath)
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
            [IO.File]::WriteAllLines($Path, $keep)
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

Export-ModuleMember -Function *-CM*
