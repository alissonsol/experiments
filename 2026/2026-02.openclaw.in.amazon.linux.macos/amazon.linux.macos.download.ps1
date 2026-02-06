<#
.SYNOPSIS
Finds and downloads the latest Amazon Linux 2023 KVM Image (ARM64) for macOS (Apple Silicon).
#>

$BaseUrl = "https://cdn.amazonlinux.com/al2023/os-images"
$DownloadDir = "$HOME/Downloads/AmazonLinux2023-KVM"

# Ensure download directory exists
New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null

Write-Host "Fetching release list from Amazon Linux CDN..." -ForegroundColor Cyan

# 1. Get the list of version folders
try {
    $response = Invoke-WebRequest -Uri $BaseUrl -UseBasicParsing
    # Parse HTML links to find version numbers (e.g., "2023.6.20250218.0/")
    # We sort descending to get the "latest" version.
    $latestVersion = $response.Links.href | 
        Where-Object { $_ -match '^\d{4}\.\d+\.\d+\.\d+/$' } | 
        Sort-Object -Descending | 
        Select-Object -First 1
    
    if (-not $latestVersion) { throw "Could not find any version folders." }

    $latestVersion = $latestVersion.TrimEnd('/')
    Write-Host "Latest Version Found: $latestVersion" -ForegroundColor Green
}
catch {
    Write-Error "Failed to fetch version list. Check internet connection."
    exit 1
}

# 2. Construct the Image URL
# Pattern: <base>/<ver>/kvm/al2023-kvm-<ver>-kernel-<kernel_ver>-arm64.x86_64.qcow2
# Note: We need to find the specific filename inside the version folder because kernel version varies.

$VersionUrl = "$BaseUrl/$latestVersion/kvm/"
try {
    $verResponse = Invoke-WebRequest -Uri $VersionUrl -UseBasicParsing
    $imageFile = $verResponse.Links.href | 
        Where-Object { $_ -match "al2023-kvm-.*-arm64.x86_64.qcow2$" } | 
        Select-Object -First 1

    if (-not $imageFile) { throw "Could not find ARM64 qcow2 image in $VersionUrl" }
}
catch {
    Write-Error "Failed to find image file listing."
    exit 1
}

$FullUrl = "$BaseUrl/$latestVersion/kvm/$imageFile"
$OutputPath = Join-Path $DownloadDir $imageFile

# 3. Download
if (Test-Path $OutputPath) {
    Write-Host "File already exists: $OutputPath" -ForegroundColor Yellow
} else {
    Write-Host "Downloading $imageFile..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $FullUrl -OutFile $OutputPath
}

Write-Host "Download Complete: $OutputPath" -ForegroundColor Green
# Save path for the next script to pick up (optional technique, or just rely on filename)
$OutputPath | Out-File -FilePath "$HOME/Downloads/latest_al2023_path.txt" -Encoding ascii