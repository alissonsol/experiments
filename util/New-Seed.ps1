<#PSScriptInfo
.VERSION 0.1
.GUID 42a1beed-c0de-4a1f-b2c3-d4e5f6a7b8c9
.AUTHOR Alisson Sol
.COMPANYNAME None
.COPYRIGHT (c) 2026 Alisson Sol et al.
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

# Script parameters
param(
	[Parameter(Position = 0)]
	[string]$vmName = "SEED"
)

$global:InformationPreference = "Continue"
$global:DebugPreference = "SilentlyContinue"
$global:VerbosePreference = "SilentlyContinue"

$commonModulePath = Join-Path -Path $PSScriptRoot -ChildPath "VM.common.psm1"
Import-Module -Name $commonModulePath -Force

# Inform and check for elevation
Write-Output "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
	Write-Output "Please run this script as Administrator."
	Write-Output "Be careful."
	exit 1
}

# Files
$localVhdxPath = (Get-VMHost).VirtualHardDiskPath
Write-Output "Hyper-V default VHDX folder: $localVhdxPath"
if (!(Test-Path -Path $localVhdxPath)) {
	Write-Output "The Hyper-V default VHDX folder does not exist: $localVhdxPath"
	exit 1
}

$vmConfig = Join-Path $PSScriptRoot "vmconfig"
$seedIsoFile = Join-Path $localVhdxPath "$vmName/seed.iso"
$VolumeId = "cidata"
CreateIso -SourceDir $vmConfig -OutputFile $seedIsoFile -VolumeId $VolumeId
