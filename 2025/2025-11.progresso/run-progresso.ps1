<#
  Copyright (c) 2025 - Alisson Sol
# Runs the Progresso service executable in console mode after ensuring
# `dist\backend\ordem.target.xml` exists. If missing, attempts to copy
# it from `%LOCALAPPDATA%\Ordem\ordem.target.xml`.
#
# Usage: run from repository root (double-click or from PowerShell).
# The script now collects detailed logs and enables Rust backtraces and
# env-logger output to help diagnose runtime errors such as
# "unsupported operation: 'serialize_seq'".
#>

try {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
} catch {
    $scriptDir = Get-Location
}

# Check if the project has been built
function Check-Build {
    param(
        [string]$ServicesDir,
        [string]$ExePath,
        [string]$ScriptDir
    )

    if ((-not (Test-Path $ServicesDir)) -or (-not (Test-Path $ExePath))) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Yellow
        Write-Host "Project Not Built" -ForegroundColor Yellow
        Write-Host "========================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "The executable '$ExePath' was not found." -ForegroundColor Red
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
                # Re-check if executable now exists
                if (-not (Test-Path $ExePath)) {
                    Write-Error "Executable still not found after build: $ExePath"
                    exit 3
                }
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
        Write-Host "This is needed to run the progresso service executable." -ForegroundColor Yellow
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

$servicesDir = Join-Path $scriptDir 'dist\backend'
$exePath = Join-Path $servicesDir 'progresso_service.exe'

# ============================================================================
# Check build and dependencies
# ============================================================================

# First check if the project is built
Check-Build -ServicesDir $servicesDir -ExePath $exePath -ScriptDir $scriptDir

# Then check runtime dependencies
Check-Dependencies

# ============================================================================
# Setup ordem.target.xml
# ============================================================================

$targetFile = Join-Path $servicesDir 'ordem.target.xml'
if (-not (Test-Path $targetFile)) {
    $src = Join-Path $env:LOCALAPPDATA 'Ordem\ordem.target.xml'
    if (Test-Path $src) {
        try {
            Copy-Item -Path $src -Destination $targetFile -Force -ErrorAction Stop
            Write-Host "Copied ordem.target.xml from $src to $targetFile"
        } catch {
            Write-Error "Failed to copy ordem.target.xml from ${src}: $_"
        }
    } else {
        Write-Host "No ordem.target.xml in $servicesDir and none at $src"
    }
}

if (-not (Test-Path $targetFile)) {
    Write-Error "ordem.target.xml is missing. Please provide dist\backend\ordem.target.xml or place one in ${env:LOCALAPPDATA}\Ordem\ordem.target.xml and re-run."
    exit 1
}

Write-Host "Starting progresso_service.exe in console mode (working dir: $servicesDir)"

# Prepare log file and enable verbose Rust logging/backtraces for diagnostics
$logFile = Join-Path $servicesDir 'run-progresso.log'
try {
    if (-not (Test-Path $servicesDir)) { New-Item -ItemType Directory -Path $servicesDir -Force | Out-Null }
    # copy a timestamped backup of the ordem file to help repro issues
    $ts = (Get-Date -Format 'yyyyMMdd.HHmmss')
    $ordemBackup = Join-Path $servicesDir "ordem.target.$ts.backup.xml"
    Copy-Item -Path $targetFile -Destination $ordemBackup -Force -ErrorAction SilentlyContinue
} catch {
    Write-Warning "Could not create backup of ordem.target.xml: $_"
}

# Enable Rust diagnostics for the child process (inherited by child)
$env:RUST_BACKTRACE = '1'
$env:RUST_LOG = 'warn'

Push-Location $servicesDir
try {
    # Run the exe, stream output to console and save to log for later analysis
    & $exePath 2>&1 | Tee-Object -FilePath $logFile
    $exitCode = $LASTEXITCODE
} catch {
    Write-Error "Execution failed: $_"
    $exitCode = 100
} finally {
    Pop-Location
}

if ($exitCode -ne 0) {
    Write-Error "progresso_service.exe exited with code $exitCode"

    Write-Host "--- Diagnostic summary ---"
    Write-Host "Timestamp: $(Get-Date -Format o)"
    Write-Host "Working dir: $servicesDir"
    Write-Host "ordem.target.xml: $targetFile"
    Write-Host "ordem backup (if created): $ordemBackup"
    Write-Host "Log file: $logFile"
    Write-Host "Environment: RUST_BACKTRACE=$($env:RUST_BACKTRACE); RUST_LOG=$($env:RUST_LOG)"

    if (Test-Path $logFile) {
        Write-Host "--- Last 80 lines of log (for quick inspection) ---"
        Get-Content -Path $logFile -Tail 80 | ForEach-Object { Write-Host $_ }
    }

    if (Test-Path $targetFile) {
        Write-Host "--- First 100 lines of ordem.target.xml (for quick inspection) ---"
        Get-Content -Path $targetFile -TotalCount 100 | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host "ordem.target.xml not present for inspection."
    }

    Write-Host "If you see 'unsupported operation: 'serialize_seq'' in the log, enable a full backtrace and inspect $logFile."
    Write-Error "Detailed log and backup written to $servicesDir. Re-run with the same script and attach $logFile when reporting the issue."
}

exit $exitCode

