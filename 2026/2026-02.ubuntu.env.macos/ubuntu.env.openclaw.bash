#!/bin/bash
set -e

echo ">>> 1. Installing dependencies..."
sudo apt update
sudo apt install -y cmake git g++ libsdl2-dev libsdl2-image-dev libsdl2-mixer-dev libsdl2-ttf-dev libsdl2-gfx-dev

echo ">>> 2. Building OpenClaw..."
rm -rf ~/OpenClaw
git clone https://github.com/pjasicek/OpenClaw.git ~/OpenClaw
mkdir -p ~/OpenClaw/build && cd ~/OpenClaw/build
cmake ..
make -j$(nproc)

echo ">>> SETUP COMPLETE."
echo "To play, copy CLAW.REZ from the original game to ~/OpenClaw/build/ and run:"
echo "  cd ~/OpenClaw/build && ./openclaw"
