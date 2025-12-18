<#
  Copyright (c) 2025 - Alisson Sol
#>
$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Ordem - Service Ordering Tool" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check if running on Windows
if ($PSVersionTable.Platform -and $PSVersionTable.Platform -ne 'Win32NT') {
    Write-Error "This application only runs on Windows."
    exit 1
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$backendDir = Join-Path $scriptDir "dist\backend"
$uiDir = Join-Path $scriptDir "ui"
$distUiDir = Join-Path $scriptDir "dist\ui"

# Bind address (matches services/retrieve/src/main.rs)
$bind = "127.0.0.1:4000"
$EndpointUrl = "http://$bind"

# Helper: open default browser to a URL (Windows-only script, but keep best-effort)
function Open-Browser($url) {
    try {
        Start-Process $url -ErrorAction Stop
        Write-Host "Opened browser at: $url" -ForegroundColor Green
    } catch {
        Write-Warning "Couldn't open browser automatically. Please open: $url"
    }
}

# ============================================================================
# Check for development environment and dependencies
# ============================================================================
$isDevEnvironment = Test-Path (Join-Path $scriptDir "ui\package.json")

if ($isDevEnvironment) {
    Write-Host "Development environment detected." -ForegroundColor Cyan
    Write-Host ""

    # Check for npm (required for building UI)
    $hasNpm = Get-Command npm -ErrorAction SilentlyContinue
    if (-not $hasNpm) {
        Write-Host "npm is not installed or not in PATH." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "To install Node.js (includes npm):" -ForegroundColor White
        Write-Host "  1. Visit: https://nodejs.org/" -ForegroundColor White
        Write-Host "  2. Download and install the LTS version" -ForegroundColor White
        Write-Host "  3. Restart your terminal" -ForegroundColor White
        Write-Host ""
        Write-Error "Cannot build UI without npm. Please install Node.js and try again."
        exit 1
    }

    # Check for Rust/Cargo (required for building backend)
    $hasCargo = Get-Command cargo -ErrorAction SilentlyContinue
    if (-not $hasCargo) {
        Write-Host "cargo is not installed or not in PATH." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "To install Rust (includes cargo):" -ForegroundColor White
        Write-Host "  1. Visit: https://rustup.rs/" -ForegroundColor White
        Write-Host "  2. Download and run rustup-init.exe" -ForegroundColor White
        Write-Host "  3. Restart your terminal" -ForegroundColor White
        Write-Host ""
        Write-Error "Cannot build backend without cargo. Please install Rust and try again."
        exit 1
    }

    Write-Host "✓ npm found: $(npm --version)" -ForegroundColor Green
    Write-Host "✓ cargo found: $(cargo --version)" -ForegroundColor Green
    Write-Host ""

    # Check if UI dependencies are installed
    $nodeModulesPath = Join-Path $uiDir "node_modules"
    if (-not (Test-Path $nodeModulesPath)) {
        Write-Host "Installing UI dependencies..." -ForegroundColor Yellow
        Push-Location $uiDir
        try {
            npm install --omit=dev
            Write-Host "✓ UI dependencies installed" -ForegroundColor Green
        } finally {
            Pop-Location
        }
        Write-Host ""
    }

    # Check if build is needed
    $needsBuild = $false
    $backendExe = Get-ChildItem -Path $backendDir -Filter "*.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $backendExe) {
        Write-Host "Backend executable not found - build required" -ForegroundColor Yellow
        $needsBuild = $true
    }

    if (-not (Test-Path (Join-Path $distUiDir "bundle.js"))) {
        Write-Host "UI bundle not found - build required" -ForegroundColor Yellow
        $needsBuild = $true
    }

    if ($needsBuild) {
        Write-Host ""
        Write-Host "Building application..." -ForegroundColor Yellow
        $buildScript = Join-Path $scriptDir "scripts\build-all.ps1"
        if (Test-Path $buildScript) {
            & $buildScript
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Build failed. Cannot start application."
                exit 1
            }
        } else {
            Write-Error "Build script not found at: $buildScript"
            exit 1
        }
        Write-Host ""
    }
}

# ============================================================================
# Find and validate backend executable
# ============================================================================
$backendExe = Get-ChildItem -Path $backendDir -Filter "*.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1

if (-not $backendExe) {
    Write-Error "Backend executable not found in: $backendDir"
    Write-Host ""
    if ($isDevEnvironment) {
        Write-Host "Please run the build script: .\scripts\build-all.ps1" -ForegroundColor Yellow
    } else {
        Write-Host "This distribution package appears to be incomplete." -ForegroundColor Yellow
    }
    Write-Host ""
    exit 1
}

# ============================================================================
# Check for VC++ Redistributable (required for Rust executables)
# ============================================================================
Write-Host "Checking runtime dependencies..." -ForegroundColor Cyan

# Check if vcruntime140.dll is available
$vcRuntimeFound = $false
$systemPaths = @(
    "$env:SystemRoot\System32",
    "$env:SystemRoot\SysWOW64"
)

foreach ($path in $systemPaths) {
    if (Test-Path (Join-Path $path "vcruntime140.dll")) {
        $vcRuntimeFound = $true
        break
    }
}

if (-not $vcRuntimeFound) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "Missing Runtime Dependency" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "The Microsoft Visual C++ Redistributable is required but not found." -ForegroundColor Yellow
    Write-Host "This is needed to run the ordem service executable." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Attempting to install it automatically using winget..." -ForegroundColor Cyan
    Write-Host ""

    # Check if winget is available
    $hasWinget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $hasWinget) {
        Write-Host "winget is not available on this system." -ForegroundColor Red
        Write-Host ""
        Write-Host "Please install the Microsoft Visual C++ Redistributable manually:" -ForegroundColor White
        Write-Host "  1. Visit: https://aka.ms/vs/17/release/vc_redist.x64.exe" -ForegroundColor White
        Write-Host "  2. Download and run the installer" -ForegroundColor White
        Write-Host "  3. Restart this script" -ForegroundColor White
        Write-Host ""
        Write-Error "Cannot continue without VC++ Redistributable."
        exit 1
    }

    Write-Host "Installing Microsoft Visual C++ Redistributable 2015-2022..." -ForegroundColor Yellow
    try {
        # Install VC++ Redistributable using winget
        $installResult = winget install --id Microsoft.VCRedist.2015+.x64 --exact --accept-package-agreements --accept-source-agreements 2>&1

        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq -1978335189) {
            # Exit code -1978335189 (0x8A15000B) means "No applicable update found" - package already installed
            Write-Host "✓ Microsoft Visual C++ Redistributable is now available" -ForegroundColor Green
            Write-Host ""
        } else {
            Write-Host "Installation may have encountered issues (exit code: $LASTEXITCODE)" -ForegroundColor Yellow
            Write-Host "Output: $installResult" -ForegroundColor Gray
            Write-Host ""
            Write-Host "If the service still fails to start, please install manually:" -ForegroundColor Yellow
            Write-Host "  https://aka.ms/vs/17/release/vc_redist.x64.exe" -ForegroundColor White
            Write-Host ""
        }
    } catch {
        Write-Host "Failed to install VC++ Redistributable automatically." -ForegroundColor Red
        Write-Host "Error: $_" -ForegroundColor Red
        Write-Host ""
        Write-Host "Please install it manually from:" -ForegroundColor White
        Write-Host "  https://aka.ms/vs/17/release/vc_redist.x64.exe" -ForegroundColor White
        Write-Host ""
        Write-Error "Cannot continue without VC++ Redistributable."
        exit 1
    }
} else {
    Write-Host "✓ Microsoft Visual C++ Redistributable found" -ForegroundColor Green
}

Write-Host ""

# Display connection instructions
Write-Host "Starting Ordem server..." -ForegroundColor Yellow
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Connection Instructions:" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  1. The server will start on port 4000" -ForegroundColor White
Write-Host "  2. Open your web browser" -ForegroundColor White
Write-Host "  3. Navigate to: $EndpointUrl" -ForegroundColor Green
Write-Host ""
Write-Host "  The application will be ready in a few seconds..." -ForegroundColor White
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Press Ctrl+C to stop the server." -ForegroundColor Yellow
Write-Host ""

# Open default browser to the running service
Open-Browser $EndpointUrl

# Start the backend
& $backendExe.FullName

