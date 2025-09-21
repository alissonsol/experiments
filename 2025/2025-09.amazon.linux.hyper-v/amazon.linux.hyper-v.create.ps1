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

# Check if Hyper-V services are installed and running
$hypervFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
if ($hypervFeature.State -ne 'Enabled') {
	Write-Output "Hyper-V is not enabled. Please enable Hyper-V from Windows Features."
	Write-Output "Instructions: https://docs.microsoft.com/en-us/virtualization/hyper-v-on-windows/quick-start/enable-hyper-v"
	exit 1
}

$service = Get-Service -Name vmms -ErrorAction SilentlyContinue
if (!$service -or $service.Status -ne 'Running') {
	Write-Output "Hyper-V Virtual Machine Management service (vmms) is not running. Please start the service."
	Write-Output "Instructions: https://docs.microsoft.com/en-us/virtualization/hyper-v-on-windows/quick-start/enable-hyper-v"
	exit 1
}

# Check if VM named 'AmazonLinux' exists and force delete it
$vmName = "AmazonLinux"
$existingVM = Get-VM -Name $vmName -ErrorAction SilentlyContinue
if ($existingVM) {
	Write-Output "VM '$vmName' exists. Deleting..."
	Stop-VM -Name $vmName -Force -ErrorAction SilentlyContinue
	Remove-VM -Name $vmName -Force
	Write-Output "VM '$vmName' deleted."
}

# Files
$localVhdxPath = (Get-VMHost).VirtualHardDiskPath
Write-Output "Hyper-V default VHDX folder: $localVhdxPath"
if (!(Test-Path -Path $localVhdxPath)) {
    Write-Output "The Hyper-V default VHDX folder does not exist: $localVhdxPath"
    exit 1
}
$vhdxName = "amazonlinux.vhdx"
$vhdxFile = Join-Path $localVhdxPath $vhdxName
if (!(Test-Path -Path $vhdxFile)) {
	Write-Output "The VHDX file does not exist: $vhdxFile"
	Write-Output "Please run the download script first."
	exit 1
}
$seedIsoFile = Join-Path $localVhdxPath "seed.iso"
if (!(Test-Path -Path $seedIsoFile)) {
	Write-Output "The seed ISO file does not exist: $seedIsoFile"
	Write-Output "Please run the download script first."
	exit 1
}

# Create new Generation 2 Hyper-V VM
Write-Output "Creating new VM '$vmName'..."
New-VM -Name $vmName -Generation 2 -MemoryStartupBytes 8192MB -SwitchName "Default Switch" -VHDPath $vhdxFile | Out-Null
Set-VM -Name $vmName -MemoryStartupBytes 8192MB -MemoryMinimumBytes 8192MB -MemoryMaximumBytes 8192MB | Out-Null
Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $false
Set-VMFirmware -VMName $vmName -EnableSecureBoot Off | Out-Null
Add-VMDvdDrive -VMName $vmName -Path $seedIsoFile | Out-Null
$Cores = (Get-CimInstance -ClassName Win32_Processor).NumberOfCores | Measure-Object -Sum
$CoreCount = $Cores.Sum
$vmCores = [math]::Floor($CoreCount / 2)
Set-VMProcessor -VMName $vmName -Count $vmCores | Out-Null
Write-Output "VM '$vmName' created and configured."