# Runs the test suite with LuaJIT (preferred) or a Lua 5.1 interpreter.
# Usage: powershell -ExecutionPolicy Bypass -File scripts/test.ps1 [test name]

param([string]$Only = "")

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$lua = $null
foreach ($candidate in @("luajit", "lua5.1", "lua51", "lua")) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($cmd) { $lua = $cmd.Source; break }
}
if (-not $lua) {
    Write-Error "No Lua interpreter found. Install LuaJIT (for example: winget install DEVCOM.LuaJIT) or Lua 5.1."
    exit 2
}

Write-Host "Using $lua"
if ($Only) { & $lua tests/run.lua $Only } else { & $lua tests/run.lua }
exit $LASTEXITCODE
