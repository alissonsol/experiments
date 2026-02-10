<#PSScriptInfo
.VERSION 0.1
.GUID 5b3e8a1d-7c42-4f9e-b6d8-a1e3c5f7d2b4
.AUTHOR Alisson Sol
.COMPANYNAME None
.COPYRIGHT (c) 2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
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
# $sourceFile = "https://releases.ubuntu.com/noble/ubuntu-24.04.2-desktop-amd64.iso"
$sourceFile = "https://cdimage.ubuntu.com/noble/daily-live/current/noble-desktop-amd64.iso"
$localVhdxPath = (Get-VMHost).VirtualHardDiskPath
Write-Output "Hyper-V default VHDX folder: $localVhdxPath"
if (!(Test-Path -Path $localVhdxPath)) {
    Write-Output "The Hyper-V default VHDX folder does not exist: $localVhdxPath"
    exit 1
}

# Destination file
$destFile = Join-Path $localVhdxPath "ubuntu.desktop.amd64.iso"
Remove-Item $destFile -Force -ErrorAction SilentlyContinue
Write-Output "Downloading $sourceFile to $destFile"
Invoke-WebRequest -Uri $sourceFile -OutFile $destFile

Write-Output "Download Complete: $destFile"
