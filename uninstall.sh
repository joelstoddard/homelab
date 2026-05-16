#!/bin/bash
# Reverse of install.sh — removes packages and binaries it laid down.
# Operator-private state (the venv under ansible/.venv, ~/.config/sops/,
# ~/.config/netbox/) is NOT touched: those belong to the operator, not
# install.sh.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (e.g. sudo ./uninstall.sh)" >&2
    exit 1
fi

prompt_yn() {
    local reply
    read -rp "$1 [y/N] " -n 1 reply
    echo
    [[ "$reply" =~ ^[Yy]$ ]]
}

echo ">> Removing Docker engine + plugins"
apt-get remove -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin \
    || echo "  (nothing to remove)"

echo ">> Removing Docker apt repo + key"
rm -f /etc/apt/keyrings/docker.asc /etc/apt/sources.list.d/docker.list

echo ">> Removing sops binary"
rm -f /usr/local/bin/sops

echo ">> Removing age and other install.sh-installed apt packages"
# python3 itself is not removed — it's a core distro package and pulling it
# uninstalls half the system. Pass --remove-python3 to force it.
apt-get remove -y age python3-pip python3-venv git make rsync \
    || echo "  (nothing to remove)"

if [[ "${1:-}" == "--remove-python3" ]] && prompt_yn "Really remove python3 (likely breaks the system)?"; then
    apt-get remove -y python3
fi

if prompt_yn "Remove /var/lib/docker (deletes all Docker images, containers, volumes)?"; then
    rm -rf /var/lib/docker
fi

echo ">> Cleanup"
apt-get autoremove -y
apt-get autoclean

echo
echo "Done. Note: operator state was left alone —"
echo "  - docker group membership (run 'gpasswd -d <user> docker' to remove)"
echo "  - ~/.config/sops/age/keys.txt and ~/.config/netbox/env"
echo "  - ansible/.venv (run 'make clean' inside ansible/ or 'rm -rf ansible/.venv')"
