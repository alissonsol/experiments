<#PSScriptInfo
.VERSION 0.4
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
  late-commands:
    - curtin in-target --target=/target -- passwd --expire ubuntu
    - wget -O /target/ubuntu.env.openclaw.bash "https://raw.githubusercontent.com/alissonsol/experiments/main/2026/2026-02.ubuntu.env.macos/ubuntu.env.openclaw.bash"
    - curtin in-target --target=/target -- chmod +x /ubuntu.env.openclaw.bash
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

# 7. Generate UTM config.plist from template
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TemplatePath = Join-Path $ScriptDir "config.plist.template"
if (-not (Test-Path $TemplatePath)) {
    Write-Error "Template not found at '$TemplatePath'."
    exit 1
}

# Generate UUIDs and MAC address for this VM
$VmUuid = [guid]::NewGuid().ToString().ToUpper()
$DiskId = [guid]::NewGuid().ToString().ToUpper()
$IsoId = [guid]::NewGuid().ToString().ToUpper()
$SeedId = [guid]::NewGuid().ToString().ToUpper()
$MacBytes = [byte[]]::new(6)
[System.Random]::new().NextBytes($MacBytes)
$MacBytes[0] = ($MacBytes[0] -bor 0x02) -band 0xFE  # locally administered unicast
$MacAddress = ($MacBytes | ForEach-Object { $_.ToString("X2") }) -join ":"

$PlistContent = (Get-Content -Raw $TemplatePath) `
    -replace '__VM_NAME__',        $VmName `
    -replace '__VM_UUID__',        $VmUuid `
    -replace '__MAC_ADDRESS__',    $MacAddress `
    -replace '__DISK_IDENTIFIER__', $DiskId `
    -replace '__DISK_IMAGE_NAME__', 'disk.qcow2' `
    -replace '__ISO_IDENTIFIER__',  $IsoId `
    -replace '__ISO_IMAGE_NAME__',  "$VmName.iso" `
    -replace '__SEED_IDENTIFIER__', $SeedId `
    -replace '__SEED_IMAGE_NAME__', 'seed.iso' `
    -replace '__CPU_COUNT__',       '4' `
    -replace '__MEMORY_SIZE__',     '8192'

Set-Content -Path "$UtmDir/config.plist" -Value $PlistContent

Write-Output ""
Write-Output "VM bundle created: $UtmDir"
Write-Output "Double-click '$VmName.utm' on your Desktop to import it into UTM."
Write-Output "The Ubuntu installer will start automatically with autoinstall."
Write-Output "Default credentials - username: ubuntu, password: password (must be changed on first login)"
