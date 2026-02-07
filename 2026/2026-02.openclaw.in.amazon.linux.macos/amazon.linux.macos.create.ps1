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


$VmName = "openclaw01"
$UtmDir = "$HOME/Desktop/$VmName.utm" # Creates directly on Desktop for easy access
$DataDir = "$UtmDir/Data"
# $ImagesDir = "$UtmDir/Images" # standard UTM structure might vary, but flat is often okay. We'll use Data.

# 1. Locate the Image
$DownloadDir = "$HOME/Downloads/AmazonLinux2023-KVM"
$PathFile = Join-Path $DownloadDir "amazonlinux.qcow2"
if (Test-Path $PathFile) {
} else {
    Write-Error "Could not find latest image path file. Run the download script first."
    exit 1
}

Write-Output "Creating VM '$VmName' using image: $PathFile"

# 2. Create Bundle Structure
if (Test-Path $UtmDir) { Remove-Item -Recurse -Force $UtmDir }
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# 3. Copy Disk Image
$DestImage = "$DataDir/$VmName.qcow2"
Copy-Item -Path $PathFile -Destination $DestImage

# 4. Generate Cloud-Init Seed ISO
$SeedDir = "$HOME/Downloads/seed_temp/$VmName"
Remove-Item -Recurse -Force $SeedDir | Out-Null
New-Item -ItemType Directory -Force -Path $SeedDir | Out-Null

# User-Data (Default user: ec2-user / password: password)
$UserData = @"
#cloud-config
password: password
chpasswd: { expire: False }
ssh_pwauth: True
runcmd:
  - echo "Setup Complete."
"@
Set-Content -Path "$SeedDir/user-data" -Value $UserData
Set-Content -Path "$SeedDir/meta-data" -Value "instance-id: $VmName" -NoNewline

$SeedIso = "$DataDir/seed.iso"
Write-Output "Generating seed.iso..."
Start-Process "hdiutil" -ArgumentList "makehybrid -o `"$SeedIso`" -hfs -joliet -iso -default-volume-name cidata `"$SeedDir`"" -Wait -NoNewWindow
Write-Output "Created '$SeedIso' with data from: $SeedDir"

# 5. Generate config.plist
# This is a minimal QEMU ARM64 configuration for UTM
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
        <string>Amazon Linux 2023 for OpenClaw</string>
    </dict>
    <key>System</key>
    <dict>
        <key>Architecture</key>
        <string>aarch64</string>
        <key>CPUCount</key>
        <integer>2</integer>
        <key>MemorySize</key>
        <integer>4096</integer>
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

Write-Output "VM Bundle Created: $UtmDir"
Write-Output "Double-click '$VmName.utm' on your Desktop to import it into UTM."