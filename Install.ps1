#Requires -Version 5.1
[CmdletBinding()]
param([string]$RootPath='C:\CrashMonitor', [switch]$EnableCrashDumps, [switch]$DisableAutoReboot, [switch]$NoStart)
$ErrorActionPreference='Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Installation requires Windows.' }
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run Windows PowerShell as Administrator.' }
if ($DisableAutoReboot -and -not $EnableCrashDumps) { throw '-DisableAutoReboot requires -EnableCrashDumps.' }
$RootPath=[IO.Path]::GetFullPath($RootPath).TrimEnd('\')
$source=$PSScriptRoot
$manifestPath=Join-Path $source 'manifest.json'
if (Test-Path -LiteralPath $manifestPath) {
    $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($entry in $manifest.Files) {
        if ($entry.Path -notmatch '^[A-Za-z0-9_./-]+$' -or $entry.Path -match '(^|/)\.\.(/|$)' -or [IO.Path]::IsPathRooted($entry.Path)) { throw 'Invalid path in package manifest.' }
        $file=Join-Path $source $entry.Path
        if (-not (Test-Path -LiteralPath $file) -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $entry.SHA256) { throw "Package checksum mismatch: $($entry.Path)" }
    }
}
# Validate pure logic before touching the installed monitor or OS settings.
& (Join-Path $source 'Tests/Test-Self.ps1')
Import-Module (Join-Path $source 'Modules/Common.psm1')
$config=Get-CMConfig $RootPath $source
$files=@('CrashMonitor.ps1','Worker.ps1','Install.ps1','NightlyLogCleanup.ps1','RegisterNightlyTask.ps1','README.md','TODO.md','Config/defaults-v2.json','Modules/Common.psm1','Modules/EventCapture.psm1','Modules/TelemetryV2.psm1','Modules/Diagnostics.psm1','Modules/VoltageMonitor.psm1','Scripts/Export-Diagnostics.ps1','Scripts/Get-MonitorStatus.ps1','Scripts/Stop-Monitor.ps1','Tests/Test-Self.ps1','Tests/Test-Windows.ps1')
if (Test-Path -LiteralPath $manifestPath) { $files+= 'manifest.json' }
$backup=Join-Path $RootPath ('Backups/v2-'+[datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))
[void][IO.Directory]::CreateDirectory($backup)
$task=Get-ScheduledTask -TaskName 'CrashMonitor_AutoStart' -ErrorAction SilentlyContinue
if ($task) { Export-ScheduledTask -TaskName 'CrashMonitor_AutoStart' | Set-Content -LiteralPath (Join-Path $backup 'CrashMonitor_AutoStart.xml') -Encoding UTF8 }
$legacyCleanup=Get-ScheduledTask -TaskName 'CrashMonitor_NightlyCleanup' -ErrorAction SilentlyContinue
if ($legacyCleanup) { Export-ScheduledTask -TaskName 'CrashMonitor_NightlyCleanup' | Set-Content -LiteralPath (Join-Path $backup 'CrashMonitor_NightlyCleanup.xml') -Encoding UTF8 }
# Graceful v2 shutdown before replacing files. Legacy v1 runs directly as the task.
$stop=Join-Path $RootPath 'Evidence/State/stop.request'
if (Test-Path -LiteralPath (Split-Path -Parent $stop)) {
    [IO.File]::WriteAllText($stop,[datetime]::UtcNow.ToString('o'))
    Start-Sleep -Seconds 6
}
if ($task) { Stop-ScheduledTask -TaskName 'CrashMonitor_AutoStart' -ErrorAction Stop }
if ($legacyCleanup) { Stop-ScheduledTask -TaskName 'CrashMonitor_NightlyCleanup' -ErrorAction SilentlyContinue; Disable-ScheduledTask -TaskName 'CrashMonitor_NightlyCleanup' | Out-Null }
foreach ($relative in $files + @('Config/config.json')) {
    $target=Join-Path $RootPath $relative
    if (Test-Path -LiteralPath $target) {
        $saved=Join-Path $backup $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $saved))
        Copy-Item -LiteralPath $target -Destination $saved -Force
    }
}
if ($source.TrimEnd('\') -ne $RootPath) {
    foreach ($relative in $files) {
        $target=Join-Path $RootPath $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        Copy-Item -LiteralPath (Join-Path $source $relative) -Destination $target -Force
    }
}
$config.SchemaVersion=2
Write-CMJson -Path (Join-Path $RootPath 'Config/config.json') -Value $config
if ($EnableCrashDumps) {
    $key='HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
    $names=@('CrashDumpEnabled','LogEvent','AlwaysKeepMemoryDump','AutoReboot')
    $old=Get-ItemProperty -LiteralPath $key
    $saved=@{}
    foreach ($name in $names) { $saved[$name]=@{ Exists=($null -ne $old.PSObject.Properties[$name]); Value=(Get-CMValue $old $name) } }
    Write-CMJson (Join-Path $backup 'CrashControl-before.json') $saved
    New-ItemProperty -LiteralPath $key -Name CrashDumpEnabled -Value 7 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -LiteralPath $key -Name LogEvent -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -LiteralPath $key -Name AlwaysKeepMemoryDump -Value 1 -PropertyType DWord -Force | Out-Null
    if ($DisableAutoReboot) { New-ItemProperty -LiteralPath $key -Name AutoReboot -Value 0 -PropertyType DWord -Force | Out-Null }
    Write-Warning 'Automatic memory dump configured. Pagefile settings were preserved: verify their capacity and free space. A later planned reboot may be needed for OS dump settings to take effect.'
}
$exe=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$args='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RootPath "{1}" -NonInteractive' -f (Join-Path $RootPath 'CrashMonitor.ps1'),$RootPath
$action=New-ScheduledTaskAction -Execute $exe -Argument $args -WorkingDirectory $RootPath
$trigger=New-ScheduledTaskTrigger -AtStartup
$taskPrincipal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'CrashMonitor_AutoStart' -Action $action -Trigger $trigger -Principal $taskPrincipal -Settings $settings -Force | Out-Null
if (-not $NoStart) { Start-ScheduledTask -TaskName 'CrashMonitor_AutoStart' }
Write-Output "Installed CrashMonitor v2 in $RootPath. Previous code/task configuration: $backup"
Write-Output "After 1-2 minutes run: powershell -NoProfile -File `"$RootPath\Tests\Test-Windows.ps1`" -RootPath `"$RootPath`""
