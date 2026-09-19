#!/bin/bash
# Reverse of install.sh — removes the packages and binaries it lays down.
# Operator-private state (ansible/.venv, ~/.config/sops/, ~/.config/netbox/)
# is NOT touched: that belongs to the operator, not to install.sh.
#
# Usage: sudo ./uninstall.sh [target-user] [--remove-python3]
#   target-user defaults to $SUDO_USER, and is only used to offer the
#   docker group membership back.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (e.g. sudo ./uninstall.sh)" >&2
    exit 1
fi

REMOVE_PYTHON3=0
TARGET_USER=""
for arg in "$@"; do
    case "$arg" in
        --remove-python3) REMOVE_PYTHON3=1 ;;
        *) [[ -z "$TARGET_USER" ]] && TARGET_USER="$arg" ;;
    esac
done
TARGET_USER="${TARGET_USER:-${SUDO_USER:-}}"

prompt_yn() {
    local reply
    read -rp "$1 [y/N] " -n 1 reply
    echo
    [[ "$reply" =~ ^[Yy]$ ]]
}

# Before the packages go, while the group still exists. Nothing is asked on a
# host where install.sh never granted it.
if [[ -n "$TARGET_USER" ]] && id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    if prompt_yn "Remove ${TARGET_USER} from the docker group?"; then
        gpasswd -d "$TARGET_USER" docker
    fi
fi

echo ">> Removing Docker engine + plugins"
apt-get remove -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin \
    || echo "  (nothing to remove)"

echo ">> Removing Docker apt repo + key"
# /etc/apt/keyrings stays: install.sh creates it, but other repos share it.
rm -f /etc/apt/keyrings/docker.asc /etc/apt/sources.list.d/docker.list

echo ">> Removing the upstream binaries from /usr/local/bin"
rm -f /usr/local/bin/sops \
      /usr/local/bin/talosctl \
      /usr/local/bin/kubectl \
      /usr/local/bin/flux \
      /usr/local/bin/helm \
      /usr/local/bin/talhelper

echo ">> Removing the apt packages install.sh adds"
# tofu arrives as an upstream .deb, so apt owns it like any other package.
# ca-certificates, curl and gnupg are left alone: apt itself needs them.
apt-get remove -y age tofu arp-scan python3-pip python3-venv git make rsync \
    || echo "  (nothing to remove)"

# python3 is a core distro package and removing it takes half the system.
if [[ "$REMOVE_PYTHON3" -eq 1 ]] && prompt_yn "Really remove python3 (likely breaks the system)?"; then
    apt-get remove -y python3
fi

if prompt_yn "Remove /var/lib/docker (deletes all Docker images, containers, volumes)?"; then
    rm -rf /var/lib/docker
fi

echo ">> Cleanup"
apt-get autoremove -y
apt-get autoclean

echo
echo "Done. Operator state was left alone —"
echo "  - ~/.config/sops/age/keys.txt and ~/.config/netbox/env"
echo "  - ansible/.venv (run 'make clean' inside ansible/ or 'rm -rf ansible/.venv')"
