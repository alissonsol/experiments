# Ubuntu Desktop running in macOS UTM

Copyright (c) 2019-2026 by Alisson Sol

Minimal commands for creating the VM. Link to details at the end.

## One-time setup

**On the macOS host (one-time setup): Requirements**

Check latest instructions for `brew` from [brew.sh](https://brew.sh/)

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

After installing `brew`, you may need to open another terminal.

```bash
brew install --cask utm
brew install git
brew install powershell
brew install openssl qemu
brew install wget
```

**Getting only the needed folder**
```bash
git clone --filter=blob:none --sparse https://github.com/alissonsol/experiments.git
cd experiments
git sparse-checkout add 2026/2026-02.ubuntu.desktop/macos.utm
cd 2026/2026-02.ubuntu.desktop/macos.utm/
```

**On the macOS host: Getting the base image**

```bash
pwsh ./Get-Image.ps1
```

## For each VM

**On the macOS host (Terminal): Create VM**

```bash
pwsh ./New-VM.ps1
```

Or with a custom hostname:
```bash
pwsh ./New-VM.ps1 -VMName myhostname
```

Double-click `HOSTNAME.utm` on your Desktop to import it into UTM and start the VM. The Ubuntu installer will run automatically using autoinstall. <mark>This step may take a few minutes (~15)</mark>. The screen may not be shown. If not shown after ~15 minutes, stop and restart the VM.

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

## Optional install of OpenClaw

**On the VM (after reboot): OpenClaw install**

Open a terminal and enter the commands.

```bash
wget -O ubuntu.env.openclaw.bash https://raw.githubusercontent.com/alissonsol/experiments/refs/heads/main/2026/2026-02.ubuntu.desktop/macos.utm/ubuntu.env.openclaw.bash
chmod a+x ubuntu.env.openclaw.bash
sudo bash ./ubuntu.env.openclaw.bash
```

Open terminal and configure OpenClaw. This is past the install step in the OpenClaw [Getting Started](https://docs.openclaw.ai/start/getting-started).

```bash
openclaw onboard --install-daemon
```

<mark>Careful: you are about to give AI some precious access to your accounts!</mark>

Read more [here](READ.MORE.md) about the details of the VM creation process.

