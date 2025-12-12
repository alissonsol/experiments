#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Ordem Distribution Packager" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$repoRoot = (Get-Location).Path
$distDir = Join-Path $repoRoot "dist"
$packageDir = Join-Path $repoRoot "package"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$zipName = "ordem-dist-$timestamp.zip"
$zipPath = Join-Path $repoRoot $zipName

# ============================================================================
# Step 0: Check if backend is running
# ============================================================================
Write-Host "[0/4] Checking for running processes..." -ForegroundColor Yellow

$backendExe = Join-Path $distDir "backend\ordem_services_retrieve.exe"
if (Test-Path $backendExe) {
    $runningProcess = Get-Process -Name "ordem_services_retrieve" -ErrorAction SilentlyContinue
    if ($runningProcess) {
        Write-Host ""
        Write-Warning "The backend application is currently running!"
        Write-Host "  Please stop the application before creating a distribution package." -ForegroundColor Yellow
        Write-Host "  You can stop it by pressing Ctrl+C in the terminal where it's running," -ForegroundColor Yellow
        Write-Host "  or by running: Stop-Process -Name 'ordem_services_retrieve'" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
}

Write-Host "  ✓ No running processes detected" -ForegroundColor Green
Write-Host ""

# ============================================================================
# Step 1: Ensure everything is built
# ============================================================================
Write-Host "[1/4] Building application..." -ForegroundColor Yellow

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

Write-Host "  ✓ Build completed successfully" -ForegroundColor Green
Write-Host ""

# ============================================================================
# Step 2: Create package directory structure
# ============================================================================
Write-Host "[2/4] Creating package directory..." -ForegroundColor Yellow

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
Get-ChildItem -Path $sourceBackendDir -Filter "*.exe" | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $packageBackendDir -Force
}

# Copy only necessary UI files (exclude node_modules and package files)
$sourceUiDir = Join-Path $distDir "ui"
Copy-Item -Path (Join-Path $sourceUiDir "bundle.js") -Destination $packageUiDir -Force
Copy-Item -Path (Join-Path $sourceUiDir "index.html") -Destination $packageUiDir -Force
Copy-Item -Path (Join-Path $sourceUiDir "styles.css") -Destination $packageUiDir -Force

Write-Host "  ✓ Copied backend executable" -ForegroundColor Green
Write-Host "  ✓ Copied UI files (bundle.js, index.html, styles.css)" -ForegroundColor Green

# ============================================================================
# Step 3: Copy run-ordem.ps1 launcher script
# ============================================================================
Write-Host "[3/4] Copying launcher script..." -ForegroundColor Yellow

$sourceLauncher = Join-Path $repoRoot "run-ordem.ps1"
if (-not (Test-Path $sourceLauncher)) {
    Write-Error "Launcher script not found at: $sourceLauncher"
    exit 1
}

$launcherPath = Join-Path $packageDir "run-ordem.ps1"
Copy-Item -Path $sourceLauncher -Destination $launcherPath -Force

Write-Host "  ✓ Copied run-ordem.ps1" -ForegroundColor Green

# ============================================================================
# Step 4: Create README for distribution
# ============================================================================
$readmeContent = @'
# Ordem - Service Ordering Tool

## Quick Start

1. Extract this ZIP file to a folder on your Windows computer
2. Open PowerShell in the extracted folder
3. Run: `.\run-ordem.ps1`
4. Open your browser to: http://127.0.0.1:4000

## Requirements

- Windows operating system
- PowerShell (included with Windows)
- No additional runtime dependencies required

## What's Included

- `dist/backend/` - Backend server executable
- `dist/ui/` - Web UI files (HTML, CSS, JavaScript)
- `run-ordem.ps1` - Launcher script

## Usage

The application allows you to:
- View current Windows services and their startup types
- Define target startup configurations
- Reorder services for startup sequence
- Set different end types for services

## Troubleshooting

If you get a PowerShell execution policy error, run:
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

## Support

For issues or questions, refer to the project documentation.
'@

$readmePath = Join-Path $packageDir "README.txt"
Set-Content -Path $readmePath -Value $readmeContent -Encoding UTF8

Write-Host "  ✓ Created README.txt" -ForegroundColor Green
Write-Host ""

# ============================================================================
# Step 5: Create ZIP archive
# ============================================================================
Write-Host "[4/4] Creating ZIP archive..." -ForegroundColor Yellow

Compress-Archive -Path "$packageDir\*" -DestinationPath $zipPath -Force

Write-Host "  ✓ Created: $zipName" -ForegroundColor Green
Write-Host ""

# Clean up package directory
Remove-Item $packageDir -Recurse -Force

# ============================================================================
# Summary
# ============================================================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Distribution Package Created!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Package: $zipName" -ForegroundColor White
Write-Host "  Size:    $([math]::Round((Get-Item $zipPath).Length / 1MB, 2)) MB" -ForegroundColor White
Write-Host "  Path:    $zipPath" -ForegroundColor White
Write-Host ""
Write-Host "To distribute:" -ForegroundColor Yellow
Write-Host "  1. Send the ZIP file to the target computer" -ForegroundColor White
Write-Host "  2. Extract the ZIP file" -ForegroundColor White
Write-Host "  3. Run: .\run-ordem.ps1" -ForegroundColor White
Write-Host ""

