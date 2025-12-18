#!/usr/bin/env pwsh
# Copyright (c) 2025 - Alisson Sol
$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Progresso: Build All" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Import dependency checking module
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptDir "check-dependencies.psm1") -Force

# Check dependencies before building
if (-not (Test-AllDependencies -RequiredTools @('Cargo'))) {
    Write-Host "Build cannot proceed without required dependencies." -ForegroundColor Red
    exit 1
}

# NOTE: This script uses Cargo instead of Bazel due to Windows symlink limitations.
# Bazel's rules_rust (crate_universe) requires symlink creation which needs either:
# - Windows Developer Mode enabled, OR
# - Administrator privileges
# To use Bazel instead, enable Developer Mode in Windows Settings > Privacy & Security > For developers
# Then run: bazel build //:progresso_service

$repoRoot = (Get-Location).Path
$distDir = Join-Path $repoRoot "dist"

Write-Host "[1/2] Building progresso_service with Cargo..." -ForegroundColor Yellow

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    Write-Error "Cargo not found on PATH. Install Rust toolchain from https://rustup.rs/"
    exit 1
}

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
