#!/bin/bash

# Install the GUI
dnf update -y
dnf upgrade -y
dnf groupinstall "Desktop" -y

# Install Git
dnf -y install git
git --version

# Install Node.js 22+ (required for OpenClaw)
curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -
dnf -y install nodejs
node --version
npm --version

# Install OpenClaw
npm install -g openclaw@latest

# Run OpenClaw onboarding (installs daemon with defaults, no interactive prompts)
openclaw onboard --install-daemon --non-interactive --workspace ~/openclaw

# Verify OpenClaw installation
openclaw doctor

# Show installed versions
echo "Git: `git --version`"
echo "Node.js: `node --version`"
echo "npm: `npm --version`"
echo "OpenClaw: `openclaw --version`"