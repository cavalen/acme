#!/bin/bash

# Customization
echo 'IP=$(ip addr show dev eth0 | grep -oP "(?<=inet ).*(?=/)")' >>~/.bashrc
echo 'export PS1="\[\e[33m\]ubuntu-vm\[\e[m\]@\[\e[32m\]$IP\[\e[m\]:[\[\e[36m\]\w\[\e[m\]]: " ' >>~/.bashrc
echo 'alias l="ls -la --color=auto --human-readable --time-style=long-iso --group-directories-first"' >>~/.bashrc

# Install Docker
sudo apt update -y
sudo apt install -y software-properties-common docker.io docker-compose
sudo systemctl enable docker
sudo systemctl start docker
echo -e "Docker Installed"

# Run containers
cd /home/ubuntu/
git clone https://github.com/f5devcentral/f5-waf-elk-dashboards
docker-compose -f docker-compose.yaml up -d
