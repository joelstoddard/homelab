#!/bin/bash
# Installs the host-level prerequisites for running the homelab Ansible
# automation against this machine as the PXE server. Idempotent.
#
# Usage: sudo ./install.sh [target-user]
#   target-user defaults to $SUDO_USER; falls back to a clear error.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (e.g. sudo ./install.sh)" >&2
    exit 1
fi

TARGET_USER="${1:-${SUDO_USER:-}}"
if [[ -z "$TARGET_USER" ]]; then
    echo "No target user resolved. Pass the operator account as the first arg" >&2
    echo "(it gets added to the docker group). Example: sudo ./install.sh joel" >&2
    exit 1
fi
if ! id "$TARGET_USER" &>/dev/null; then
    echo "User '$TARGET_USER' does not exist." >&2
    exit 1
fi

# /etc/os-release exposes ID (debian, ubuntu, …) and VERSION_CODENAME
# (trixie, jammy, …). Docker ships separate repos for debian and ubuntu;
# pick whichever matches.
. /etc/os-release
case "$ID" in
    debian|ubuntu) DOCKER_REPO_DISTRO="$ID" ;;
    *) echo "Unsupported distro: $ID. Edit install.sh to add a case." >&2; exit 1 ;;
esac
CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
if [[ -z "$CODENAME" ]]; then
    echo "Could not determine release codename from /etc/os-release." >&2
    exit 1
fi

echo ">> Updating apt cache"
apt-get update

echo ">> Installing base tooling (curl, ca-certificates, gnupg, python3-venv, git, make, rsync)"
apt-get install -y \
    ca-certificates curl gnupg \
    python3 python3-pip python3-venv \
    git make rsync

# age + sops decrypt the per-host secrets under
# ansible/inventory/host_vars/*.sops.yaml at apply time, via the
# community.sops.load_vars pre-task in each playbook.
# age is in apt; sops isn't packaged for Debian/Ubuntu, so pull the
# upstream binary. Bump SOPS_VERSION when operator workstations move.
echo ">> Installing age (encrypted host_vars decryption)"
apt-get install -y age

SOPS_VERSION="v3.12.2"
SOPS_ARCH="$(dpkg --print-architecture)"
echo ">> Installing sops ${SOPS_VERSION} from upstream release"
curl -fsSL -o /usr/local/bin/sops \
    "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.${SOPS_ARCH}"
chmod +x /usr/local/bin/sops

echo ">> Installing Docker apt key + repo (${DOCKER_REPO_DISTRO}/${CODENAME})"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/${DOCKER_REPO_DISTRO}/gpg" \
    -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_REPO_DISTRO} ${CODENAME} stable
EOF
apt-get update

echo ">> Installing Docker engine + compose plugin"
apt-get install -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

echo ">> Enabling docker daemon"
systemctl enable --now docker

echo ">> Adding ${TARGET_USER} to docker group"
usermod -aG docker "$TARGET_USER"

echo
echo "Done. Verify with:  docker --version  &&  docker compose version"
echo "${TARGET_USER} must start a fresh login session (or run 'newgrp docker')"
echo "before Docker commands work without sudo."
