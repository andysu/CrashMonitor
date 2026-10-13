#Requires -Version 5.1
[CmdletBinding()]
param([string]$RootPath, [switch]$Check)
$ErrorActionPreference='Stop'
# Windows PowerShell 5.1 leaves $PSScriptRoot empty inside param() defaults, so the project root is resolved here.
if (-not $RootPath) { $RootPath=Split-Path -Parent $PSScriptRoot }
$RootPath=[IO.Path]::GetFullPath($RootPath).TrimEnd('\')
$manifestPath=Join-Path $RootPath 'manifest.json'
# Package composition. README.md and TODO.md are excluded so documentation edits do not require a new manifest.
$sources=@(
    @{Dir='';Filter='*.ps1';Recurse=$false},
    @{Dir='Modules';Filter='*.psm1';Recurse=$false},
    @{Dir='Scripts';Filter='*.ps1';Recurse=$false},
    @{Dir='Tests';Filter='*.ps1';Recurse=$false},
    @{Dir='Config';Filter='*.json';Recurse=$false},
    @{Dir='Tools';Filter='*';Recurse=$true}
)
$found=New-Object Collections.Generic.List[string]
foreach ($src in $sources) {
    $dir=if ($src.Dir) { Join-Path $RootPath $src.Dir } else { $RootPath }
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter $src.Filter -File -Recurse:$src.Recurse)) { $found.Add($f.FullName.Substring($RootPath.Length+1).Replace('\','/')) }
}
foreach ($name in '.gitattributes','.gitignore') { if (Test-Path -LiteralPath (Join-Path $RootPath $name)) { $found.Add($name) } }
$paths=$found.ToArray()
[Array]::Sort($paths,[StringComparer]::InvariantCultureIgnoreCase)
$files=foreach ($p in $paths) {
    # Same rule as Assert-CMPackageManifest in Install.ps1: a path it would reject must not enter the manifest.
    if ($p -notmatch '^[A-Za-z0-9_./-]+$') { throw "Unsupported characters in package path: $p" }
    $full=Join-Path $RootPath $p
    [pscustomobject]@{Path=$p;SizeBytes=(Get-Item -LiteralPath $full -Force).Length;Sha256=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLower()}
}
$files=@($files)

$old=$null
if (Test-Path -LiteralPath $manifestPath) { $old=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
$oldFiles=@{}
if ($old) { foreach ($e in @($old.Files)) { $oldFiles[$e.Path]=$e } }
$changes=New-Object Collections.Generic.List[string]
foreach ($f in $files) {
    if (-not $oldFiles.ContainsKey($f.Path)) { $changes.Add("ADDED: $($f.Path)") }
    elseif ([string]$oldFiles[$f.Path].Sha256 -ne $f.Sha256 -or [long]$oldFiles[$f.Path].SizeBytes -ne $f.SizeBytes) { $changes.Add("CHANGED: $($f.Path)") }
}
foreach ($p in $oldFiles.Keys) { if ($paths -notcontains $p) { $changes.Add("REMOVED: $p") } }
# Order matters too: a reordered list rewrites the file even when every hash matches.
$sameOrder=$old -and ((@($old.Files | ForEach-Object { $_.Path }) -join '|') -eq ($paths -join '|'))
if ($changes.Count -eq 0 -and $sameOrder) {
    Write-Output "manifest.json is up to date ($($files.Count) files)."
    exit 0
}
$changes | ForEach-Object { Write-Output $_ }
if ($Check) {
    Write-Output "manifest.json is out of date: $($changes.Count) change(s). Run Scripts/Update-Manifest.ps1 to regenerate it."
    exit 1
}

# Hand-written JSON keeps the Windows PowerShell 5.1 ConvertTo-Json layout on any PowerShell edition, so diffs stay minimal.
function ConvertTo-CMJsonScalar { param($Value) if ($null -eq $Value) { return 'null' }; return ($Value | ConvertTo-Json -Compress) }
$package=if ($old -and $old.Package) { $old.Package } else { 'CrashMonitor' }
$version=if ($old -and $old.Version) { $old.Version } else { '2.0.0' }
$gitCommit=if ($old) { $old.GitCommit } else { $null }
$entries=foreach ($f in $files) {
    "                  {`r`n                      `"Path`":  $(ConvertTo-CMJsonScalar $f.Path),`r`n                      `"SizeBytes`":  $($f.SizeBytes),`r`n                      `"Sha256`":  `"$($f.Sha256)`"`r`n                  }"
}
$json="{`r`n    `"Package`":  $(ConvertTo-CMJsonScalar $package),`r`n    `"Version`":  $(ConvertTo-CMJsonScalar $version),`r`n    `"GeneratedUtc`":  `"$([datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))`",`r`n    `"GitCommit`":  $(ConvertTo-CMJsonScalar $gitCommit),`r`n    `"FileCount`":  $($files.Count),`r`n    `"Files`":  [`r`n$(@($entries) -join ",`r`n")`r`n              ]`r`n}"
[IO.File]::WriteAllText($manifestPath,$json,(New-Object Text.UTF8Encoding $true))
Write-Output "manifest.json updated: $($files.Count) files, $($changes.Count) change(s)."
