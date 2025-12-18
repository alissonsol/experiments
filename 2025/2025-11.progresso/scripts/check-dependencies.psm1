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
    'Test-AllDependencies'
)
