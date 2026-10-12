#Requires -Version 5.1
[CmdletBinding()]
param([string]$RootPath='C:\CrashMonitor', [string]$Destination, [switch]$FullHistory)
$ErrorActionPreference='Stop'
$codeRoot=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $codeRoot 'Modules/Common.psm1')
Import-Module (Join-Path $codeRoot 'Modules/Diagnostics.psm1')
if (-not $Destination) { $Destination=Join-Path $RootPath 'Exports' }
if ([IO.Path]::GetFullPath($Destination).StartsWith([IO.Path]::GetFullPath((Join-Path $RootPath 'Evidence')), [StringComparison]::OrdinalIgnoreCase)) { throw 'Destination must be outside Evidence to prevent recursive copies.' }
$path=Export-CMDiagnostics -Root $RootPath -Destination $Destination -Config (Get-CMConfig $RootPath $codeRoot) -FullHistory:$FullHistory
Write-Output $path
