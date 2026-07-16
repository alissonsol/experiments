#!/usr/bin/env pwsh
# Copyright (c) 2026 by Alisson Sol.
# GUID: 42904e29-74d4-42f6-9e7b-b12455edf08e
<#
.SYNOPSIS
  Run the Durable Workflows Lab in a single command on macOS or Windows.

.DESCRIPTION
  One command to launch the lab:
    1. verifies Node.js is installed,
    2. runs `npm install` on the first run,
    3. starts the local server (Node + tsx - no Docker, no external services),
    4. opens the lab in your default browser.

  Cross-platform: works in PowerShell 7+ (pwsh) on macOS / Windows / Linux, and
  in Windows PowerShell 5.1. Ctrl+C stops the server.

.PARAMETER Port
  Port to serve on. Default 3000.

.PARAMETER NoBrowser
  Start the server but don't open a browser.

.PARAMETER Reinstall
  Force `npm install` even if node_modules already exists.

.EXAMPLE
  pwsh ./run-lab.ps1

.EXAMPLE
  pwsh ./run-lab.ps1 -Port 8080

.EXAMPLE
  # Windows PowerShell (if pwsh isn't installed):
  powershell -ExecutionPolicy Bypass -File .\run-lab.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Interactive console tool: colored status output is intentional. On PowerShell 7 Write-Host writes to the information stream and stays redirectable, and Write-Output would corrupt helper function return values.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '',
    Justification = 'False positive: the Start-Job script block declares $u, $win and $mac in its own param() and receives them through -ArgumentList, which is correct; a $using: prefix would be wrong here.')]
[CmdletBinding()]
param(
  [int]$Port = 3000,
  [switch]$NoBrowser,
  [switch]$Reinstall
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Set-Location $root

function Write-Step($m) { Write-Host "  > $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "  + $m" -ForegroundColor Green }
function Write-Bad($m)  { Write-Host "  x $m" -ForegroundColor Red }

# OS detection that works in BOTH Windows PowerShell 5.1 and PowerShell 7+.
# ($env:OS is 'Windows_NT' on all Windows; $IsMacOS only exists in 7+, and
#  macOS never ships 5.1 - so these two checks are sufficient.)
$onWindows = ($env:OS -eq 'Windows_NT')
$onMac     = (-not $onWindows) -and ($IsMacOS -eq $true)

# On Windows, `npm` resolves to npm.ps1, whose argument forwarding is broken
# in PowerShell (multi-arg calls mangle to "Unknown command: pm"). npm.cmd
# forwards args correctly, so use it on Windows and plain `npm` elsewhere.
$npm = if ($onWindows) { 'npm.cmd' } else { 'npm' }

Write-Host ""
Write-Host "  Durable Workflows Lab - Restate vs Temporal (side-by-side)" -ForegroundColor White
Write-Host ""

# --- 0. Sanity: are we in the project? ---
if (-not (Test-Path (Join-Path $root 'package.json'))) {
  Write-Bad "package.json not found next to this script ($root)."
  Write-Host "  Run this script from inside the lab directory."
  exit 1
}

# --- 1. Node.js + npm present? ---
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Write-Bad "Node.js was not found on your PATH."
  Write-Host "  Install Node 18+ from https://nodejs.org  (macOS: 'brew install node')."
  exit 1
}
if (-not (Get-Command $npm -ErrorAction SilentlyContinue)) {
  Write-Bad "npm was not found on your PATH."
  exit 1
}
Write-Ok ("Node.js " + (& node --version))

# --- 2. Dependencies (first run only, unless -Reinstall) ---
if ($Reinstall -or -not (Test-Path (Join-Path $root 'node_modules'))) {
  Write-Step "Installing dependencies (first run)..."
  & $npm install
  if ($LASTEXITCODE -ne 0) { Write-Bad "npm install failed."; exit 1 }
  Write-Ok "Dependencies installed"
}
else {
  Write-Ok "Dependencies already present"
}

$url = "http://localhost:$Port"

# --- 3. Open the browser once the server answers (background) ---
$browserJob = $null
if (-not $NoBrowser) {
  $browserJob = Start-Job -ScriptBlock {
    param($u, $win, $mac)
    for ($i = 0; $i -lt 120; $i++) {
      try { Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 2 | Out-Null; break }
      catch { Start-Sleep -Milliseconds 500 }
    }
    if ($win)     { Start-Process $u }
    elseif ($mac) { & open $u }
    else          { & xdg-open $u }
  } -ArgumentList $url, $onWindows, $onMac
}

# --- 4. Start the server in the foreground (Ctrl+C stops it) ---
Write-Step "Starting the lab at $url"
Write-Host "  (press Ctrl+C to stop)" -ForegroundColor DarkGray
Write-Host ""
$env:PORT = "$Port"
try {
  & $npm start
}
finally {
  if ($browserJob) {
    Stop-Job   $browserJob -ErrorAction SilentlyContinue
    Remove-Job $browserJob -ErrorAction SilentlyContinue
  }
}
