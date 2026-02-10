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

Read more [here](READ.MORE.md) about the details of the VM creation process.
