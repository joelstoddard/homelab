#!/bin/bash

# This script uninstalls the dependencies installed by install.sh

# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit
fi

echo "Starting uninstallation process..."

# Uninstall Docker
echo "Uninstalling Docker..."
apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
if [ $? -eq 0 ]; then
    echo "Docker packages removed successfully."
else
    echo "Failed to remove Docker packages."
fi

# Remove Docker repository and GPG key
echo "Removing Docker repository and GPG key..."
rm -f /etc/apt/keyrings/docker.asc
rm -f /etc/apt/sources.list.d/docker.list
if [ $? -eq 0 ]; then
    echo "Docker repository configuration removed successfully."
else
    echo "Failed to remove Docker repository configuration."
fi

# Uninstall other packages
echo "Uninstalling other packages..."
apt remove -y python3-pip python3-venv git make
if [ $? -eq 0 ]; then
    echo "Other packages removed successfully."
else
    echo "Failed to remove other packages."
fi

# Note: python3 is a system package and removing it could break the system
# Ask for confirmation before removing python3
read -p "Do you want to remove python3? This may break your system. (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Uninstalling python3..."
    apt remove -y python3
    if [ $? -eq 0 ]; then
        echo "Python3 removed successfully."
    else
        echo "Failed to remove Python3."
    fi
else
    echo "Skipping python3 removal."
fi

# Remove Docker data directory
read -p "Do you want to remove Docker data? This will delete all Docker images and containers. (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Removing Docker data..."
    rm -rf /var/lib/docker
    if [ $? -eq 0 ]; then
        echo "Docker data removed successfully."
    else
        echo "Failed to remove Docker data."
    fi
else
    echo "Skipping Docker data removal."
fi

# Clean up
echo "Cleaning up..."
apt autoremove -y
apt autoclean

echo "Uninstallation completed. You may need to reboot your system."