<#PSScriptInfo
.VERSION 0.1
.GUID e50a15d0-96f6-11f0-a790-b9c7039a859e
.AUTHOR Alisson Sol
.COMPANYNAME None
.COPYRIGHT (c) 2025 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

# Inform and check for elevation
Write-Output "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
	Write-Output "Please run this script as Administrator."
	Write-Output "Be careful."
	exit 1
}

# Source URL
$sourceFolder = "https://cdn.amazonlinux.com/al2023/os-images/2023.8.20250915.0/hyperv/"
$localVhdxPath = (Get-VMHost).VirtualHardDiskPath
Write-Output "Hyper-V default VHDX folder: $localVhdxPath"
if (!(Test-Path -Path $localVhdxPath)) {
    Write-Output "The Hyper-V default VHDX folder does not exist: $localVhdxPath"
    exit 1
}

# Find the first .zip file link to download
$html = Invoke-WebRequest -Uri $sourceFolder
$zipFile = ($html.Links | Where-Object { $_.href -match "\.zip$" })[0].href
$url = $sourceFolder + $zipFile

# Destination file
$destFile = Join-Path $localVhdxPath "amazonlinux.zip"
Remove-Item $destFile -Force -ErrorAction SilentlyContinue
Invoke-WebRequest -Uri $url -OutFile $destFile

# Extract the .vhdx file from the zip and save as amazonlinux.vhdx
$vhdxName = "amazonlinux.vhdx"
$vhdxFile = Join-Path $localVhdxPath $vhdxName
Remove-Item $vhdxFile -Force -ErrorAction SilentlyContinue
$zip = [System.IO.Compression.ZipFile]::OpenRead($destFile)
$entry = $zip.Entries | Where-Object { $_.Name -match "\.vhdx$" }
if ($entry) {
	$stream = $entry.Open()
	$outStream = [System.IO.File]::Open($vhdxFile, [System.IO.FileMode]::Create)
	$stream.CopyTo($outStream)
	$outStream.Close()
	$stream.Close()
}
$zip.Dispose()

# Download seed.iso from the same origin as the script into $localVhdxPath
$seedIsoUrl = "https://github.com/alissonsol/experiments/blob/main/2025/2025-09.amazon.linux.hyper-v/seed.iso?raw=true"
$seedIsoFile = Join-Path $localVhdxPath "seed.iso"
Remove-Item $seedIsoFile -Force -ErrorAction SilentlyContinue
Invoke-WebRequest -Uri $seedIsoUrl -OutFile $seedIsoFile