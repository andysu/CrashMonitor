#Requires -Version 5.1
# Runs on ANOTHER computer and records the UDP packets CrashMonitor sends when EnableUdpHeartbeat is on.
# A sudden reset or power loss can drop the last seconds of local evidence; this record survives it.
# Self-contained: copy this one file to the receiving computer. Inbound UDP on -Port must be allowed by its firewall.
[CmdletBinding()]
param(
    [int]$Port = 514,
    [string]$OutputDirectory,
    [int]$SilenceSeconds = 10,
    [int]$DurationSeconds = 0,
    [string]$BindAddress = '0.0.0.0'
)
$ErrorActionPreference = 'Stop'

$script:ReceiverColumns = @('ReceivedUtc','SenderIp','Host','Type','Seq','SentUtc','BootKey','CpuPct','RamPct','RamAvailMB','DiskQLen','IoLatencyMs','TempStatus','CpuTempC','CpuPowerW','Vcore','Plus12V','Plus5V','Plus33V','FanRpm','DiskTempC','ThermalZoneC','Whea','StorageErrors','ThermalEvents')
$script:EventColumns = @('Utc','Host','Event','Detail')

function ConvertFrom-CMHeartbeatPacket {
    # Accepts the RFC 5424 syslog line CrashMonitor sends and plain JSON; anything else is ignored.
    param([string]$Text)
    $start = $Text.IndexOf('{')
    if ($start -lt 0) { return $null }
    try { $packet = $Text.Substring($start) | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if (-not $packet.Host -or -not $packet.Type) { return $null }
    return $packet
}

function Update-CMHeartbeatState {
    # Called for every packet; returns RESUMED and REBOOT records for that host.
    param([hashtable]$State, $Packet, [datetime]$NowUtc)
    $records = @()
    $hostName = [string]$Packet.Host
    $previous = $State[$hostName]
    if ($previous) {
        if ($previous.Silent) { $records += [pscustomobject]@{ Utc=$NowUtc.ToString('o'); Host=$hostName; Event='RESUMED'; Detail=('packets again after {0:N0} s of silence' -f ($NowUtc - $previous.LastUtc).TotalSeconds) } }
        if ($Packet.BootKey -and $previous.BootKey -and $Packet.BootKey -ne $previous.BootKey) { $records += [pscustomobject]@{ Utc=$NowUtc.ToString('o'); Host=$hostName; Event='REBOOT'; Detail="BootKey $($previous.BootKey) -> $($Packet.BootKey)" } }
    }
    $lastTelemetry = if ($Packet.Type -eq 'telemetry') { $Packet } elseif ($previous) { $previous.LastTelemetry } else { $null }
    $bootKey = if ($Packet.BootKey) { [string]$Packet.BootKey } elseif ($previous) { $previous.BootKey } else { $null }
    $State[$hostName] = @{ LastUtc=$NowUtc; BootKey=$bootKey; Silent=$false; LastTelemetry=$lastTelemetry }
    return $records
}

function Test-CMHeartbeatSilence {
    # Called on every loop pass; returns one SILENCE record per host when its packets stop, with the last readings.
    param([hashtable]$State, [datetime]$NowUtc, [int]$SilenceSeconds)
    $records = @()
    foreach ($hostName in @($State.Keys)) {
        $entry = $State[$hostName]
        if ($entry.Silent -or ($NowUtc - $entry.LastUtc).TotalSeconds -lt $SilenceSeconds) { continue }
        $entry.Silent = $true
        $detail = "no packets for $SilenceSeconds s; last packet $($entry.LastUtc.ToString('o'))"
        $t = $entry.LastTelemetry
        if ($t) {
            $parts = foreach ($name in @('CpuPct','CpuTempC','CpuPowerW','Vcore','Plus12V','Plus5V','Plus33V','FanRpm','DiskTempC','Whea','StorageErrors','ThermalEvents')) {
                if ($null -ne $t.$name) { "$name=$($t.$name)" }
            }
            $detail += "; last telemetry $($t.Utc): " + (@($parts) -join ', ')
        }
        $records += [pscustomobject]@{ Utc=$NowUtc.ToString('o'); Host=$hostName; Event='SILENCE'; Detail=$detail }
    }
    return $records
}

function Add-CMReceiverCsv {
    param([string]$Path, [string[]]$Columns, $Values)
    $encode = {
        param($v)
        if ($null -eq $v) { $s = '' } elseif ($v -is [IFormattable]) { $s = $v.ToString($null, [Globalization.CultureInfo]::InvariantCulture) } else { $s = [string]$v }
        '"' + $s.Replace('"', '""') + '"'
    }
    $lines = @()
    if (-not (Test-Path -LiteralPath $Path)) { $lines += (@($Columns | ForEach-Object { & $encode $_ }) -join ';') }
    $lines += (@($Columns | ForEach-Object { & $encode $Values.$_ }) -join ';')
    [IO.File]::AppendAllText($Path, (($lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))
}

function Invoke-CMHeartbeatReceiver {
    param([int]$Port, [string]$OutputDirectory, [int]$SilenceSeconds, [int]$DurationSeconds, [string]$BindAddress)
    [void][IO.Directory]::CreateDirectory($OutputDirectory)
    $eventsPath = Join-Path $OutputDirectory 'heartbeat-events.csv'
    $udp = New-Object Net.Sockets.UdpClient((New-Object Net.IPEndPoint([Net.IPAddress]::Parse($BindAddress), $Port)))
    $udp.Client.ReceiveTimeout = 1000
    $state = @{}
    $until = if ($DurationSeconds -gt 0) { [datetime]::UtcNow.AddSeconds($DurationSeconds) } else { [datetime]::MaxValue }
    Write-Host "Listening on UDP ${BindAddress}:$Port; output $OutputDirectory; silence threshold $SilenceSeconds s. Ctrl+C to stop."
    try {
        while ([datetime]::UtcNow -lt $until) {
            $remote = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
            $bytes = $null
            try { $bytes = $udp.Receive([ref]$remote) }
            catch {
                $socketError = $_.Exception
                if ($socketError.InnerException) { $socketError = $socketError.InnerException }
                if (-not ($socketError -is [Net.Sockets.SocketException] -and $socketError.SocketErrorCode -eq [Net.Sockets.SocketError]::TimedOut)) { throw }
            }
            $now = [datetime]::UtcNow
            $records = @()
            if ($bytes) {
                $packet = ConvertFrom-CMHeartbeatPacket ([Text.Encoding]::UTF8.GetString($bytes))
                if ($packet) {
                    $row = @{ ReceivedUtc=$now.ToString('o'); SenderIp=$remote.Address.ToString(); SentUtc=$packet.Utc }
                    foreach ($name in $script:ReceiverColumns) { if (-not $row.ContainsKey($name)) { $row[$name] = $packet.$name } }
                    $safeHost = ([string]$packet.Host) -replace '[^A-Za-z0-9_.-]', '_'
                    Add-CMReceiverCsv -Path (Join-Path $OutputDirectory "heartbeat-$safeHost.csv") -Columns $script:ReceiverColumns -Values ([pscustomobject]$row)
                    $records += Update-CMHeartbeatState -State $state -Packet $packet -NowUtc $now
                }
            }
            $records += Test-CMHeartbeatSilence -State $state -NowUtc $now -SilenceSeconds $SilenceSeconds
            foreach ($record in $records) {
                Add-CMReceiverCsv -Path $eventsPath -Columns $script:EventColumns -Values $record
                Write-Host "[$($record.Utc)] $($record.Host) $($record.Event): $($record.Detail)"
            }
        }
    } finally { $udp.Dispose() }
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $OutputDirectory) { $OutputDirectory = Join-Path (Get-Location) 'HeartbeatLogs' }
    Invoke-CMHeartbeatReceiver -Port $Port -OutputDirectory $OutputDirectory -SilenceSeconds $SilenceSeconds -DurationSeconds $DurationSeconds -BindAddress $BindAddress
}
