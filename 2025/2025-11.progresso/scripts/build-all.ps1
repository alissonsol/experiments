#!/usr/bin/env pwsh
# Copyright (c) 2025 - Alisson Sol
$ErrorActionPreference = 'Stop'

# Navigate to project root and save previous location
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
Push-Location $projectRoot

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Progresso: Build All" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Import dependency checking module
Import-Module (Join-Path $scriptDir "check-dependencies.psm1") -Force

# Check dependencies before building
if (-not (Test-AllDependencies -RequiredTools @('Cargo'))) {
    Write-Host "Build cannot proceed without required dependencies." -ForegroundColor Red
    exit 1
}

# Initialize MSVC build environment (required for Rust to find link.exe)
Write-Host ""
if (-not (Initialize-MSVCEnvironment)) {
    Write-Host ""
    Write-Host "Failed to initialize MSVC build environment." -ForegroundColor Red
    Write-Host "Rust requires MSVC toolchain to link executables on Windows." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "This error typically occurs when:" -ForegroundColor Yellow
    Write-Host "  - Visual Studio Build Tools are not installed" -ForegroundColor White
    Write-Host "  - The 'Desktop development with C++' workload is missing" -ForegroundColor White
    Write-Host "  - link.exe is not in PATH and cannot be automatically located" -ForegroundColor White
    Write-Host ""
    Write-Host "To fix this issue, run: .\scripts\install-dependencies.ps1" -ForegroundColor Cyan
    Write-Host ""
    exit 1
}
Write-Host ""

# NOTE: This script uses Cargo instead of Bazel due to Windows symlink limitations.
# Bazel's rules_rust (crate_universe) requires symlink creation which needs either:
# - Windows Developer Mode enabled, OR
# - Administrator privileges
# To use Bazel instead, enable Developer Mode in Windows Settings > Privacy & Security > For developers
# Then run: bazel build //:progresso_service

$repoRoot = $projectRoot
$distDir = Join-Path $repoRoot "dist"

Write-Host "[1/2] Building progresso_service with Cargo..." -ForegroundColor Yellow

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    Write-Error "Cargo not found on PATH. Install Rust toolchain from https://rustup.rs/"
    exit 1
}

# Inform users about potential antivirus interference
$targetDir = Join-Path $repoRoot "services\progresso_service\target"
Write-Host ""
Write-Host "Note: Rust build generates temporary build-script-build.exe files." -ForegroundColor Cyan
Write-Host "If your antivirus interferes, add an exclusion for: $targetDir" -ForegroundColor Cyan
Write-Host "See README.md 'Antivirus Configuration' section for details." -ForegroundColor Cyan
Write-Host ""

# Build the progresso_service using Cargo
$serviceDir = Join-Path $repoRoot "services\progresso_service"
Push-Location $serviceDir
try {
    & cargo build --release
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Cargo build failed"
        exit 1
    }
} finally {
    Pop-Location
}

Write-Host "  ✓ Cargo build completed" -ForegroundColor Green
Write-Host ""

Write-Host "[2/2] Collecting build outputs..." -ForegroundColor Yellow

# Ensure dist backend dir
$backendDist = Join-Path $distDir "backend"
if (Test-Path $backendDist) { Remove-Item $backendDist -Recurse -Force }
New-Item -ItemType Directory -Path $backendDist -Force | Out-Null

# Find built binary produced by Cargo
# When a specific target is set in .cargo/config.toml, output goes to target/<target>/release
$cargoTarget = Join-Path $serviceDir "target\x86_64-pc-windows-msvc\release\progresso_service.exe"
if (-not (Test-Path $cargoTarget)) {
    # Fallback to default location if target-specific path doesn't exist
    $cargoTarget = Join-Path $serviceDir "target\release\progresso_service.exe"
}
if (Test-Path $cargoTarget) {
    Copy-Item -Path $cargoTarget -Destination $backendDist -Force
    Write-Host "  ✓ Copied progresso_service.exe to dist/backend" -ForegroundColor Green
} else {
    Write-Warning "No progresso_service.exe found at expected location: $cargoTarget"
}

Write-Host ""
Write-Host "Build finished." -ForegroundColor Cyan

# Return to previous location
Pop-Location
