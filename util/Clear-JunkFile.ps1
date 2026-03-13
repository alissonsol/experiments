#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Scans a folder tree and removes common junk/system files (Thumbs.db, .DS_Store, etc.).

.DESCRIPTION
    Recursively scans the target folder for files matching a configurable list of
    junk filenames. Handles hidden, system, and read-only attributes. Displays a
    summary of what will be deleted and asks for confirmation before proceeding.

.PARAMETER Path
    The root folder to scan. Defaults to the current directory.

.EXAMPLE
    .\Remove-JunkFiles.ps1 -Path "D:\Projects"
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Path = "."
)

# ============================================================================
# CONFIGURABLE LIST — add or remove filenames as needed
# ============================================================================
$JunkFileNames = @(
    "Thumbs.db"
    ".DS_Store"
    "desktop.ini"
    "._*"            # macOS resource-fork sidecar files
    ".Spotlight-V100" # macOS Spotlight index folder marker (file form)
    ".Trashes"        # macOS trash folder marker
    "ehthumbs.db"     # legacy Windows Media Center thumbnails
    "ehthumbs_vista.db"
)
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Resolve and validate the target path ---
try {
    $ResolvedPath = (Resolve-Path -Path $Path -ErrorAction Stop).Path
} catch {
    Write-Host "`n  ERROR: Path not found — '$Path'" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -Path $ResolvedPath -PathType Container)) {
    Write-Host "`n  ERROR: '$ResolvedPath' is not a directory." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "  Remove-JunkFiles" -ForegroundColor Cyan
Write-Host "  ================" -ForegroundColor Cyan
Write-Host "  Target : $ResolvedPath"
Write-Host "  Patterns: $($JunkFileNames -join ', ')"
Write-Host ""

# --- Scan phase ---
Write-Host "  Scanning..." -ForegroundColor Yellow

# -Force exposes hidden and system files.
# We build an include list from $JunkFileNames and recurse the whole tree once.
$FoundFiles = Get-ChildItem -Path $ResolvedPath -Recurse -Force -File `
    -Include $JunkFileNames -ErrorAction SilentlyContinue

if (-not $FoundFiles -or $FoundFiles.Count -eq 0) {
    Write-Host "  No junk files found. Nothing to do.`n" -ForegroundColor Green
    exit 0
}

# --- Build a summary grouped by filename ---
$GroupedSummary = $FoundFiles | Group-Object -Property Name | Sort-Object -Property Count -Descending

$TotalCount = $FoundFiles.Count
$TotalSize  = ($FoundFiles | Measure-Object -Property Length -Sum).Sum

Write-Host ""
Write-Host "  ┌─────────────────────────────────────────────┐" -ForegroundColor DarkGray
Write-Host "  │  Scan Results                                │" -ForegroundColor DarkGray
Write-Host "  ├──────────────────────────┬──────────┬────────┤" -ForegroundColor DarkGray
Write-Host ("  │ {0,-24} │ {1,-8} │ {2,-6} │" -f "Filename", "Count", "Size") -ForegroundColor DarkGray
Write-Host "  ├──────────────────────────┼──────────┼────────┤" -ForegroundColor DarkGray

foreach ($Group in $GroupedSummary) {
    $GroupSize = ($Group.Group | Measure-Object -Property Length -Sum).Sum
    $SizeStr = if ($GroupSize -ge 1MB) { "{0:N1} MB" -f ($GroupSize / 1MB) }
               elseif ($GroupSize -ge 1KB) { "{0:N1} KB" -f ($GroupSize / 1KB) }
               else { "$GroupSize B" }
    Write-Host ("  │ {0,-24} │ {1,8} │ {2,6} │" -f $Group.Name, $Group.Count, $SizeStr) -ForegroundColor White
}

$TotalSizeStr = if ($TotalSize -ge 1MB) { "{0:N1} MB" -f ($TotalSize / 1MB) }
                elseif ($TotalSize -ge 1KB) { "{0:N1} KB" -f ($TotalSize / 1KB) }
                else { "$TotalSize B" }

Write-Host "  ├──────────────────────────┼──────────┼────────┤" -ForegroundColor DarkGray
Write-Host ("  │ {0,-24} │ {1,8} │ {2,6} │" -f "TOTAL", $TotalCount, $TotalSizeStr) -ForegroundColor Cyan
Write-Host "  └──────────────────────────┴──────────┴────────┘" -ForegroundColor DarkGray
Write-Host ""

# --- Optional: list every file path ---
$ShowList = Read-Host "  Show full file list? (y/N)"
if ($ShowList -match '^[Yy]') {
    Write-Host ""
    foreach ($File in ($FoundFiles | Sort-Object FullName)) {
        Write-Host "    $($File.FullName)" -ForegroundColor DarkGray
    }
    Write-Host ""
}

# --- Confirmation gate ---
Write-Host "  This action is irreversible — files are permanently deleted." -ForegroundColor Red
$Confirm = Read-Host "  Delete all $TotalCount files? Type YES to confirm"

if ($Confirm -cne "YES") {
    Write-Host "`n  Aborted. No files were deleted.`n" -ForegroundColor Yellow
    exit 0
}

# --- Deletion phase ---
Write-Host ""
$Deleted  = 0
$Failed   = 0

foreach ($File in $FoundFiles) {
    try {
        # Strip read-only / hidden / system attributes so Remove-Item won't be blocked.
        if ($File.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
            $File.Attributes = $File.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
        }
        Remove-Item -LiteralPath $File.FullName -Force -ErrorAction Stop
        $Deleted++
        Write-Host "    Deleted: $($File.FullName)" -ForegroundColor DarkGreen
    } catch {
        $Failed++
        Write-Host "    FAILED : $($File.FullName) — $($_.Exception.Message)" -ForegroundColor Red
    }
}

# --- Final report ---
Write-Host ""
Write-Host "  ────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Deleted : $Deleted" -ForegroundColor Green
if ($Failed -gt 0) {
    Write-Host "  Failed  : $Failed" -ForegroundColor Red
}
Write-Host "  ────────────────────────────`n" -ForegroundColor DarkGray
