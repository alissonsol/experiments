#!/bin/bash

# Install Docker
dnf -y install dnf-plugins-core iptables container-selinux
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf --releasever=9 -y update
dnf --releasever=9 -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
docker --version

# Docker cleanup
rm /etc/yum.repos.d/docker-ce.repo
dnf makecache
groupadd docker
usermod -aG docker $USER
newgrp docker
docker run hello-world