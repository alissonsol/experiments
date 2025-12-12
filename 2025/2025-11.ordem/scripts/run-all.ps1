#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Ordem Run-All Script" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$repoRoot = (Get-Location).Path
$dist = Join-Path $repoRoot "dist"

# ============================================================================
# Step 1: Build UI to dist/ui
# ============================================================================
if (Test-Path "ui/package.json") {
    Write-Host "[1/2] Building UI to dist/ui..." -ForegroundColor Yellow

    $uiDist = Join-Path $dist "ui"
    if (Test-Path $uiDist) { Remove-Item $uiDist -Recurse -Force }
    New-Item -ItemType Directory -Path $uiDist -Force | Out-Null

    Push-Location "ui"
    try {
        if (Get-Command npm -ErrorAction SilentlyContinue) {
            # Build bundle to top-level dist/ui
            npx esbuild src/main.ts --bundle --outfile="../dist/ui/bundle.js" --minify
            # Copy static files
            Copy-Item -Path "index.html" -Destination (Join-Path $uiDist "index.html") -Force
            Copy-Item -Path "src/styles.css" -Destination (Join-Path $uiDist "styles.css") -Force

            Write-Host "  ✓ UI built successfully to: $uiDist" -ForegroundColor Green
        } else {
            Write-Warning "  npm not found in PATH — skipping UI build. Install Node.js to build the UI."
            Write-Host "  The backend will run without UI (API only)" -ForegroundColor Yellow
        }
    } finally { Pop-Location }
} else {
    Write-Host "[1/2] No UI found (ui/package.json missing) — skipping UI build" -ForegroundColor Yellow
}

Write-Host ""

# ============================================================================
# Step 2: Start Backend (which serves both API and UI)
# ============================================================================
Write-Host "[2/2] Starting Backend..." -ForegroundColor Yellow

# Determine backend source
$backendSource = $null
$backendExe = $null

# Option 1: Use pre-built binary from dist/backend
if (Test-Path "dist\backend") {
    $backendDir = Join-Path (Get-Location).Path "dist\backend"
    $exe = Get-ChildItem -Path $backendDir -Filter "*.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exe) {
        $backendSource = "dist/backend (pre-built binary)"
        $backendExe = $exe.FullName
    }
}

# Option 2: Build and run from source
if (-not $backendExe) {
    if (-not (Test-Path "services/retrieve/Cargo.toml")) {
        Write-Error "Backend not found at services/retrieve/Cargo.toml. Can't start service."
        exit 1
    }

    if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
        Write-Error "cargo not found in PATH. Install Rust (rustup) and restart your shell to run the backend."
        Write-Host "As a fallback you can run the UI dev server separately: ./scripts/run-ui.ps1" -ForegroundColor Yellow
        exit 1
    }

    $backendSource = "services/retrieve (cargo run --release)"
}

# Display configuration
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Configuration:" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Backend Source: $backendSource" -ForegroundColor White
Write-Host "  Backend URL:    http://127.0.0.1:4000" -ForegroundColor White

if (Test-Path (Join-Path $dist "ui")) {
    Write-Host "  UI Source:      dist/ui (served by backend)" -ForegroundColor White
    Write-Host "  UI URL:         http://127.0.0.1:4000 (same as backend)" -ForegroundColor White
    Write-Host ""
    Write-Host "  ✓ Single endpoint: Backend serves both API and UI" -ForegroundColor Green
} else {
    Write-Host "  UI Source:      NOT FOUND" -ForegroundColor Red
    Write-Host "  UI URL:         N/A (API only mode)" -ForegroundColor Red
    Write-Host ""
    Write-Host "  ⚠ API-only mode: No UI will be served" -ForegroundColor Yellow
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Starting server... Press Ctrl+C to stop." -ForegroundColor Yellow
Write-Host ""

# Start the backend
if ($backendExe) {
    & $backendExe
} else {
    Push-Location "services/retrieve"
    try {
        cargo run --release
    } finally { Pop-Location }
}
