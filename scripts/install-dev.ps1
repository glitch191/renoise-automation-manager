# Installs the tool into the Renoise tools folder for development.
# No administrator rights are needed: a directory junction is used.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts/install-dev.ps1            (junction to this folder)
#   powershell -ExecutionPolicy Bypass -File scripts/install-dev.ps1 -Copy      (plain copy, no auto reload)
#   powershell -ExecutionPolicy Bypass -File scripts/install-dev.ps1 -RenoiseVersion 3.5.4
#   powershell -ExecutionPolicy Bypass -File scripts/install-dev.ps1 -Uninstall
#
# Only %APPDATA%\Renoise\V<version>\Scripts\Tools\com.glitch191.RenoiseAutomationManager.xrnx
# is created, replaced or removed. No other tool is touched.

param(
    [string]$RenoiseVersion = "",
    [switch]$Copy,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$BundleId = "com.glitch191.RenoiseAutomationManager"

$base = Join-Path $env:APPDATA "Renoise"
if (-not (Test-Path -LiteralPath $base)) { throw "Renoise preferences folder not found: $base. Start Renoise once first." }

# Pick the requested version folder, or the highest V<x.y.z> folder.
$folders = Get-ChildItem -LiteralPath $base -Directory | Where-Object { $_.Name -match '^V(\d+(\.\d+)+)$' }
if ($RenoiseVersion) {
    $folder = $folders | Where-Object { $_.Name -eq "V$RenoiseVersion" } | Select-Object -First 1
    if (-not $folder) { throw "No folder V$RenoiseVersion in $base" }
} else {
    $folder = $folders | Sort-Object { [version]($_.Name.Substring(1)) } -Descending | Select-Object -First 1
    if (-not $folder) { throw "No Renoise version folder found in $base" }
}

$tools = Join-Path $folder.FullName "Scripts\Tools"
$target = Join-Path $tools "$BundleId.xrnx"
Write-Host "Renoise folder: $($folder.Name)"

function Test-OurTool([string]$path) {
    $m = Join-Path $path "manifest.xml"
    if (-not (Test-Path -LiteralPath $m)) { return $false }
    return ([System.IO.File]::ReadAllText($m) -match "<Id>$([regex]::Escape($BundleId))</Id>")
}

function Remove-Existing([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    $item = Get-Item -LiteralPath $path -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        # Removing a junction never deletes the folder it points to.
        [System.IO.Directory]::Delete($path)
    } elseif (Test-OurTool $path) {
        Remove-Item -LiteralPath $path -Recurse -Force
    } else {
        throw "$path exists but is not this tool. Nothing was changed."
    }
}

if ($Uninstall) {
    Remove-Existing $target
    $flag = Join-Path $root "dev.flag"
    if (Test-Path -LiteralPath $flag) { Remove-Item -LiteralPath $flag }
    Write-Host "Removed $target"
    exit 0
}

New-Item -ItemType Directory -Force -Path $tools | Out-Null
Remove-Existing $target

if ($Copy) {
    New-Item -ItemType Directory -Path $target | Out-Null
    foreach ($f in @("manifest.xml", "main.lua", "LICENSE")) {
        Copy-Item -LiteralPath (Join-Path $root $f) -Destination $target
    }
    foreach ($d in @("core", "bridge", "ui")) {
        New-Item -ItemType Directory -Path (Join-Path $target $d) | Out-Null
        Copy-Item -Path (Join-Path $root "$d\*.lua") -Destination (Join-Path $target $d)
    }
    Write-Host "Copied the tool to $target"
} else {
    New-Item -ItemType Junction -Path $target -Target $root | Out-Null
    # The flag enables _AUTO_RELOAD_DEBUG; it is git ignored and never packaged.
    Set-Content -LiteralPath (Join-Path $root "dev.flag") -Value "Development install: enables _AUTO_RELOAD_DEBUG." -Encoding ASCII
    Write-Host "Linked $target -> $root (auto reload enabled)"
}
Write-Host "Restart Renoise or use Tools > Reload All Tools."
