# OpenClaw in Amazon Linux using Windows Hyper-v

Copyright (c) 2019-2026 by Alisson Sol

## 0) Too long. Don't want to read the details. Only the needed commands

Minimal commands for creating the VM. See sections below for details.

**Getting only the needed folder**
```powershell
git clone --filter=blob:none --sparse https://github.com/alissonsol/experiments.git
cd experiments
git sparse-checkout add 2026/2026-02.amazon.linux/windows.hyper-v
cd 2026\2026-02.amazon.linux\windows.hyper-v
```

**On the Windows host (Administrator PowerShell, one-time setup):**

Assuming you are in the `experiments\2026\2026-02.openclaw.in.amazon.linux.hyper-v` folder.

```powershell
.\Get-Image.ps1
```

**On the Windows host (Administrator PowerShell, create VM):**
```powershell
.\New-OpenClawVM.ps1
```

**On the VM (after first login and password change): Optional install of OpenClaw**

Unless you changed the defaults in the [vmconfig/user-data](./vmconfig/user-data) file, at this point the user is `ec2-user` and the password is `amazonlinux`.

```bash
cd /
sudo bash amazon.linux.openclaw.bash
sudo reboot now
```

After reboot, open a terminal and configure OpenClaw. This is past the install step in the OpenClaw [Getting Started](https://docs.openclaw.ai/start/getting-started).

```bash
openclaw onboard --install-daemon
```

Careful: you are about to give AI some precious access to your accounts!

![](images/001.openclaw.config.png)

Read more [here](READ.MORE.md) about the details of the VM creation process.

