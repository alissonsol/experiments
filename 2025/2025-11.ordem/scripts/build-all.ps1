#!/usr/bin/env pwsh
# Copyright (c) 2025 - Alisson Sol
$ErrorActionPreference = 'Stop'

# Navigate to project root and save previous location
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
Push-Location $projectRoot

Write-Host "Building Ordem backend and UI into top-level dist/"

# Import dependency checking module
Import-Module (Join-Path $scriptDir "check-dependencies.psm1") -Force

# Check dependencies before building
if (-not (Test-AllDependencies -RequiredTools @('Cargo', 'Node', 'npm'))) {
    Write-Host "Build cannot proceed without required dependencies." -ForegroundColor Red
    exit 1
}

$repoRoot = $projectRoot
$dist = Join-Path $repoRoot "dist"

if (-not (Test-Path $dist)) { New-Item -ItemType Directory -Path $dist | Out-Null }

# Build UI: output to dist/ui
if (Test-Path "ui/package.json") {
    Write-Host "Building UI into $dist/ui"
    $uiDist = Join-Path $dist "ui"
    if (Test-Path $uiDist) { Remove-Item $uiDist -Recurse -Force }
    New-Item -ItemType Directory -Path $uiDist | Out-Null

    Push-Location "ui"
    try {
        if (Get-Command npm -ErrorAction SilentlyContinue) {
            # Build bundle to top-level dist/ui (use relative path so esbuild creates the file)
            npx --yes esbuild src/main.ts --bundle --outfile="../dist/ui/bundle.js" --minify
            # Copy static files
            Copy-Item -Path "index.html" -Destination $uiDist -Force
            Copy-Item -Path "src/styles.css" -Destination $uiDist -Force

            # Copy package.json to dist/ui and install production dependencies there (optional)
            Copy-Item -Path "package.json" -Destination $uiDist -Force
            Push-Location $uiDist
            try {
                if (Get-Command npm -ErrorAction SilentlyContinue) {
                    npm install --omit=dev --yes
                } else {
                    Write-Warning "npm not found — skipping node_modules install into dist/ui"
                }
            } finally { Pop-Location }

            Write-Host "UI built into $uiDist"
        } else {
            Write-Warning "npm not found in PATH — please install Node.js to build the UI. Skipping UI build."
        }
    } finally { Pop-Location }
} else {
    Write-Warning "ui/package.json not found — skipping UI build"
}

# Build Rust backend and copy binary into dist/backend
if (Test-Path "services/retrieve/Cargo.toml") {
    Write-Host "Building Rust backend and copying artifact into $dist/backend"

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
        Write-Warning "Skipping Rust backend build due to missing MSVC environment"
    } else {
        # Inform users about potential antivirus interference
        $targetDir = Join-Path $repoRoot "services\retrieve\target"
        Write-Host ""
        Write-Host "Note: Rust build generates temporary build-script-build.exe files." -ForegroundColor Cyan
        Write-Host "If your antivirus interferes, add an exclusion for: $targetDir" -ForegroundColor Cyan
        Write-Host "See README.md 'Antivirus Configuration' section for details." -ForegroundColor Cyan
        Write-Host ""

        Push-Location "services/retrieve"
        try {
            if (Get-Command cargo -ErrorAction SilentlyContinue) {
                # Build with stable Rust toolchain
                cargo build --release
                # When a specific target is set in .cargo/config.toml, output goes to target/<target>/release
                # Check both locations for compatibility
                $targetDir = Join-Path (Get-Location).Path "target\x86_64-pc-windows-msvc\release"
                if (-not (Test-Path $targetDir)) {
                    $targetDir = Join-Path (Get-Location).Path "target\release"
                }
                # Determine binary name from Cargo.toml package name
                $cargoToml = Get-Content -Path "Cargo.toml" -Raw
                $nameMatch = [regex]::Match($cargoToml, 'name\s*=\s*"(?<n>[^"]+)"')
                $binName = if ($nameMatch.Success) { $nameMatch.Groups['n'].Value } else { 'ordem_service' }
                $exeName = $binName + ".exe"
                $srcExe = Join-Path $targetDir $exeName
                if (Test-Path $srcExe) {
                    $backendDist = Join-Path $dist "backend"
                    if (-not (Test-Path $backendDist)) { New-Item -ItemType Directory -Path $backendDist | Out-Null }
                    Copy-Item -Path $srcExe -Destination $backendDist -Force
                    Write-Host "Copied backend binary to $backendDist"
                } else {
                    Write-Warning "Could not find built backend binary at $srcExe"
                }
            } else {
                Write-Warning "cargo not found in PATH — please install Rust (rustup) to build the backend. Skipping backend build."
            }
        } finally { Pop-Location }
    }
} else {
    Write-Warning "services/retrieve/Cargo.toml not found — skipping backend build"
}

Write-Host "Build-all finished. Artifacts are under $dist"

# Return to previous location
Pop-Location
