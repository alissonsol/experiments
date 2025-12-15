#!/usr/bin/env pwsh
# Copyright (c) 2025 - Alisson Sol
$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Progresso: Clean All" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$repoRoot = (Get-Location).Path

Write-Host "[1/4] Cleaning Rust target directory..." -ForegroundColor Yellow
$cargoTarget = Join-Path $repoRoot "services\progresso_service\target"
if (Test-Path $cargoTarget) {
    Remove-Item $cargoTarget -Recurse -Force
    Write-Host "  ✓ Removed Rust target directory" -ForegroundColor Green
} else {
    Write-Host "  - No Rust target directory found" -ForegroundColor Gray
}

Write-Host ""
Write-Host "[2/4] Running bazel clean (if available)..." -ForegroundColor Yellow
if (Get-Command bazel -ErrorAction SilentlyContinue) {
    & bazel clean 2>&1 | Out-Null
    Write-Host "  ✓ Bazel clean completed" -ForegroundColor Green
} else {
    Write-Host "  - Bazel not found; skipping" -ForegroundColor Gray
}

Write-Host ""
Write-Host "[3/4] Removing dist and package directories..." -ForegroundColor Yellow
$distDir = Join-Path $repoRoot "dist"
if (Test-Path $distDir) {
    Remove-Item $distDir -Recurse -Force
    Write-Host "  ✓ Removed dist directory" -ForegroundColor Green
} else {
    Write-Host "  - No dist directory found" -ForegroundColor Gray
}

$packageDir = Join-Path $repoRoot "package"
if (Test-Path $packageDir) {
    Remove-Item $packageDir -Recurse -Force
    Write-Host "  ✓ Removed package directory" -ForegroundColor Green
} else {
    Write-Host "  - No package directory found" -ForegroundColor Gray
}

Write-Host ""
Write-Host "[4/4] Removing generated Bazel/Cargo files..." -ForegroundColor Yellow

# Remove generated Cargo.lock from root (if it was copied there)
$rootCargoLock = Join-Path $repoRoot "Cargo.lock"
if (Test-Path $rootCargoLock) {
    Remove-Item $rootCargoLock -Force
    Write-Host "  ✓ Removed root Cargo.lock" -ForegroundColor Green
}

# Remove Bazel symlinks and generated files
$bazelDirs = @("bazel-bin", "bazel-out", "bazel-progresso", "bazel-testlogs")
foreach ($dir in $bazelDirs) {
    $path = Join-Path $repoRoot $dir
    if (Test-Path $path) {
        Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  ✓ Removed $dir" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Clean complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
