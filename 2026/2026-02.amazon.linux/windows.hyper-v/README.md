# Amazon Linux running in Windows Hyper-V

Copyright (c) 2019-2026 by Alisson Sol

Minimal commands for creating the VM. Link to details at the end.

## One-time setup

**On the Windows host (one-time setup): Requirements**

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
git sparse-checkout add 2026/2026-02.amazon.linux/windows.hyper-v
cd 2026\2026-02.amazon.linux\windows.hyper-v
```

**On the Windows host (Administrator PowerShell): Getting the base image**

Assuming you are in the `experiments\2026\2026-02.amazon.linux\windows.hyper-v` folder.

```powershell
.\Get-Image.ps1
```

## For each VM

**On the Windows host (Administrator PowerShell): Create VM**

```powershell
.\New-VM.ps1
```

Or with a custom hostname:

```powershell
.\New-VM.ps1 -VMName myhostname
```

**On the VM: Install Graphical User Interface**

Unless you changed the defaults in the [vmconfig/user-data](./vmconfig/user-data) file, at this point the user is `ec2-user` and the password is `amazonlinux`.

```bash
sudo dnf update -y
sudo dnf upgrade -y
sudo dnf groupinstall "Desktop" -y
sudo reboot now
```

The machine is now ready!

## Optional install of OpenClaw

**On the VM: OpenClaw install**

```bash
cd /
sudo bash amazon.linux.openclaw.bash
sudo reboot now
```

After reboot, open a terminal and configure OpenClaw. This is past the install step in the OpenClaw [Getting Started](https://docs.openclaw.ai/start/getting-started).

```bash
openclaw onboard --install-daemon
```

<mark>Careful: you are about to give AI some precious access to your accounts!</mark>

![](images/001.openclaw.config.png)

Read more [here](READ.MORE.md) about the details of the VM creation process.

