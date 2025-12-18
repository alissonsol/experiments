# Check if running on Windows
if (-not $IsWindows -and (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: This script is Windows-specific and can only run on Windows." -ForegroundColor Red
    Write-Host "Please use the appropriate installation script for your operating system." -ForegroundColor Yellow
    exit 1
}

# For PowerShell versions that don't have $IsWindows (older than 6.0), assume Windows
# since PowerShell on non-Windows systems always defines $IsWindows
if (-not (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue)) {
    # Running on Windows PowerShell (pre-6.0), which is Windows-only
}

# Check if running as Administrator
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "This script requires Administrator privileges to install dependencies for all users." -ForegroundColor Yellow
    Write-Host "Restarting as Administrator..." -ForegroundColor Yellow
    Write-Host ""

    # Get the current script path and directory
    $scriptPath = $MyInvocation.MyCommand.Path
    $scriptDir = Split-Path -Parent $scriptPath

    # Re-launch the script with administrator privileges
    # Use -NoExit to keep window open, and set location to script directory
    $arguments = "-NoExit -NoProfile -ExecutionPolicy Bypass -Command `"Set-Location '$scriptDir'; & '$scriptPath'`""
    Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -Verb RunAs

    # Exit the current non-elevated script
    exit
}

$ErrorActionPreference = "Stop"


Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Installing Dependencies for progresso" -ForegroundColor Cyan
Write-Host "Running as Administrator" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

function Refresh-Path {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
}

function Get-CommandPath {
    param([string]$Command)

    try {
        $cmd = Get-Command $Command -ErrorAction SilentlyContinue
        if ($cmd) {
            return $cmd.Path
        }
    } catch {}

    return $null
}

function Test-ToolInstalled {
    param(
        [string]$Command,
        [string]$Name
    )

    $path = Get-CommandPath $Command
    if ($path) {
        try {
            $version = & $Command --version 2>&1 | Select-Object -First 1
            Write-Host "✓ $Name found at: $path" -ForegroundColor Green
            Write-Host "  Version: $version" -ForegroundColor Gray
            return $true
        } catch {
            Write-Host "⚠ $Name found at $path but failed version check" -ForegroundColor Yellow
            return $false
        }
    }
    return $false
}

function Install-WithWinget {
    param(
        [string]$Name,
        [string]$WingetId,
        [string]$Version = $null,
        [string]$VerifyCommand,
        [bool]$Silent = $true
    )

    Write-Host "→ Installing $Name..." -ForegroundColor Cyan

    $args = @("install", "--id", $WingetId, "--accept-package-agreements", "--accept-source-agreements")

    if ($Silent) {
        $args += "--silent"
    }

    if ($Version) {
        $args += @("--version", $Version, "--force")
    }

    try {
        Write-Host "  Running: winget $($args -join ' ')" -ForegroundColor Gray

        if ($Silent) {
            $output = & winget $args 2>&1 | Out-String
        } else {
            & winget $args
            $output = ""
        }

        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0 -and $output -notlike "*already installed*") {
            Write-Host ""
            Write-Host "  ✗ Installation failed with exit code: $exitCode" -ForegroundColor Red
            if ($output) {
                Write-Host "  Output:" -ForegroundColor Gray
                Write-Host "  $output" -ForegroundColor Gray
            }
            Write-Host ""
            Write-Host "  Troubleshooting steps:" -ForegroundColor Yellow
            Write-Host "  1. Run 'winget list $WingetId' to check if already installed" -ForegroundColor White
            Write-Host "  2. Try running this script as Administrator" -ForegroundColor White
            Write-Host "  3. Update winget: winget upgrade --id Microsoft.Winget.Source" -ForegroundColor White
            Write-Host "  4. Manually install from: https://www.winget.run/pkg/$WingetId" -ForegroundColor White
            Write-Host ""
            return $false
        }

        # Refresh PATH after installation
        Refresh-Path

        # Verify installation
        Start-Sleep -Seconds 2
        $path = Get-CommandPath $VerifyCommand

        if ($path) {
            $version = & $VerifyCommand --version 2>&1 | Select-Object -First 1
            Write-Host "  ✓ $Name installed successfully" -ForegroundColor Green
            Write-Host "  Location: $path" -ForegroundColor Gray
            Write-Host "  Version: $version" -ForegroundColor Gray
            Write-Host ""
            return $true
        } else {
            Write-Host ""
            Write-Host "  ⚠ Installation completed but '$VerifyCommand' not found in PATH" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  Troubleshooting steps:" -ForegroundColor Yellow
            Write-Host "  1. Close and reopen your terminal" -ForegroundColor White
            Write-Host "  2. Run this script again to verify" -ForegroundColor White
            Write-Host "  3. Check your PATH manually: `$env:Path" -ForegroundColor White
            Write-Host "  4. Verify installation location exists" -ForegroundColor White
            Write-Host ""
            return $false
        }

    } catch {
        Write-Host ""
        Write-Host "  ✗ Installation error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Troubleshooting steps:" -ForegroundColor Yellow
        Write-Host "  1. Ensure winget is installed and updated" -ForegroundColor White
        Write-Host "  2. Try running as Administrator" -ForegroundColor White
        Write-Host "  3. Check your internet connection" -ForegroundColor White
        Write-Host ""
        return $false
    }
}

# Track results
$results = @{}

# ============================================================================
# STEP 1: Install Rust
# ============================================================================
Write-Host "STEP 1: Rust Installation" -ForegroundColor Cyan
Write-Host "----------------------------------------" -ForegroundColor Cyan
Write-Host ""

if (Test-ToolInstalled -Command "rustc" -Name "Rust") {
    $results.Rust = $true

    # Also check rustup
    if (Get-CommandPath "rustup") {
        $rustupPath = (Get-Command rustup).Path
        Write-Host "✓ rustup found at: $rustupPath" -ForegroundColor Green
    }

    Write-Host ""
} else {
    Write-Host "Rust not found, installing..." -ForegroundColor Yellow
    Write-Host ""

    $results.Rust = Install-WithWinget -Name "Rust" -WingetId "Rustlang.Rustup" -VerifyCommand "rustc" -Silent $false

    if (-not $results.Rust) {
        Write-Host "CRITICAL: Rust installation failed. Cannot proceed." -ForegroundColor Red
        Write-Host ""
        exit 1
    }
}

# Configure Rust toolchain - MSVC only (no GNU toolchain)
Write-Host "Configuring Rust toolchain (MSVC x86_64-pc-windows-msvc only)..." -ForegroundColor Cyan
Write-Host ""

if (Get-CommandPath "rustup") {
    try {
        # First, ensure the default host is set to MSVC to prevent GNU installation
        Write-Host "→ Setting default host to MSVC..." -ForegroundColor Yellow
        & rustup set default-host x86_64-pc-windows-msvc

        # Remove any existing GNU toolchain if present
        Write-Host "→ Checking for and removing any GNU toolchain..." -ForegroundColor Yellow
        $gnuInstalled = & rustup toolchain list | Select-String "gnu"
        if ($gnuInstalled) {
            Write-Host "  Found GNU toolchain, removing..." -ForegroundColor Gray
            & rustup toolchain uninstall stable-x86_64-pc-windows-gnu 2>&1 | Out-Null
            Write-Host "  ✓ GNU toolchain removed" -ForegroundColor Green
        } else {
            Write-Host "  No GNU toolchain found (good)" -ForegroundColor Gray
        }

        # Install MSVC toolchain
        Write-Host "→ Installing MSVC toolchain (x86_64-pc-windows-msvc)..." -ForegroundColor Yellow
        & rustup toolchain install stable-x86_64-pc-windows-msvc --no-self-update

        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ✓ MSVC toolchain installed successfully" -ForegroundColor Green

            Write-Host "→ Setting MSVC as default toolchain..." -ForegroundColor Yellow
            & rustup default stable-x86_64-pc-windows-msvc

            Write-Host "→ Adding rustfmt and clippy components..." -ForegroundColor Yellow
            & rustup component add rustfmt clippy

            if ($LASTEXITCODE -eq 0) {
                Write-Host "  ✓ All components installed successfully" -ForegroundColor Green

                # Verify configuration
                Write-Host "→ Verifying toolchain configuration..." -ForegroundColor Yellow
                $defaultToolchain = & rustup default 2>&1 | Out-String
                if ($defaultToolchain -match "msvc") {
                    Write-Host "  ✓ Default toolchain: $($defaultToolchain.Trim())" -ForegroundColor Green
                    $results.RustComponents = $true
                } else {
                    Write-Host "  ⚠ Warning: Default toolchain may not be MSVC" -ForegroundColor Yellow
                    Write-Host "  Current: $($defaultToolchain.Trim())" -ForegroundColor Gray
                    $results.RustComponents = $false
                }
            } else {
                Write-Host "  ✗ Component installation failed" -ForegroundColor Red
                Write-Host "  Run manually: rustup component add rustfmt clippy" -ForegroundColor Yellow
                $results.RustComponents = $false
            }
        } else {
            Write-Host "  ✗ MSVC toolchain installation failed" -ForegroundColor Red
            $results.RustComponents = $false
        }
    } catch {
        Write-Host "  ✗ Error: $($_.Exception.Message)" -ForegroundColor Red
        $results.RustComponents = $false
    }
} else {
    Write-Host "✗ rustup not found - cannot configure toolchain" -ForegroundColor Red
    Write-Host "  This is unusual - Rust should include rustup" -ForegroundColor Yellow
    Write-Host "  Try reinstalling Rust or restart your terminal" -ForegroundColor Yellow
    $results.RustComponents = $false
}

Write-Host ""

# ============================================================================
# STEP 2: Install Microsoft Visual C++ Build Tools (required for Rust MSVC toolchain)
# ============================================================================
Write-Host "STEP 2: Microsoft Visual C++ Build Tools Installation" -ForegroundColor Cyan
Write-Host "----------------------------------------" -ForegroundColor Cyan
Write-Host ""
Write-Host "NOTE: The MSVC toolchain requires link.exe from Visual Studio Build Tools." -ForegroundColor Gray
Write-Host "      VS Code is NOT sufficient - you need the full Build Tools package." -ForegroundColor Gray
Write-Host ""

# Check if Visual Studio Build Tools are available
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$buildToolsInstalled = $false
$linkExeFound = $false

if (Test-Path $vswhere) {
    try {
        $vsInstances = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json | ConvertFrom-Json
        if ($vsInstances -and $vsInstances.Length -gt 0) {
            $buildToolsInstalled = $true
            Write-Host "✓ Visual C++ Build Tools found" -ForegroundColor Green
            foreach ($instance in $vsInstances) {
                Write-Host "  Version: $($instance.installationVersion)" -ForegroundColor Gray
                Write-Host "  Path: $($instance.installationPath)" -ForegroundColor Gray

                # Try to find link.exe in this instance
                $vcToolsPath = Join-Path $instance.installationPath "VC\Tools\MSVC"
                if (Test-Path $vcToolsPath) {
                    $linkExe = Get-ChildItem -Path $vcToolsPath -Filter "link.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($linkExe) {
                        $linkExeFound = $true
                        Write-Host "  ✓ link.exe found at: $($linkExe.FullName)" -ForegroundColor Green
                    }
                }
            }

            if (-not $linkExeFound) {
                Write-Host "  ⚠ WARNING: Build Tools found but link.exe not detected" -ForegroundColor Yellow
                Write-Host "  You may need to reinstall with the C++ workload selected" -ForegroundColor Yellow
            }
        }
    } catch {
        # vswhere failed, continue to installation
    }
}

if ($buildToolsInstalled -and $linkExeFound) {
    $results.BuildTools = $true
    Write-Host ""
} else {
    if ($buildToolsInstalled -and -not $linkExeFound) {
        Write-Host "Build Tools are installed but link.exe is missing." -ForegroundColor Yellow
        Write-Host "Reinstalling with C++ workload..." -ForegroundColor Yellow
    } else {
        Write-Host "Visual C++ Build Tools not found, installing..." -ForegroundColor Yellow
    }
    Write-Host ""

    # Download and run the VS Build Tools installer directly with proper components
    $installerUrl = "https://aka.ms/vs/17/release/vs_buildtools.exe"
    $installerPath = Join-Path $env:TEMP "vs_buildtools.exe"

    Write-Host "→ Downloading Visual Studio Build Tools installer..." -ForegroundColor Cyan
    try {
        # Download the installer
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $webClient = New-Object System.Net.WebClient
        $webClient.DownloadFile($installerUrl, $installerPath)
        Write-Host "  ✓ Downloaded to: $installerPath" -ForegroundColor Green

        Write-Host "→ Installing Visual C++ Build Tools (this may take several minutes)..." -ForegroundColor Cyan
        Write-Host "  Components: Desktop development with C++, MSVC tools, Windows SDK" -ForegroundColor Gray
        Write-Host ""

        # Run installer with required components for Rust MSVC toolchain
        # --quiet: No UI, no prompts
        # --wait: Wait for installation to complete
        # --norestart: Don't restart automatically
        # --nocache: Don't cache installation files
        # --add: Add specific workloads and components
        $installerArgs = @(
            "--quiet",
            "--wait",
            "--norestart",
            "--nocache",
            "--add", "Microsoft.VisualStudio.Workload.VCTools",
            "--add", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
            "--add", "Microsoft.VisualStudio.Component.Windows11SDK.22621",
            "--add", "Microsoft.VisualStudio.Component.VC.CMake.Project",
            "--includeRecommended"
        )

        Write-Host "  Running: $installerPath $($installerArgs -join ' ')" -ForegroundColor Gray
        $process = Start-Process -FilePath $installerPath -ArgumentList $installerArgs -Wait -PassThru

        if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
            # 0 = success, 3010 = success but reboot required
            if ($process.ExitCode -eq 3010) {
                Write-Host "  ✓ Installation completed (reboot recommended)" -ForegroundColor Green
            } else {
                Write-Host "  ✓ Installation completed successfully" -ForegroundColor Green
            }

            # Verify installation by checking for vswhere and link.exe
            Start-Sleep -Seconds 3
            $vswhereCheck = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
            if (Test-Path $vswhereCheck) {
                $vsInstances = & $vswhereCheck -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json 2>$null | ConvertFrom-Json
                if ($vsInstances -and $vsInstances.Length -gt 0) {
                    Write-Host "  ✓ vswhere confirms VC++ tools installed" -ForegroundColor Green
                    foreach ($instance in $vsInstances) {
                        $vcToolsPath = Join-Path $instance.installationPath "VC\Tools\MSVC"
                        if (Test-Path $vcToolsPath) {
                            $linkExeCheck = Get-ChildItem -Path $vcToolsPath -Filter "link.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
                            if ($linkExeCheck) {
                                Write-Host "  ✓ link.exe found at: $($linkExeCheck.FullName)" -ForegroundColor Green
                                $results.BuildTools = $true
                            }
                        }
                    }
                }
            }

            if (-not $results.BuildTools) {
                Write-Host "  ⚠ Installation completed but verification pending" -ForegroundColor Yellow
                Write-Host "  You may need to restart your terminal for changes to take effect." -ForegroundColor Yellow
                $results.BuildTools = $true  # Assume success since installer completed
            }
        } else {
            Write-Host "  ✗ Installation failed with exit code: $($process.ExitCode)" -ForegroundColor Red
            Write-Host ""
            Write-Host "  Common exit codes:" -ForegroundColor Yellow
            Write-Host "    -1: General error" -ForegroundColor Gray
            Write-Host "    1: Parameters are invalid" -ForegroundColor Gray
            Write-Host "    1602: User cancelled" -ForegroundColor Gray
            Write-Host "    1641: Reboot initiated" -ForegroundColor Gray
            Write-Host ""
            Write-Host "  Try manual installation:" -ForegroundColor Yellow
            Write-Host "  1. Download: https://visualstudio.microsoft.com/downloads/#build-tools-for-visual-studio-2022" -ForegroundColor White
            Write-Host "  2. Run installer and select 'Desktop development with C++'" -ForegroundColor White
            $results.BuildTools = $false
        }

        # Clean up installer
        if (Test-Path $installerPath) {
            Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
        }

    } catch {
        Write-Host "  ✗ Error during installation: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Try manual installation:" -ForegroundColor Yellow
        Write-Host "  1. Download: https://visualstudio.microsoft.com/downloads/#build-tools-for-visual-studio-2022" -ForegroundColor White
        Write-Host "  2. Run installer and select 'Desktop development with C++'" -ForegroundColor White
        $results.BuildTools = $false

        # Clean up installer on error
        if (Test-Path $installerPath) {
            Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ""

# ============================================================================
# STEP 3: Install Bazel
# ============================================================================
Write-Host "STEP 3: Bazel Installation" -ForegroundColor Cyan
Write-Host "----------------------------------------" -ForegroundColor Cyan
Write-Host ""

if (Test-ToolInstalled -Command "bazel" -Name "Bazel") {
    $results.Bazel = $true
    Write-Host ""
} else {
    Write-Host "Bazel not found, installing..." -ForegroundColor Yellow
    Write-Host ""

    $results.Bazel = Install-WithWinget -Name "Bazel" -WingetId "Bazel.Bazel" -VerifyCommand "bazel" -Silent $false

    if (-not $results.Bazel) {
        Write-Host "WARNING: Bazel installation failed." -ForegroundColor Yellow
        Write-Host "You may need to install it manually from: https://bazel.build/install" -ForegroundColor Yellow
        Write-Host ""
    }
}

# ============================================================================
# Final Summary
# ============================================================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Installation Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$allSuccess = $true

foreach ($key in $results.Keys) {
    if ($results[$key]) {
        Write-Host "✓ $key" -ForegroundColor Green
    } else {
        Write-Host "✗ $key" -ForegroundColor Red
        $allSuccess = $false
    }
}

Write-Host ""

if ($allSuccess) {
    Write-Host "All dependencies installed successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "  1. Navigate to services directory and run: cargo build" -ForegroundColor White
    Write-Host "  2. For Windows service functionality, ensure you have admin privileges" -ForegroundColor White
    Write-Host ""
} else {
    Write-Host "Some installations failed. Review the errors above." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "You may need to:" -ForegroundColor Yellow
    Write-Host "  1. Restart your terminal" -ForegroundColor White
    Write-Host "  2. Run this script again" -ForegroundColor White
    Write-Host "  3. Install failed components manually" -ForegroundColor White
    Write-Host ""
}

# ============================================================================
# Open new PowerShell window with dependency information
# ============================================================================
Write-Host "Opening new PowerShell window with dependency information..." -ForegroundColor Cyan
Write-Host ""

# Get the project root directory (parent of scripts directory)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir

# Get the path to the show-dependencies script
$showDepsScript = Join-Path $scriptDir "show-dependencies.ps1"

# Start a new non-elevated PowerShell window at the project root, executing the show-dependencies script
$arguments = "-NoExit -NoProfile -ExecutionPolicy Bypass -Command `"Set-Location '$projectRoot'; & '$showDepsScript'`""
Start-Process -FilePath "powershell.exe" -ArgumentList $arguments

Write-Host "New PowerShell window opened at project root with dependency information." -ForegroundColor Green
Write-Host "You can now close this administrator window." -ForegroundColor Yellow
Write-Host ""
