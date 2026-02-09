#!/bin/bash
set -e

echo ">>> 1. Installing dependencies..."
sudo apt update
sudo apt install -y cmake git g++ libsdl2-dev libsdl2-image-dev libsdl2-mixer-dev libsdl2-ttf-dev libsdl2-gfx-dev
curl -fsSL https://deb.nodesource.com | sudo -E bash -
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
NODE_MAJOR=22
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | sudo tee /etc/apt/sources.list.d/nodesource.list
sudo apt-get update
sudo apt-get install nodejs -y

echo ">>> 2. Building OpenClaw..."
rm -rf ~/OpenClaw
git clone https://github.com/pjasicek/OpenClaw.git ~/OpenClaw
mkdir -p ~/OpenClaw/build && cd ~/OpenClaw/build
cmake ..
make -j$(nproc)

echo ">>> SETUP COMPLETE."
echo "To play, copy CLAW.REZ from the original game to ~/OpenClaw/build/ and run:"
echo "  cd ~/OpenClaw/build && ./openclaw"
