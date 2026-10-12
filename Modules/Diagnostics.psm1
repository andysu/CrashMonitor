#Requires -Version 5.1
Import-Module (Join-Path $PSScriptRoot 'Common.psm1')

function Invoke-CMNative {
    param([string]$FilePath, [string[]]$Arguments, [string]$OutputPrefix, [int]$TimeoutSeconds=30)
    $out="$OutputPrefix.stdout.txt"; $err="$OutputPrefix.stderr.txt"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()

    $stdoutTask = $p.StandardOutput.ReadToEndAsync()
    $stderrTask = $p.StandardError.ReadToEndAsync()

    try {
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            try { $p.Kill() } catch {}
            throw "Timeout running $FilePath"
        }
        [IO.File]::WriteAllText($out, $stdoutTask.Result)
        [IO.File]::WriteAllText($err, $stderrTask.Result)
        if ($p.ExitCode -ne 0) { throw "$FilePath exit code $($p.ExitCode). See $err" }
    } finally { $p.Dispose() }
}

function Get-CMInventory {
    $result=[ordered]@{ SchemaVersion=2; CapturedUtc=[datetime]::UtcNow.ToString('o'); Errors=@() }
    $queries=@{
        OperatingSystem=@('Win32_OperatingSystem',@('Caption','Version','BuildNumber','LastBootUpTime','SystemDrive','WindowsDirectory','TotalVisibleMemorySize','FreePhysicalMemory'))
        Computer=@('Win32_ComputerSystem',@('Manufacturer','Model','TotalPhysicalMemory','AutomaticManagedPagefile','HypervisorPresent'))
        Bios=@('Win32_BIOS',@('Manufacturer','SMBIOSBIOSVersion','ReleaseDate'))
        Processor=@('Win32_Processor',@('Name','MaxClockSpeed','NumberOfCores','NumberOfLogicalProcessors'))
        Disks=@('Win32_DiskDrive',@('Index','DeviceID','Model','SerialNumber','InterfaceType','Size','Status','PNPDeviceID'))
        LogicalDisks=@('Win32_LogicalDisk',@('DeviceID','DriveType','FileSystem','Size','FreeSpace','VolumeName'))
        PageFileSettings=@('Win32_PageFileSetting',@('Name','InitialSize','MaximumSize'))
        PageFileUsage=@('Win32_PageFileUsage',@('Name','AllocatedBaseSize','CurrentUsage','PeakUsage','TempPageFile'))
        Recovery=@('Win32_OSRecoveryConfiguration',@('DebugInfoType','DebugFilePath','MiniDumpDirectory','AutoReboot','WriteToSystemLog','OverwriteExistingDebugFile'))
        Drivers=@('Win32_PnPSignedDriver',@('DeviceName','DeviceID','DriverVersion','DriverDate','DriverProviderName','InfName','IsSigned'))
        KernelDrivers=@('Win32_SystemDriver',@('Name','DisplayName','State','StartMode','PathName','ServiceType'))
        Updates=@('Win32_QuickFixEngineering',@('HotFixID','Description','InstalledOn'))
    }
    foreach ($key in $queries.Keys) {
        try { $result[$key]=@(Get-CimInstance -ClassName $queries[$key][0] -OperationTimeoutSec 5 -ErrorAction Stop | Select-Object -Property $queries[$key][1]) }
        catch { $result.Errors+= "${key}: $_" }
    }
    try { $result.Partitions=@(Get-Partition -ErrorAction Stop | Select-Object DiskNumber,PartitionNumber,DriveLetter,Type,Size,AccessPaths,IsBoot,IsSystem) }
    catch { $result.Errors+="Partitions: $_" }
    try {
        $physical=@(Get-PhysicalDisk -ErrorAction Stop)
        $result.PhysicalDisks=@($physical | Select-Object DeviceId,FriendlyName,SerialNumber,MediaType,BusType,HealthStatus,OperationalStatus,Size)
        $result.StorageReliability=@($physical | Get-StorageReliabilityCounter -ErrorAction Stop | Select-Object DeviceId,Temperature,TemperatureMax,ReadErrorsTotal,ReadErrorsUncorrected,WriteErrorsTotal,WriteErrorsUncorrected,Wear,PowerOnHours)
    } catch { $result.Errors+="Storage reliability (not full SMART; hardware dependent): $_" }
    try { $result.CrashControl=Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction Stop | Select-Object CrashDumpEnabled,DumpFile,MinidumpDir,AutoReboot,LogEvent,AlwaysKeepMemoryDump,DedicatedDumpFile,DumpFileSize }
    catch { $result.Errors+="CrashControl: $_" }
    $result.DumpFiles=@()
    foreach ($path in @("$env:SystemRoot\MEMORY.DMP","$env:SystemRoot\Minidump")) {
        if (Test-Path -LiteralPath $path) { $result.DumpFiles+=@(Get-ChildItem -LiteralPath $path -File -ErrorAction SilentlyContinue | Select-Object Name,Length,LastWriteTimeUtc,FullName) }
    }
    return $result
}

function Export-CMEvtx {
    param([string]$Directory, [Nullable[datetime]]$SinceUtc)
    [void][IO.Directory]::CreateDirectory($Directory)
    foreach ($channel in @('System','Application')) {
        $dest=Join-Path $Directory "$channel.evtx"
        $args=@('epl',$channel,('"{0}"' -f $dest),'/ow:true')
        if ($null -ne $SinceUtc) {
            $when=([datetime]$SinceUtc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            $args+=('/q:"*[System[TimeCreated[@SystemTime >= ''{0}'']]]"' -f $when)
        }
        Invoke-CMNative -FilePath (Join-Path $env:SystemRoot 'System32/wevtutil.exe') -Arguments $args -OutputPrefix (Join-Path $Directory "$channel-export") -TimeoutSeconds 60
    }
}

function New-CMIncident {
    param([string]$Root, [hashtable]$Config, $Boot, [object[]]$Events, $PreviousSession)
    $dir=Join-Path $Root "Evidence/Incidents/$($Boot.BootKey)"
    if (Test-Path -LiteralPath (Join-Path $dir 'complete.json')) { return }
    [void][IO.Directory]::CreateDirectory($dir)
    $previousBoot=$null
    if ($PreviousSession) { $previousBoot=[datetime]::Parse($PreviousSession.Boot.BootUtc).ToUniversalTime() }
    $classification=Get-CMRestartClassification -Events $Events -BootUtc ([datetime]::Parse($Boot.BootUtc).ToUniversalTime()) -PreviousBootUtc $previousBoot
    $inventory=Get-CMInventory
    Write-CMJson (Join-Path $dir 'inventory.json') $inventory
    $report=[ordered]@{
        SchemaVersion=2; GeneratedUtc=[datetime]::UtcNow.ToString('o'); Boot=$Boot
        PreviousSession=$PreviousSession; Classification=$classification
        BootEvents=@($Events); Limitations=@('No dump analysis performed. Heartbeat timestamps are last confirmed monitor activity, not an exact failure time.','Disk errors and WHEA are evidence, not an automatic root-cause verdict.','Software polling cannot rule out short power loss, CPU overheating or hardware watchdog resets.')
    }
    Write-CMJson (Join-Path $dir 'report.json') $report
    $lines=@('CrashMonitor v2 - boot incident',"Boot UTC: $($Boot.BootUtc)","Boot key: $($Boot.BootKey)","Classification: $($classification.Type)",$classification.Explanation,'','Events (UTC / provider / ID / message):')
    $lines+=@($Events | Sort-Object Utc | ForEach-Object { "$($_.Utc) | $($_.Provider) | $($_.EventId) | $($_.Message)" })
    $lines+=@('','Limits:')+$report.Limitations
    [IO.File]::WriteAllLines((Join-Path $dir 'report.txt'),[string[]]$lines,(New-Object Text.UTF8Encoding($false)))
    # Each event in report.json includes EventData; full XML is copied independently.
    $xmlDir=Join-Path $dir 'XML'; [void][IO.Directory]::CreateDirectory($xmlDir)
    foreach ($ev in $Events) {
        $safe=$ev.Channel -replace '[^a-zA-Z0-9_-]','_'
        $stamp=[datetime]::Parse($ev.Utc).ToUniversalTime().Ticks
        $source=Join-Path $Root "Evidence/Events/$safe/$($ev.RecordId)-$stamp.xml"
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $xmlDir "$safe-$($ev.RecordId)-$stamp.xml") -Force }
    }
    foreach ($name in @('telemetry-v2.csv','heartbeat-v2.csv','events.jsonl','supervisor.log','events.log','telemetry.log')) {
        $path=Join-Path $Root "Evidence/Logs/$name"
        if (Test-Path -LiteralPath $path) {
            # Bounded tails keep report generation independent of months of logs.
            if ($name.EndsWith('.csv')) {
                Invoke-CMFileLock $path {
                    $header=Get-Content -LiteralPath $path -TotalCount 1 -Encoding UTF8 -ErrorAction Stop
                    $tail=@(Get-Content -LiteralPath $path -Tail 300 -Encoding UTF8 -ErrorAction Stop)
                    if ($tail.Count -and $tail[0] -ne $header) { $tail=@($header)+$tail }
                    $tail | Set-Content -LiteralPath (Join-Path $dir $name) -Encoding UTF8
                }
            } else { Get-Content -LiteralPath $path -Tail 300 -Encoding UTF8 -ErrorAction Stop | Set-Content -LiteralPath (Join-Path $dir $name) -Encoding UTF8 }
        }
    }
    $exportErrors=@()
    $since=[datetime]::Parse($Boot.BootUtc).ToUniversalTime().AddHours(-24)
    try { Export-CMEvtx -Directory (Join-Path $dir 'EVTX') -SinceUtc $since }
    catch { $exportErrors+= [string]$_; Write-CMLog $Root 'events' "EVTX incident export failed: $_" 'ERROR' }
    Write-CMJson (Join-Path $dir 'complete.json') @{ CompletedUtc=[datetime]::UtcNow.ToString('o'); ExportErrors=$exportErrors; Classification=$classification.Type }
}

function Export-CMDiagnostics {
    param([string]$Root, [string]$Destination, [hashtable]$Config, [switch]$FullHistory)
    $stamp=[datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)
    $dir=Join-Path $Destination "CrashMonitor-Diagnostics-$stamp"
    [void][IO.Directory]::CreateDirectory($dir)
    Write-CMJson (Join-Path $dir 'inventory.json') (Get-CMInventory)
    foreach ($name in @('Logs','State','Incidents','Events','Archive')) {
        $source=Join-Path $Root "Evidence/$name"
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $dir -Recurse -Force -ErrorAction Stop }
    }
    $since=[datetime]::UtcNow.AddHours(-[double]$Config.EventBackfillHours)
    if ($FullHistory) { $since=$null }
    Export-CMEvtx -Directory (Join-Path $dir 'EVTX') -SinceUtc $since
    $manifest=@(Get-ChildItem $dir -File -Recurse | ForEach-Object {
        [pscustomobject]@{ Path=$_.FullName.Substring($dir.Length+1); Bytes=$_.Length; SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    })
    Write-CMJson (Join-Path $dir 'manifest.json') @{ CapturedUtc=[datetime]::UtcNow.ToString('o'); Files=$manifest; FullHistory=[bool]$FullHistory; Note='Live snapshot: individual logs may advance during copying. Memory dumps and legacy logs are not copied.' }
    $zip="$dir.zip"
    Compress-Archive -LiteralPath $dir -DestinationPath $zip -CompressionLevel Optimal -ErrorAction Stop
    return $zip
}
Export-ModuleMember -Function Invoke-CMNative, Get-CMInventory, Export-CMEvtx, New-CMIncident, Export-CMDiagnostics
