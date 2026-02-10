#!/bin/bash

# Determine the real user (even when running with sudo)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

# Install Git
sudo apt-get install git -y

# Install NVM, Node.js, and OpenClaw as the real user
sudo -u "$REAL_USER" bash << 'EOF'
# Install NVM
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"

# Install Node.js
nvm install 22

# Install OpenClaw
npm install -g openclaw@latest

# Run OpenClaw onboarding (installs daemon with defaults, no interactive prompts)
openclaw onboard --install-daemon --non-interactive --workspace ~/openclaw

# Verify OpenClaw installation (non-interactive to skip prompts)
openclaw doctor --non-interactive
EOF

# Make openclaw available to all users by symlinking to /usr/local/bin
OPENCLAW_PATH=$(sudo -u "$REAL_USER" bash -c 'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; which openclaw')
if [ -n "$OPENCLAW_PATH" ]; then
    sudo ln -sf "$OPENCLAW_PATH" /usr/local/bin/openclaw
fi

# Show installed versions
echo "Git: $(git --version)"
sudo -u "$REAL_USER" bash -c '
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    echo "Node.js: $(node --version)"
    echo "npm: $(npm --version)"
    echo "OpenClaw: $(openclaw --version)"
'