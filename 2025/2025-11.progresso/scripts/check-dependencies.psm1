# Check-Dependencies.psm1
# PowerShell module for checking project dependencies
# Copyright (c) 2025 - Alisson Sol

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

function Test-RustInstalled {
    param([bool]$Quiet = $false)

    $rustcPath = Get-CommandPath "rustc"
    if ($rustcPath) {
        if (-not $Quiet) {
            try {
                $version = & rustc --version 2>&1 | Select-Object -First 1
                Write-Host "  ✓ Rust: $version" -ForegroundColor Green
            } catch {
                Write-Host "  ✓ Rust: Found at $rustcPath" -ForegroundColor Green
            }
        }
        return $true
    }

    if (-not $Quiet) {
        Write-Host "  ✗ Rust (rustc) not found" -ForegroundColor Red
    }
    return $false
}

function Test-CargoInstalled {
    param([bool]$Quiet = $false)

    $cargoPath = Get-CommandPath "cargo"
    if ($cargoPath) {
        if (-not $Quiet) {
            try {
                $version = & cargo --version 2>&1 | Select-Object -First 1
                Write-Host "  ✓ Cargo: $version" -ForegroundColor Green
            } catch {
                Write-Host "  ✓ Cargo: Found at $cargoPath" -ForegroundColor Green
            }
        }
        return $true
    }

    if (-not $Quiet) {
        Write-Host "  ✗ Cargo not found" -ForegroundColor Red
    }
    return $false
}

function Test-MSVCInstalled {
    param([bool]$Quiet = $false)

    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"

    if (Test-Path $vswhere) {
        try {
            $vsInstances = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json 2>$null | ConvertFrom-Json
            if ($vsInstances -and $vsInstances.Length -gt 0) {
                if (-not $Quiet) {
                    $version = $vsInstances[0].installationVersion
                    Write-Host "  ✓ MSVC Build Tools: Version $version" -ForegroundColor Green
                }
                return $true
            }
        } catch {
            # vswhere failed
        }
    }

    if (-not $Quiet) {
        Write-Host "  ✗ MSVC Build Tools not found" -ForegroundColor Red
    }
    return $false
}

function Test-BazelInstalled {
    param([bool]$Quiet = $false)

    $bazelPath = Get-CommandPath "bazel"
    if ($bazelPath) {
        if (-not $Quiet) {
            try {
                $version = & bazel --version 2>&1 | Select-Object -First 1
                Write-Host "  ✓ Bazel: $version" -ForegroundColor Green
            } catch {
                Write-Host "  ✓ Bazel: Found at $bazelPath" -ForegroundColor Green
            }
        }
        return $true
    }

    if (-not $Quiet) {
        Write-Host "  ✗ Bazel not found" -ForegroundColor Red
    }
    return $false
}

function Initialize-MSVCEnvironment {
    <#
    .SYNOPSIS
    Initializes the MSVC build environment for the current PowerShell session.

    .DESCRIPTION
    Locates and runs VsDevCmd.bat to set up the Visual Studio build environment,
    which includes adding link.exe and other MSVC tools to the PATH.
    This is required for Rust to successfully link Windows executables.

    .PARAMETER Quiet
    If $true, suppresses detailed output.

    .EXAMPLE
    Initialize-MSVCEnvironment

    .EXAMPLE
    if (-not (Initialize-MSVCEnvironment -Quiet)) {
        Write-Error "Failed to setup MSVC environment"
        exit 1
    }
    #>
    param([bool]$Quiet = $false)

    # Check if link.exe is already in PATH (environment already initialized)
    if (Get-Command link.exe -ErrorAction SilentlyContinue) {
        if (-not $Quiet) {
            Write-Host "  ✓ MSVC environment already initialized (link.exe found in PATH)" -ForegroundColor Green
        }
        return $true
    }

    if (-not $Quiet) {
        Write-Host ""
        Write-Host "Initializing MSVC build environment..." -ForegroundColor Cyan
    }

    # Locate Visual Studio installation using vswhere
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"

    if (-not (Test-Path $vswhere)) {
        if (-not $Quiet) {
            Write-Host "  ✗ vswhere.exe not found - Visual Studio may not be installed" -ForegroundColor Red
            Write-Host ""
            Write-Host "To fix this issue:" -ForegroundColor Yellow
            Write-Host "  1. Install Visual Studio Build Tools or Visual Studio" -ForegroundColor White
            Write-Host "  2. Make sure to include 'Desktop development with C++' workload" -ForegroundColor White
            Write-Host "  3. Or run: .\scripts\install-dependencies.ps1" -ForegroundColor Cyan
            Write-Host ""
        }
        return $false
    }

    # Find VS installation with C++ build tools
    try {
        $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null

        if (-not $vsPath) {
            if (-not $Quiet) {
                Write-Host "  ✗ Visual Studio installation with C++ tools not found" -ForegroundColor Red
                Write-Host ""
                Write-Host "To fix this issue:" -ForegroundColor Yellow
                Write-Host "  1. Install Visual Studio Build Tools or Visual Studio" -ForegroundColor White
                Write-Host "  2. Make sure to include 'Desktop development with C++' workload" -ForegroundColor White
                Write-Host "  3. Or run: .\scripts\install-dependencies.ps1" -ForegroundColor Cyan
                Write-Host ""
            }
            return $false
        }

        # Locate VsDevCmd.bat
        $vsDevCmd = Join-Path $vsPath "Common7\Tools\VsDevCmd.bat"

        if (-not (Test-Path $vsDevCmd)) {
            if (-not $Quiet) {
                Write-Host "  ✗ VsDevCmd.bat not found at: $vsDevCmd" -ForegroundColor Red
            }
            return $false
        }

        if (-not $Quiet) {
            Write-Host "  Found Visual Studio at: $vsPath" -ForegroundColor Gray
        }

        # Run VsDevCmd.bat and capture environment variables
        # We use cmd.exe to run the batch file, then export all environment variables
        $tempFile = [System.IO.Path]::GetTempFileName()

        # Run VsDevCmd.bat in cmd.exe, then output all environment variables to temp file
        & cmd.exe /c "`"$vsDevCmd`" -no_logo && set" | Out-File -FilePath $tempFile -Encoding ASCII

        # Parse environment variables and set them in current session
        Get-Content $tempFile | ForEach-Object {
            if ($_ -match '^([^=]+)=(.*)$') {
                $name = $matches[1]
                $value = $matches[2]

                # Update current session environment
                Set-Item -Path "env:$name" -Value $value -ErrorAction SilentlyContinue
            }
        }

        # Clean up temp file
        Remove-Item $tempFile -ErrorAction SilentlyContinue

        # Verify that link.exe is now available
        if (Get-Command link.exe -ErrorAction SilentlyContinue) {
            if (-not $Quiet) {
                Write-Host "  ✓ MSVC environment initialized successfully" -ForegroundColor Green
                $linkPath = (Get-Command link.exe).Path
                Write-Host "  ✓ link.exe found at: $linkPath" -ForegroundColor Green
            }
            return $true
        } else {
            if (-not $Quiet) {
                Write-Host "  ✗ MSVC environment setup completed but link.exe still not found" -ForegroundColor Red
                Write-Host ""
                Write-Host "This may indicate an incomplete Visual Studio installation." -ForegroundColor Yellow
                Write-Host "Try reinstalling with the 'Desktop development with C++' workload." -ForegroundColor Yellow
                Write-Host ""
            }
            return $false
        }

    } catch {
        if (-not $Quiet) {
            Write-Host "  ✗ Error initializing MSVC environment: $_" -ForegroundColor Red
        }
        return $false
    }
}

function Test-AllDependencies {
    <#
    .SYNOPSIS
    Checks all required dependencies for the progresso project.

    .DESCRIPTION
    Validates that all required tools are installed and available on the system PATH.
    Returns $true if all dependencies are met, $false otherwise.

    .PARAMETER Quiet
    If $true, suppresses detailed output and only returns the result.

    .PARAMETER RequiredTools
    Array of tool names to check. Valid values: 'Rust', 'Cargo', 'MSVC', 'Bazel'
    If not specified, checks all tools.

    .EXAMPLE
    Test-AllDependencies

    .EXAMPLE
    Test-AllDependencies -RequiredTools @('Rust', 'Cargo')

    .EXAMPLE
    if (-not (Test-AllDependencies -Quiet)) { exit 1 }
    #>
    param(
        [bool]$Quiet = $false,
        [string[]]$RequiredTools = @('Rust', 'Cargo', 'MSVC', 'Bazel')
    )

    if (-not $Quiet) {
        Write-Host ""
        Write-Host "Checking dependencies..." -ForegroundColor Cyan
    }

    $allInstalled = $true
    $missingTools = @()

    foreach ($tool in $RequiredTools) {
        $isInstalled = switch ($tool) {
            'Rust'  { Test-RustInstalled -Quiet $Quiet }
            'Cargo' { Test-CargoInstalled -Quiet $Quiet }
            'MSVC'  { Test-MSVCInstalled -Quiet $Quiet }
            'Bazel' { Test-BazelInstalled -Quiet $Quiet }
            default {
                Write-Warning "Unknown tool: $tool"
                $false
            }
        }

        if (-not $isInstalled) {
            $allInstalled = $false
            $missingTools += $tool
        }
    }

    if (-not $Quiet) {
        Write-Host ""

        if ($allInstalled) {
            Write-Host "All required dependencies are installed." -ForegroundColor Green
        } else {
            Write-Host "Missing dependencies detected!" -ForegroundColor Red
            Write-Host ""
            Write-Host "Missing tools:" -ForegroundColor Yellow
            foreach ($tool in $missingTools) {
                Write-Host "  - $tool" -ForegroundColor Yellow
            }
            Write-Host ""
            Write-Host "To install missing dependencies, run:" -ForegroundColor Cyan

            $scriptDir = Split-Path -Parent $PSScriptRoot
            if (-not $scriptDir) { $scriptDir = $PSScriptRoot }
            $installScript = Join-Path $scriptDir "scripts\install-dependencies.ps1"

            if (Test-Path $installScript) {
                Write-Host "  .\scripts\install-dependencies.ps1" -ForegroundColor White
            } else {
                Write-Host "  .\install-dependencies.ps1" -ForegroundColor White
            }
            Write-Host ""
        }
    }

    return $allInstalled
}

# Export module functions
Export-ModuleMember -Function @(
    'Get-CommandPath',
    'Test-RustInstalled',
    'Test-CargoInstalled',
    'Test-MSVCInstalled',
    'Test-BazelInstalled',
    'Test-AllDependencies',
    'Initialize-MSVCEnvironment'
)
