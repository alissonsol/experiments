<#PSScriptInfo
.VERSION 0.2
.GUID 42676eba-fcd4-4bbf-b453-af7eb7dcdbfd
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

param(
    [string]$VmName = "openclaw01"
)

$UtmDir = "$HOME/Desktop/$VmName.utm"
$DataDir = "$UtmDir/Data"
$DownloadDir = "$HOME/virtual/ubuntu.env"

# 1. Locate the downloaded Ubuntu ISO
$IsoSource = Join-Path $DownloadDir "ubuntu.desktop.arm64.downloaded.iso"
if (-not (Test-Path $IsoSource)) {
    Write-Error "Ubuntu ISO not found at '$IsoSource'. Run ubuntu.env.macos.download.ps1 first."
    exit 1
}

# 2. Find OpenSSL with SHA-512 passwd support (for autoinstall password hash)
$PasswordHash = $null
foreach ($path in @("/opt/homebrew/opt/openssl@3/bin/openssl", "/opt/homebrew/opt/openssl/bin/openssl", "/usr/local/opt/openssl@3/bin/openssl", "/usr/local/opt/openssl/bin/openssl", "openssl")) {
    try {
        $result = (& $path passwd -6 "password" 2>$null)
        if ($LASTEXITCODE -eq 0 -and $result) {
            $PasswordHash = $result.Trim()
            break
        }
    } catch {}
}
if (-not $PasswordHash) {
    Write-Error "OpenSSL with SHA-512 password support is required. Install with: brew install openssl"
    exit 1
}

Write-Output "Creating VM '$VmName' using ISO: $IsoSource"

# 3. Create UTM Bundle Structure
if (Test-Path $UtmDir) { Remove-Item -Recurse -Force $UtmDir }
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# 4. Copy Ubuntu ISO into the bundle (named after hostname)
$DestIso = "$DataDir/$VmName.iso"
Copy-Item -Path $IsoSource -Destination $DestIso
Write-Output "Copied installer ISO as: $VmName.iso"

# 5. Create blank disk for installation (64GB, thin-provisioned qcow2)
$DiskImage = "$DataDir/disk.qcow2"
Write-Output "Creating 64GB disk image..."
& qemu-img create -f qcow2 "$DiskImage" 64G
if ($LASTEXITCODE -ne 0) {
    Write-Error "qemu-img failed. Install QEMU tools with: brew install qemu"
    exit 1
}

# 6. Generate autoinstall seed ISO
$SeedDir = Join-Path $DownloadDir "seed_temp/$VmName"
if (Test-Path $SeedDir) { Remove-Item -Recurse -Force $SeedDir }
New-Item -ItemType Directory -Force -Path $SeedDir | Out-Null

# Autoinstall user-data (username: ubuntu, password: password)
$UserData = @'
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  identity:
    hostname: HOSTNAME_PLACEHOLDER
    username: ubuntu
    password: "HASH_PLACEHOLDER"
  storage:
    layout:
      name: lvm
  ssh:
    install-server: true
    allow-pw: true
'@
$UserData = $UserData.Replace('HOSTNAME_PLACEHOLDER', $VmName)
$UserData = $UserData.Replace('HASH_PLACEHOLDER', $PasswordHash)

Set-Content -Path "$SeedDir/user-data" -Value $UserData
Set-Content -Path "$SeedDir/meta-data" -Value "" -NoNewline

$SeedIso = "$DataDir/seed.iso"
Write-Output "Generating seed.iso with autoinstall configuration..."
& hdiutil makehybrid -o "$SeedIso" -hfs -joliet -iso -default-volume-name cidata "$SeedDir"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to create seed.iso with hdiutil."
    exit 1
}

# 7. Generate UTM config.plist
$PlistContent = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Backend</key>
    <string>QEMU</string>
    <key>ConfigurationVersion</key>
    <integer>4</integer>
    <key>Information</key>
    <dict>
        <key>Name</key>
        <string>$VmName</string>
        <key>Notes</key>
        <string>Ubuntu Desktop 25.10 - $VmName</string>
    </dict>
    <key>System</key>
    <dict>
        <key>Architecture</key>
        <string>aarch64</string>
        <key>CPUCount</key>
        <integer>4</integer>
        <key>MemorySize</key>
        <integer>8192</integer>
    </dict>
    <key>Drive</key>
    <array>
        <dict>
            <key>ImageType</key>
            <string>Disk</string>
            <key>Interface</key>
            <string>VirtIO</string>
            <key>ImagePath</key>
            <string>disk.qcow2</string>
        </dict>
        <dict>
            <key>ImageType</key>
            <string>CD</string>
            <key>Interface</key>
            <string>USB</string>
            <key>ImagePath</key>
            <string>$VmName.iso</string>
        </dict>
        <dict>
            <key>ImageType</key>
            <string>CD</string>
            <key>Interface</key>
            <string>USB</string>
            <key>ImagePath</key>
            <string>seed.iso</string>
        </dict>
    </array>
    <key>Display</key>
    <array>
        <dict>
            <key>Hardware</key>
            <string>virtio-ramfb</string>
        </dict>
    </array>
    <key>Network</key>
    <array>
        <dict>
            <key>Mode</key>
            <string>Shared</string>
        </dict>
    </array>
</dict>
</plist>
"@

Set-Content -Path "$UtmDir/config.plist" -Value $PlistContent

Write-Output ""
Write-Output "VM bundle created: $UtmDir"
Write-Output "Double-click '$VmName.utm' on your Desktop to import it into UTM."
Write-Output "The Ubuntu installer will start automatically with autoinstall."
Write-Output "Default credentials - username: ubuntu, password: password"
