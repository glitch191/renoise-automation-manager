# Builds the .xrnx archive (a zip with manifest.xml and main.lua at its root).
# Only the files the tool needs are included: no tests, scripts, docs,
# development flag or preferences.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts/build-xrnx.ps1
#   powershell -ExecutionPolicy Bypass -File scripts/build-xrnx.ps1 -Tag v1.2.0 -Checksum
#
# -Tag converts a release tag (v1.2.0) to the numeric Version that Renoise
# expects in manifest.xml (major.MMPP, here 1.0200) and names the archive
# com.glitch191.RenoiseAutomationManager-v1.2.0.xrnx.

param(
    [string]$Tag = "",
    [string]$OutDir = "dist",
    [switch]$Checksum
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$BundleId = "com.glitch191.RenoiseAutomationManager"
$Include = @("manifest.xml", "main.lua", "LICENSE")
$IncludeDirs = @("core", "bridge", "ui")

function Convert-TagToVersion([string]$t) {
    if ($t -notmatch '^v?(\d+)\.(\d+)(?:\.(\d+))?$') {
        throw "Tag '$t' is not in the form v1.2.0"
    }
    $major = [int]$Matches[1]
    $minor = [int]$Matches[2]
    $patch = if ($Matches[3]) { [int]$Matches[3] } else { 0 }
    if ($minor -gt 99 -or $patch -gt 99) { throw "Minor and patch numbers must be below 100 (tag '$t')" }
    return ("{0}.{1:D2}{2:D2}" -f $major, $minor, $patch)
}

# Stage the files in a temporary folder.
$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("xrnx-build-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    foreach ($f in $Include) {
        Copy-Item -LiteralPath (Join-Path $root $f) -Destination (Join-Path $stage $f)
    }
    foreach ($d in $IncludeDirs) {
        $target = Join-Path $stage $d
        New-Item -ItemType Directory -Path $target | Out-Null
        Get-ChildItem -LiteralPath (Join-Path $root $d) -Filter *.lua -File | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $target $_.Name)
        }
    }

    $manifestPath = Join-Path $stage "manifest.xml"
    $manifest = [System.IO.File]::ReadAllText($manifestPath)
    if ($Tag) {
        $version = Convert-TagToVersion $Tag
        $manifest = [regex]::Replace($manifest, '<Version>[^<]*</Version>', "<Version>$version</Version>")
        [System.IO.File]::WriteAllText($manifestPath, $manifest, (New-Object System.Text.UTF8Encoding($false)))
        $name = "$BundleId-$Tag.xrnx"
    } else {
        $version = [regex]::Match($manifest, '<Version>([^<]*)</Version>').Groups[1].Value
        $name = "$BundleId.xrnx"
    }

    # Write the zip with forward slash entry names, files at the root.
    $outFull = Join-Path $root $OutDir
    New-Item -ItemType Directory -Force -Path $outFull | Out-Null
    $archive = Join-Path $outFull $name
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::Open($archive, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName | ForEach-Object {
            $rel = $_.FullName.Substring($stage.Length).TrimStart('\', '/').Replace('\', '/')
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, $rel, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    } finally {
        $zip.Dispose()
    }
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force
}

# Verify the archive content.
$zip = [System.IO.Compression.ZipFile]::OpenRead($archive)
try {
    $entries = @($zip.Entries | ForEach-Object { $_.FullName })
} finally {
    $zip.Dispose()
}
$problems = @()
foreach ($required in @("manifest.xml", "main.lua")) {
    if ($entries -notcontains $required) { $problems += "missing $required at the archive root" }
}
foreach ($e in $entries) {
    if ($e -match '^(tests|scripts|docs|\.github|out|dist|\.cache)/') { $problems += "unexpected entry $e" }
    if ($e -match '(^|/)(dev\.flag|preferences\.xml)$') { $problems += "development file $e" }
    if ($e.Contains('\')) { $problems += "backslash in entry $e" }
}
if ($problems.Count -gt 0) {
    $problems | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "Archive check failed."
}

Write-Host "Built $archive (Version $version, $($entries.Count) files)"
$entries | ForEach-Object { Write-Host "  $_" }

if ($Checksum) {
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLower()
    $sumFile = "$archive.sha256"
    [System.IO.File]::WriteAllText($sumFile, "$hash  $name`n", (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "SHA-256 $hash written to $sumFile"
}

# Expose the paths to GitHub Actions when running there.
if ($env:GITHUB_OUTPUT) {
    Add-Content -Path $env:GITHUB_OUTPUT -Value "archive=$archive"
    if ($Checksum) { Add-Content -Path $env:GITHUB_OUTPUT -Value "checksum=$archive.sha256" }
}
