#!/usr/bin/env pwsh
# GUID: 429eccde-4474-49a4-93c2-9bca24a5fb68
# Copyright (c) 2025-2026 by Alisson Sol.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Interactive console tool: colored status output is intentional. On PowerShell 7 Write-Host writes to the information stream and stays redirectable, and Write-Output would corrupt helper function return values.')]
param()

$ErrorActionPreference = 'Stop'

# Navigate to project root and save previous location
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
Push-Location $projectRoot

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Progresso Distribution Packager" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Import-Module (Join-Path $scriptDir "check-dependencies.psm1") -Force

# Check dependencies before creating distribution
if (-not (Test-AllDependencies -RequiredTools @('Cargo'))) {
    Write-Host "Distribution creation cannot proceed without required dependencies." -ForegroundColor Red
    exit 1
}

$repoRoot = $projectRoot
$distDir = Join-Path $repoRoot "dist"
$packageDir = Join-Path $repoRoot "package"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$zipName = "progresso-dist-$timestamp.zip"
$zipPath = Join-Path $repoRoot $zipName

# ============================================================================
# Step 1: Check if backend is running
# ============================================================================
Write-Host "[1/6] Checking for running processes..." -ForegroundColor Yellow

$backendExe = Join-Path $distDir "backend\progresso_service.exe"
if (Test-Path $backendExe) {
    $runningProcess = Get-Process -Name "progresso_service" -ErrorAction SilentlyContinue
    if ($runningProcess) {
        Write-Host ""
        Write-Warning "The backend application is currently running!"
        Write-Host "  Please stop the application before creating a distribution package." -ForegroundColor Yellow
        Write-Host "  You can stop it by running: Stop-Process -Name 'progresso_service'" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
}

Write-Host "  [OK] No running processes detected" -ForegroundColor Green
Write-Host ""

# ============================================================================
# Step 2: Ensure everything is built
# ============================================================================
Write-Host "[2/6] Building application..." -ForegroundColor Yellow

$buildScript = Join-Path $repoRoot "scripts\build-all.ps1"
if (Test-Path $buildScript) {
    & $buildScript
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Build failed. Cannot create distribution package."
        exit 1
    }
} else {
    Write-Error "Build script not found at: $buildScript"
    exit 1
}

Write-Host "  [OK] Build completed successfully" -ForegroundColor Green
Write-Host ""

# ============================================================================
# Step 3: Create package directory structure
# ============================================================================
Write-Host "[3/6] Creating package directory..." -ForegroundColor Yellow

if (Test-Path $packageDir) {
    Remove-Item $packageDir -Recurse -Force
}
New-Item -ItemType Directory -Path $packageDir -Force | Out-Null

# Create dist structure
$packageDistDir = Join-Path $packageDir "dist"
$packageBackendDir = Join-Path $packageDistDir "backend"
$packageUiDir = Join-Path $packageDistDir "ui"

New-Item -ItemType Directory -Path $packageBackendDir -Force | Out-Null
New-Item -ItemType Directory -Path $packageUiDir -Force | Out-Null

# Copy backend executable
$sourceBackendDir = Join-Path $distDir "backend"
if (Test-Path $sourceBackendDir) {
    Get-ChildItem -Path $sourceBackendDir -Filter "*progresso_service*" | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $packageBackendDir -Force
    }
} else {
    Write-Warning "Source backend directory not found: $sourceBackendDir"
}

# Copy UI files if present (common bundle names)
$sourceUiDir = Join-Path $distDir "ui"
if (Test-Path $sourceUiDir) {
    $uiFiles = @('bundle.js','index.html','styles.css')
    foreach ($f in $uiFiles) {
        $src = Join-Path $sourceUiDir $f
        if (Test-Path $src) { Copy-Item -Path $src -Destination $packageUiDir -Force }
    }
}

Write-Host "  [OK] Copied backend and UI files" -ForegroundColor Green
Write-Host ""

# ============================================================================
# Step 4: Copy launcher script if present
# ============================================================================
Write-Host "[4/6] Copying launcher script..." -ForegroundColor Yellow

$sourceLauncher = Join-Path $repoRoot "run-progresso.ps1"
if (Test-Path $sourceLauncher) {
    $launcherPath = Join-Path $packageDir "run-progresso.ps1"
    Copy-Item -Path $sourceLauncher -Destination $launcherPath -Force
    Write-Host "  [OK] Copied run-progresso.ps1" -ForegroundColor Green
} else {
    Write-Host "  - No run-progresso.ps1 found; skipping" -ForegroundColor Yellow
}

Write-Host ""

# ============================================================================
# Step 5: Copy README for distribution
# ============================================================================
Write-Host "[5/6] Copying README..." -ForegroundColor Yellow

$sourceReadme = Join-Path $repoRoot "README.progresso.txt"
if (-not (Test-Path $sourceReadme)) {
    Write-Error "README file not found at: $sourceReadme"
    exit 1
}

$readmePath = Join-Path $packageDir "README.progresso.txt"
Copy-Item -Path $sourceReadme -Destination $readmePath -Force

Write-Host "  [OK] Copied README.progresso.txt" -ForegroundColor Green
Write-Host ""

# ============================================================================
# Step 6: Create ZIP archive
# ============================================================================
Write-Host "[6/6] Creating ZIP archive..." -ForegroundColor Yellow

Compress-Archive -Path "$packageDir\*" -DestinationPath $zipPath -Force

Write-Host "  [OK] Created: $zipName" -ForegroundColor Green
Write-Host ""

Remove-Item $packageDir -Recurse -Force

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Distribution Package Created!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Package: $zipName" -ForegroundColor White
Write-Host "  Size:    $([math]::Round((Get-Item $zipPath).Length / 1MB, 2)) MB" -ForegroundColor White
Write-Host "  Path:    $zipPath" -ForegroundColor White
Write-Host ""

Pop-Location
