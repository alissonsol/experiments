#!/bin/bash
set -e

echo ">>> 1. Installing GUI (GNOME) and Dev Tools..."
sudo dnf update -y
sudo dnf groupinstall "Desktop" "Development Tools" -y
sudo systemctl set-default graphical.target

echo ">>> 2. Installing Dependencies (SDL2, CMake)..."
sudo dnf install -y cmake3 git gcc-c++ SDL2-devel SDL2_image-devel SDL2_mixer-devel SDL2_ttf-devel

echo ">>> 3. Building OpenClaw..."
rm -rf OpenClaw
git clone https://github.com/pjasicek/OpenClaw.git
cd OpenClaw
mkdir build && cd build
cmake ..
make -j$(nproc)

echo ">>> SETUP COMPLETE."
echo "To play:"
echo "1. Reboot the VM: sudo reboot"
echo "2. Login to the GUI."
echo "3. Copy your 'CLAW.WAD' file to: ~/OpenClaw/build/Assets/"
echo "4. Run: ~/OpenClaw/build/openclaw"
EOF
