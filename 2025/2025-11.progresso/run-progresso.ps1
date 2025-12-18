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

$servicesDir = Join-Path $scriptDir 'dist\backend'
$targetFile = Join-Path $servicesDir 'ordem.target.xml'

if (-not (Test-Path $servicesDir)) {
    Write-Error "Expected directory not found: $servicesDir. Ensure the distribution is built."
    exit 2
}

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

$exePath = Join-Path $servicesDir 'progresso_service.exe'
if (-not (Test-Path $exePath)) {
    Write-Error "Executable not found: $exePath. Build the distribution before running."
    exit 3
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

