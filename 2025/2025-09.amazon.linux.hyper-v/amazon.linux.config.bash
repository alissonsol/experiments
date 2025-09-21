#!/bin/bash

# Install the GUI
dnf update -y
dnf upgrade -y
dnf groupinstall "Desktop" -y

# Install the JDK
dnf install -y java-21-amazon-corretto-devel
java -version
javac -version
export JAVA_HOME=/etc/alternatives/java_sdk
echo 'export JAVA_HOME=/etc/alternatives/java_sdk' | sudo tee -a /etc/bashrc

# Install .NET Core
rpm -Uvh https://packages.microsoft.com/config/centos/8/packages-microsoft-prod.rpm
dnf -y update
dnf -y install dotnet-sdk-9.0
dotnet --version

# Install Git
dnf -y install git
git --version

# Install Visual Studio Code
rpm --import https://packages.microsoft.com/keys/microsoft.asc
sh -c 'echo -e "[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/vscode.repo'
dnf -y install code

# Show installed versions
echo "Java: `javac -version`"
echo "DotNet: `dotnet --version`"
echo "Git: `git --version`"
echo "Visual Studio Code: `code --version`"