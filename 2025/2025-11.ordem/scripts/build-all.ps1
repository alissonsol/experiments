#!/usr/bin/env pwsh
# Copyright (c) 2025 - Alisson Sol
$ErrorActionPreference = 'Stop'
Write-Host "Building Ordem backend and UI into top-level dist/"

# Import dependency checking module
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptDir "check-dependencies.psm1") -Force

# Check dependencies before building
if (-not (Test-AllDependencies -RequiredTools @('Cargo', 'Node', 'npm'))) {
    Write-Host "Build cannot proceed without required dependencies." -ForegroundColor Red
    exit 1
}

$repoRoot = (Get-Location).Path
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
} else {
    Write-Warning "services/retrieve/Cargo.toml not found — skipping backend build"
}

Write-Host "Build-all finished. Artifacts are under $dist"
