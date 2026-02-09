# OpenClaw in Ubuntu using macOS UTM

Copyright (c) 2019-2026 by Alisson Sol

## 0) Too long. Don't want to read the details. Only the needed commands

Minimal commands for creating the `openclaw01` VM. See sections below for details.

**On the macOS host (one-time setup):**

Check latest instructions for `brew` from [brew.sh](https://brew.sh/)

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

After installing `brew`, you may need to open another terminal.

```bash
brew install --cask utm
brew install git
brew install powershell
brew install openssl qemu xorriso
```

**Getting only the needed folder**
```bash
git clone --filter=blob:none --sparse https://github.com/alissonsol/experiments.git
cd experiments
git sparse-checkout add 2026/2026-02.ubuntu.env.macos
cd 2026/2026-02.ubuntu.env.macos/
```

**On the macOS host (download the Ubuntu image):**

```bash
pwsh ./ubuntu.env.macos.download.ps1
```

**On the macOS host (create the VM with default hostname "openclaw01"):**
```bash
pwsh ./ubuntu.env.macos.create.ps1
```

Or with a custom hostname:
```bash
pwsh ./ubuntu.env.macos.create.ps1 -VmName myhostname
```

Double-click `openclaw01.utm` (or your custom name) on your Desktop to import it into UTM and start the VM. The Ubuntu installer will run automatically using autoinstall.

**After installation completes:**

The default user is `ubuntu` and the initial password is `password`. You will be prompted to change it on first login.

## 1) Get all in!

What can you do during [The Long Dark Tea-Time of the Soul](https://en.wikipedia.org/wiki/The_Long_Dark_Tea-Time_of_the_Soul)?

This is the macOS counterpart of the [Hyper-V version](../2026-02.ubuntu.env.hyper-v/). It uses [UTM](https://mac.getutm.app/) to run an Ubuntu ARM64 VM on Apple Silicon Macs.

### 1.1) Installing UTM

[UTM](https://mac.getutm.app/) is a full-featured virtual machine host for macOS based on QEMU. Install it using [Homebrew](https://brew.sh/):

```bash
brew install --cask utm
```

The scripts in this folder use PowerShell. Install it with:

```bash
brew install powershell/tap/powershell
```

### 1.2) Downloading the Ubuntu image

The script [`ubuntu.env.macos.download.ps1`](./ubuntu.env.macos.download.ps1) fetches the Ubuntu Desktop 25.10 ARM64 ISO. The image is saved to `~/virtual/ubuntu.env/`.

```bash
pwsh ./ubuntu.env.macos.download.ps1
```

## 2) Creating the VM

The script [`ubuntu.env.macos.create.ps1`](./ubuntu.env.macos.create.ps1) creates a UTM VM bundle on your Desktop. It accepts an optional `-VmName` parameter (default: `openclaw01`) and:

- Creates a modified copy of the Ubuntu ISO with the `autoinstall` kernel parameter (bypasses the installer confirmation prompt). Requires `xorriso`; falls back to a plain copy if unavailable.
- Creates a 64GB blank qcow2 disk for installation.
- Generates an autoinstall `seed.iso` that automatically configures the Ubuntu installation with the given hostname.
- Generates a `config.plist` from [`config.plist.template`](./config.plist.template) for a QEMU ARM64 VM (4 CPUs, 8 GB RAM, VirtIO disk, UEFI boot, shared networking, sound, clipboard sharing).

```bash
pwsh ./ubuntu.env.macos.create.ps1
# Or with a custom hostname:
pwsh ./ubuntu.env.macos.create.ps1 -VmName myhostname
```

**Prerequisites:** `brew install openssl qemu xorriso` (for password hashing, disk image creation, and ISO modification).

After the script completes, double-click `<hostname>.utm` on your Desktop to import it into UTM. Start the VM and the Ubuntu installer will run automatically via autoinstall.

- Default credentials: username `ubuntu`, password `password`. You will be required to change the password on first login.
- The autoinstall sets the hostname, locale (`en_US.UTF-8`), keyboard (`us`), LVM storage layout, and enables SSH.
- After installation, the VM boots from the hard disk by default (the disk drive is first in the UEFI boot order).
- The script `ubuntu.env.openclaw.bash` is downloaded to `/` on the installed system. Run it with `sudo bash /ubuntu.env.openclaw.bash`.
