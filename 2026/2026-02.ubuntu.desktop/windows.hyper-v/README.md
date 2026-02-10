# OpenClaw in Ubuntu Desktop using Windows Hyper-V

Copyright (c) 2019-2026 by Alisson Sol

## 0) Too long. Don't want to read the details. Only the needed commands

Minimal commands for creating the VM. See sections below for details.

**On the Windows host (one-time setup):**

Enable Hyper-V from Windows Features or run in an elevated PowerShell:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart
```

Restart Windows after enabling Hyper-V.

Install [Windows ADK Deployment Tools](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install) for `Oscdimg.exe` (needed to create seed ISO). During installation, select only "Deployment Tools".

Install [Git for Windows](https://git-scm.com/download/win) (includes OpenSSL needed for password hashing).

**Getting only the needed folder**

```powershell
git clone --filter=blob:none --sparse https://github.com/alissonsol/experiments.git
cd experiments
git sparse-checkout add 2026/2026-02.ubuntu.desktop/windows.hyper-v
cd 2026\2026-02.ubuntu.desktop\windows.hyper-v\
```

**On the Windows host (download the Ubuntu image):**

```powershell
.\Get-Image.ps1
```

**On the Windows host (create the VM with default hostname):**

```powershell
.\New-VM.ps1
```

Or with a custom hostname:

```powershell
.\New-VM.ps1 -vmName myhostname
```

Start the VM from Hyper-V Manager. The Ubuntu installer will run automatically using autoinstall. <mark>This step may take a few minutes (~15)</mark>. The screen may not be shown. If not shown after ~15 minutes, stop and restart the VM.

**On the VM (after setup): Updating**

Open a terminal and enter the commands. If needed, the default user is `ubuntu` and the initial password is `password`.

```bash
wget -O updateAll https://raw.githubusercontent.com/alissonsol/experiments/refs/heads/main/util/updateAll
chmod a+x updateAll
sudo ./updateAll
```

Confirm all installations finished correctly, and then reboot.

```bash
sudo reboot now
```

The machine is now ready! You should be prompted to change the password on first login. You can change the password at any time with the `passwd` command.

**On the VM (after reboot): Optional install of OpenClaw**

Open a terminal and enter the commands.

```bash
wget -O ubuntu.env.openclaw.bash https://raw.githubusercontent.com/alissonsol/experiments/refs/heads/main/2026/2026-02.ubuntu.desktop/windows.hyper-v/ubuntu.env.openclaw.bash
chmod a+x ubuntu.env.openclaw.bash
sudo bash ./ubuntu.env.openclaw.bash
```

Open terminal and configure OpenClaw. This is past the install step in the OpenClaw [Getting Started](https://docs.openclaw.ai/start/getting-started).

```bash
openclaw onboard --install-daemon
```

Careful: you are about to give AI some precious access to your accounts!

## 1) Get all in!

What can you do during [The Long Dark Tea-Time of the Soul](https://en.wikipedia.org/wiki/The_Long_Dark_Tea-Time_of_the_Soul)?

This is the Windows Hyper-V counterpart of the [macOS UTM version](../macos.utm/). It uses [Hyper-V](https://docs.microsoft.com/en-us/virtualization/hyper-v-on-windows/) to run an Ubuntu Desktop VM on Windows.

### 1.1) Prerequisites

**Hyper-V** must be enabled. In an elevated PowerShell:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart
```

Restart Windows after enabling Hyper-V.

**Windows ADK Deployment Tools** are required for `Oscdimg.exe` (used to create the cloud-init seed ISO). Download and install from [Windows ADK](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install). During installation, select only "Deployment Tools".

**Git for Windows** is required (includes OpenSSL for password hashing). Download from [git-scm.com](https://git-scm.com/download/win).

### 1.2) Downloading the Ubuntu image

The script [`Get-Image.ps1`](./Get-Image.ps1) fetches the Ubuntu Desktop amd64 ISO. The image is saved to the Hyper-V default virtual hard disk path.

```powershell
.\Get-Image.ps1
```

## 2) Creating the VM

The script [`New-VM.ps1`](./New-VM.ps1) creates a Hyper-V Generation 2 VM. It accepts an optional `-vmName` parameter (default: `ubuntu-desktop01`) and:

- Creates a 512GB dynamically expanding VHDX for installation.
- Generates an autoinstall `seed.iso` that automatically configures the Ubuntu installation with the given hostname.
- Creates a Generation 2 Hyper-V VM (8 GB RAM, half of host CPU cores, UEFI boot, Secure Boot off, Default Switch networking).
- Mounts the Ubuntu ISO and seed ISO as DVD drives.
- Sets the DVD drive as the first boot device for installation.

```powershell
.\New-VM.ps1
# Or with a custom hostname:
.\New-VM.ps1 -vmName myhostname
```

After the script completes, start the VM from Hyper-V Manager. The Ubuntu installer will run automatically via autoinstall.

- Default credentials: username `ubuntu`, password `password`. You will be required to change the password on first login.
- The autoinstall sets the hostname, locale (`en_US.UTF-8`), keyboard (`us`), LVM storage layout, and enables SSH.

### 2.1) Testing connectivity

Once the VM is running, you can find its IP address:

```powershell
Get-VM -Name "ubuntu-deskop01" | Select-Object -ExpandProperty NetworkAdapters | Select-Object IPAddresses
```

Then SSH into the VM:

```powershell
ssh ubuntu@<ip-address>
```

## 3) Known limitations

- Ubuntu Desktop autoinstall may take approximately 15 minutes depending on hardware.
- The screen may appear blank during installation. Wait for the installation to complete.
- After installation, DVD drives must be manually removed to prevent booting into the installer again.
- Enhanced Session Mode (xrdp) is not configured by default. You can install it manually for better remote desktop experience.
