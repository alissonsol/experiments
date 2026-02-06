# OpenClaw in Amazon Linux using macOS UTM

Copyright (c) 2019-2026 by Alisson Sol

## 0) Too long. Don't want to read the details. Only the needed commands

Minimal commands for creating the `openclaw01` VM. See sections below for details.

**Getting only the needed folder**
```bash
git clone --filter=blob:none --sparse https://github.com/alissonsol/experiments.git
cd experiments
git sparse-checkout add 2026/2026-02.openclaw.in.amazon.linux.macos
cd 2026/2026-02.openclaw.in.amazon.linux.macos/
```

**On the macOS host (one-time setup, install UTM and PowerShell):**

```bash
brew install --cask utm
brew install powershell/tap/powershell
```

**On the macOS host (download the Amazon Linux image):**

```bash
pwsh ./amazon.linux.macos.download.ps1
```

**On the macOS host (create the VM):**
```bash
pwsh ./amazon.linux.macos.create.ps1
```

Double-click `openclaw01.utm` on your Desktop to import it into UTM and start the VM.

**On the VM (after first login):**

The default user is `ec2-user` and the password is `password`.

```bash
cd /
sudo bash amazon.linux.openclaw.bash
sudo reboot now
```

**On the VM (after reboot in the Graphical UX):**

Open terminal and run OpenClaw. Copy your `CLAW.WAD` file to `~/OpenClaw/build/Assets/` and run:

```bash
~/OpenClaw/build/openclaw
```

## 1) Get all in!

What can you do during [The Long Dark Tea-Time of the Soul](https://en.wikipedia.org/wiki/The_Long_Dark_Tea-Time_of_the_Soul)?

This is the macOS counterpart of the [Hyper-V version](../2026-02.openclaw.in.amazon.linux.hyper-v/). It uses [UTM](https://mac.getutm.app/) to run an Amazon Linux 2023 ARM64 VM on Apple Silicon Macs.

### 1.1) Installing UTM

[UTM](https://mac.getutm.app/) is a full-featured virtual machine host for macOS based on QEMU. Install it using [Homebrew](https://brew.sh/):

```bash
brew install --cask utm
```

The scripts in this folder use PowerShell. Install it with:

```bash
brew install powershell/tap/powershell
```

### 1.2) Downloading the Amazon Linux image

The script [`amazon.linux.macos.download.ps1`](./amazon.linux.macos.download.ps1) fetches the latest Amazon Linux 2023 KVM image (ARM64 qcow2) from the Amazon Linux CDN. The image is saved to `~/Downloads/AmazonLinux2023-KVM/`.

```bash
pwsh ./amazon.linux.macos.download.ps1
```

## 2) Creating the VM

The script [`amazon.linux.macos.create.ps1`](./amazon.linux.macos.create.ps1) creates a UTM VM bundle (`openclaw01.utm`) on your Desktop. It:

- Copies the downloaded qcow2 disk image into the bundle.
- Generates a cloud-init `seed.iso` with the default user (`ec2-user`) and password (`password`).
- Creates a `config.plist` for a QEMU ARM64 VM (2 CPUs, 4 GB RAM, VirtIO disk, shared networking).

```bash
pwsh ./amazon.linux.macos.create.ps1
```

After the script completes, double-click `openclaw01.utm` on your Desktop to import it into UTM. Start the VM from UTM.

- Login with user `ec2-user` and password `password`.
- Navigate to the root folder (`cd /`) and execute `sudo bash amazon.linux.openclaw.bash`.
  - This installs the GNOME desktop, development tools, SDL2 dependencies, and builds OpenClaw from source.
- Execute `sudo reboot now` and the VM reboots into GUI mode.

## 3) Playing OpenClaw

After the VM reboots into the graphical environment:

1. Copy your `CLAW.WAD` file to `~/OpenClaw/build/Assets/`.
2. Open a terminal and run: `~/OpenClaw/build/openclaw`.
