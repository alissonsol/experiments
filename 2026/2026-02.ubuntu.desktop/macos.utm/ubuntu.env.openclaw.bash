#!/bin/bash

# Install Git
sudo apt-get install git -y

# Install NVM and node
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"
nvm install 22

# Install OpenClaw
npm install -g openclaw@latest

# Run OpenClaw onboarding (installs daemon with defaults, no interactive prompts)
openclaw onboard --install-daemon --non-interactive --workspace ~/openclaw

# Verify OpenClaw installation (non-interactive to skip prompts)
openclaw doctor --non-interactive

# Show installed versions
echo "Git: `git --version`"
echo "Node.js: `node --version`"
echo "npm: `npm --version`"
echo "OpenClaw: `openclaw --version`"