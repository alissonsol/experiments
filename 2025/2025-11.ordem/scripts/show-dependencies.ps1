# Copyright (c) 2025 - Alisson Sol
Write-Host '========================================'  -ForegroundColor Cyan
Write-Host 'ordem Project - Installed Dependencies' -ForegroundColor Cyan
Write-Host '========================================'  -ForegroundColor Cyan
Write-Host ''

# Display Rust version
if (Get-Command rustc -ErrorAction SilentlyContinue) {
    $rustVersion = rustc --version 2>&1 | Select-Object -First 1
    Write-Host 'Rust:' -ForegroundColor Green -NoNewline
    Write-Host " $rustVersion" -ForegroundColor White

    if (Get-Command cargo -ErrorAction SilentlyContinue) {
        $cargoVersion = cargo --version 2>&1 | Select-Object -First 1
        Write-Host 'Cargo:' -ForegroundColor Green -NoNewline
        Write-Host " $cargoVersion" -ForegroundColor White
    }

    if (Get-Command rustup -ErrorAction SilentlyContinue) {
        $rustupVersion = rustup --version 2>&1 | Select-Object -First 1
        Write-Host 'Rustup:' -ForegroundColor Green -NoNewline
        Write-Host " $rustupVersion" -ForegroundColor White
    }
} else {
    Write-Host 'Rust: Not found' -ForegroundColor Red
}

Write-Host ''

# Display Visual C++ Build Tools status
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    try {
        $vsInstances = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json 2>$null | ConvertFrom-Json
        if ($vsInstances -and $vsInstances.Length -gt 0) {
            Write-Host 'Visual C++ Build Tools:' -ForegroundColor Green -NoNewline
            Write-Host " Installed (Version $($vsInstances[0].installationVersion))" -ForegroundColor White
        } else {
            Write-Host 'Visual C++ Build Tools: Not found' -ForegroundColor Red
        }
    } catch {
        Write-Host 'Visual C++ Build Tools: Status unknown' -ForegroundColor Yellow
    }
} else {
    Write-Host 'Visual C++ Build Tools: Not found' -ForegroundColor Red
}

Write-Host ''

# Display Bazel version
if (Get-Command bazel -ErrorAction SilentlyContinue) {
    $bazelVersion = bazel --version 2>&1 | Select-Object -First 1
    Write-Host 'Bazel:' -ForegroundColor Green -NoNewline
    Write-Host " $bazelVersion" -ForegroundColor White
} else {
    Write-Host 'Bazel: Not found' -ForegroundColor Red
}

Write-Host ''

# Display Node.js version
if (Get-Command node -ErrorAction SilentlyContinue) {
    $nodeVersion = node --version 2>&1
    Write-Host 'Node.js:' -ForegroundColor Green -NoNewline
    Write-Host " $nodeVersion" -ForegroundColor White

    if (Get-Command npm -ErrorAction SilentlyContinue) {
        $npmVersion = npm --version 2>&1
        Write-Host 'npm:' -ForegroundColor Green -NoNewline
        Write-Host " v$npmVersion" -ForegroundColor White
    }
} else {
    Write-Host 'Node.js: Not found' -ForegroundColor Red
}

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host 'All dependencies are now in your PATH' -ForegroundColor Green
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ''
