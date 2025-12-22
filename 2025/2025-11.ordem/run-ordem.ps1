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

# Check if the project has been built
function Check-Build {
    param(
        [string]$BackendDir,
        [string]$DistUiDir,
        [string]$ScriptDir
    )

    $backendExe = Get-ChildItem -Path $BackendDir -Filter "*.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    $uiBundleExists = Test-Path (Join-Path $DistUiDir "bundle.js")

    if (-not $backendExe -or -not $uiBundleExists) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Yellow
        Write-Host "Project Not Built" -ForegroundColor Yellow
        Write-Host "========================================" -ForegroundColor Yellow
        Write-Host ""

        if (-not $backendExe) {
            Write-Host "Backend executable not found in: $BackendDir" -ForegroundColor Red
        }
        if (-not $uiBundleExists) {
            Write-Host "UI bundle not found - build required" -ForegroundColor Yellow
        }

        Write-Host "The project needs to be built before running." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Would you like to run the build-all script now? (Y/N)" -ForegroundColor Cyan
        $response = Read-Host

        if ($response -match '^[Yy]') {
            $buildScript = Join-Path $ScriptDir 'scripts\build-all.ps1'
            if (Test-Path $buildScript) {
                Write-Host ""
                Write-Host "Running build-all script..." -ForegroundColor Green
                & $buildScript
                if ($LASTEXITCODE -ne 0) {
                    Write-Error "Build failed. Please fix build errors before running."
                    exit 3
                }
                Write-Host ""
                Write-Host "Build completed successfully. Continuing with run..." -ForegroundColor Green
                Write-Host ""
            } else {
                Write-Error "Build script not found: $buildScript"
                exit 3
            }
        } else {
            Write-Host "Build cancelled. Please run scripts\build-all.ps1 manually and try again." -ForegroundColor Yellow
            exit 3
        }
    }
}

# Check for runtime dependencies (VC++ Redistributable)
function Check-Dependencies {
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
        Write-Host "Please run the install-dependencies script to install it:" -ForegroundColor White
        Write-Host "  scripts\install-dependencies.ps1" -ForegroundColor Cyan
        Write-Host ""
        Write-Error "Cannot continue without VC++ Redistributable."
        exit 1
    } else {
        Write-Host "✓ Microsoft Visual C++ Redistributable found" -ForegroundColor Green
    }

    Write-Host ""
}

# ============================================================================
# Check build and dependencies
# ============================================================================

# First check if the project is built
Check-Build -BackendDir $backendDir -DistUiDir $distUiDir -ScriptDir $scriptDir

# Then check runtime dependencies
Check-Dependencies

# ============================================================================
# Start the application
# ============================================================================

# Find the backend executable
$backendExe = Get-ChildItem -Path $backendDir -Filter "*.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1

if (-not $backendExe) {
    Write-Error "Backend executable not found after build checks. This should not happen."
    exit 1
}

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

