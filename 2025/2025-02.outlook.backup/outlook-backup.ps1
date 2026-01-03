<#
.SYNOPSIS
    Backs up Outlook data and email folder to a timestamped ZIP archive.

.DESCRIPTION
    This script closes all Outlook processes, copies the Outlook AppData folder
    to the email directory, and creates a compressed backup archive with a timestamp.

.NOTES
    Author: Alisson Sol
    Copyright: (c) 2020-2025
    Version: 2.0
    Disclaimer: No guarantees provided
#>

[CmdletBinding()]
param()

#Requires -Version 5.1

# Script configuration
$ProcessName = 'outlook'
$ProcessCloseWaitSeconds = 5
$OutlookAppName = 'Microsoft Outlook'
$OutlookDataSubfolder = 'Microsoft/Outlook'
$EmailFolderName = 'email'
$OutlookBackupSubfolder = 'Outlook'
$BackupFilePrefix = 'email.Home'
$DateTimeFormat = 'yyyy-MM-dd-HH-mm-ss'
$EmailBackupFolder = 'C:\Backups\Email'  # Target destination for backup copies

# Get environment paths
$HomeDrive = [System.Environment]::GetEnvironmentVariable('HOMEDRIVE')
$LocalAppData = [System.Environment]::GetEnvironmentVariable('LOCALAPPDATA')

# Validate and resolve email folder path
$EmailFolderPath = Join-Path -Path $HomeDrive -ChildPath $EmailFolderName
if (-not (Test-Path -Path $EmailFolderPath)) {
    Write-Error "Email folder not found: $EmailFolderPath"
    return $false
}
$EmailFolderPath = Resolve-Path -Path $EmailFolderPath

# Close all Outlook processes
$OutlookProcesses = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue

if ($OutlookProcesses) {
    Write-Information "Closing Outlook processes..."

    while ($OutlookProcesses) {
        # Attempt to close main windows gracefully
        foreach ($Process in (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
            $Process.CloseMainWindow() | Out-Null
        }

        Start-Sleep -Seconds $ProcessCloseWaitSeconds

        # If processes still running, send Alt+Y keystroke
        $OutlookProcesses = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
        if ($OutlookProcesses) {
            Write-Information "Outlook is still open. Sending close command..."
            $WScriptShell = New-Object -ComObject WScript.Shell
            $WScriptShell.AppActivate($OutlookAppName) | Out-Null
            $WScriptShell.SendKeys('%(Y)')
        }

        $OutlookProcesses = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
    }

    Write-Information "All Outlook processes closed successfully."
}

# Validate Outlook AppData folder
$OutlookAppDataPath = Join-Path -Path $LocalAppData -ChildPath $OutlookDataSubfolder
if (-not (Test-Path -Path $OutlookAppDataPath)) {
    Write-Error "Outlook app data folder not found: $OutlookAppDataPath"
    return $false
}
$OutlookAppDataPath = Resolve-Path -Path $OutlookAppDataPath

# Prepare Outlook backup destination folder
$OutlookBackupPath = Join-Path -Path $EmailFolderPath -ChildPath $OutlookBackupSubfolder

# Remove existing backup folder and create fresh directory
if (Test-Path -Path $OutlookBackupPath) {
    Remove-Item -Path $OutlookBackupPath -Recurse -Force -ErrorAction SilentlyContinue
}

$null = New-Item -ItemType Directory -Force -Path $OutlookBackupPath -ErrorAction Stop
$OutlookBackupPath = Resolve-Path -Path $OutlookBackupPath

Write-Information "Copying Outlook data to backup location..."
Copy-Item -Path "$OutlookAppDataPath\*" -Destination $OutlookBackupPath -Recurse -Container -ErrorAction Stop

# Create compressed backup archive
Write-Output "Creating compressed backup archive..."
Add-Type -AssemblyName 'System.IO.Compression.FileSystem'

$BackupFolder = [System.Environment]::CurrentDirectory
$Timestamp = Get-Date -Format $DateTimeFormat
$BackupFilename = "$BackupFilePrefix.$Timestamp.zip"
$BackupArchivePath = Join-Path -Path $BackupFolder -ChildPath $BackupFilename

# Remove existing archive if present
if (Test-Path -Path $BackupArchivePath) {
    Remove-Item -Path $BackupArchivePath -Force -ErrorAction SilentlyContinue
}

[System.IO.Compression.ZipFile]::CreateFromDirectory($EmailFolderPath, $BackupArchivePath)

Write-Output "Backup archive created: $BackupArchivePath"

# Copy backup to destination folder
Write-Output "Copying backup to destination folder..."

# Ensure destination folder exists
if (-not (Test-Path -Path $EmailBackupFolder)) {
    Write-Information "Creating backup destination folder: $EmailBackupFolder"
    $null = New-Item -ItemType Directory -Force -Path $EmailBackupFolder -ErrorAction Stop
}

$DestinationArchivePath = Join-Path -Path $EmailBackupFolder -ChildPath $BackupFilename
Copy-Item -Path $BackupArchivePath -Destination $DestinationArchivePath -Force -ErrorAction Stop

# Verify file integrity by comparing byte sizes
Write-Information "Verifying file integrity..."
$SourceFileInfo = Get-Item -Path $BackupArchivePath
$DestinationFileInfo = Get-Item -Path $DestinationArchivePath

if ($SourceFileInfo.Length -eq $DestinationFileInfo.Length) {
    Write-Output "File integrity verified successfully!"
    Write-Information "  Source:      $BackupArchivePath ($($SourceFileInfo.Length) bytes)"
    Write-Information "  Destination: $DestinationArchivePath ($($DestinationFileInfo.Length) bytes)"
    return $true
} else {
    Write-Output "File integrity check FAILED! File sizes do not match."
    Write-Error "  Source:      $BackupArchivePath ($($SourceFileInfo.Length) bytes)"
    Write-Error "  Destination: $DestinationArchivePath ($($DestinationFileInfo.Length) bytes)"
    return $false
}