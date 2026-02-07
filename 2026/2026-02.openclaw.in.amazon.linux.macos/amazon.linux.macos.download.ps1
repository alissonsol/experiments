<#PSScriptInfo
.VERSION 0.1
.GUID 42b1ed80-851e-4624-a6a3-ca7980b54893
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

$sourceFolder = "https://cdn.amazonlinux.com/al2023/os-images/latest/kvm/"
$DownloadDir = "$HOME/Downloads/AmazonLinux2023-KVM"

# Ensure download directory exists
New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null

Write-Output "Fetching release list from Amazon Linux CDN..." -ForegroundColor Cyan

# Find the first .qcow2 file link to download
$html = Invoke-WebRequest -Uri $sourceFolder
$qcow2File = ($html.Links | Where-Object { $_.href -match "\.qcow2$" })[0].href
$url = $sourceFolder + $qcow2File

# Destination file
$destFile = Join-Path $DownloadDir "amazonlinux.qcow2"
Remove-Item $destFile -Force -ErrorAction SilentlyContinue
Invoke-WebRequest -Uri $url -OutFile $destFile

Write-Output "Download Complete: $destFile" -ForegroundColor Green
