#!/usr/bin/env pwsh
# Copyright (c) 2025 - Alisson Sol
$ErrorActionPreference = 'Stop'

# Import dependency checking module
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptDir "check-dependencies.psm1") -Force

Write-Host "This script will remove the top-level dist/ folder and optional Bazel outputs."
Write-Host "It can also run 'bazel clean --expunge' and 'git clean -fdx' if you confirm."

# Note: For clean operations, we don't strictly require all dependencies,
# but we'll inform the user if any are missing for informational purposes
Test-AllDependencies -RequiredTools @('Bazel') -Quiet $false | Out-Null

Write-Host ""
$confirm = Read-Host "Type YES to continue and perform the clean (case-sensitive)"
if ($confirm -ne 'YES') {
    Write-Host "Aborted by user. No changes made."
    exit 0
}

function Remove-IfExists($path) {
    if (Test-Path $path) {
        Write-Host "Removing: $path"
        try { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop } catch {
            Write-Warning ("Failed to remove {0}: {1}" -f $path, $_)
        }
    }
}

$repoRoot = (Get-Location).Path

# Remove top-level dist folder
Remove-IfExists (Join-Path $repoRoot "dist")

# Also remove legacy ui/node_modules and services/retrieve/target if present
Remove-IfExists (Join-Path $repoRoot "ui\node_modules")
Remove-IfExists (Join-Path $repoRoot "services\retrieve\target")

# Bazel common output dirs (but keep the bazel/ package folder present)
Get-ChildItem -Path $repoRoot -Directory -Filter "bazel-*" -ErrorAction SilentlyContinue | ForEach-Object { Remove-IfExists $_.FullName }
Remove-IfExists (Join-Path $repoRoot "bazel-bin")
Remove-IfExists (Join-Path $repoRoot "bazel-out")
Remove-IfExists (Join-Path $repoRoot "bazel-testlogs")

# Remove marker files we may have generated
Get-ChildItem -Path $repoRoot -Recurse -Include "ui_dist_marker.txt","rust_build_marker.txt" -File -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "Removing marker file: $($_.FullName)"
    Remove-IfExists $_.FullName
}

# Run bazel clean --expunge if bazel is available
if (Get-Command bazel -ErrorAction SilentlyContinue) {
    $doBazel = Read-Host "Detected 'bazel' in PATH. Run 'bazel clean --expunge'? (y/N)"
    if ($doBazel -eq 'y' -or $doBazel -eq 'Y') {
        Write-Host "Running: bazel clean --expunge"
        bazel clean --expunge
    }
}

# Optionally run git clean -fdx to fully return to repo state
if (Get-Command git -ErrorAction SilentlyContinue) {
    $doGitClean = Read-Host "Run 'git clean -fdx' to remove all untracked files (including build artifacts)? (y/N)"
    if ($doGitClean -eq 'y' -or $doGitClean -eq 'Y') {
        Write-Host "Running: git clean -fdx"
        git clean -fdx
        Write-Host "Git clean finished."
    }
}

Write-Host "Clean finished."
