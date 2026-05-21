#!/usr/bin/env bash
# Downloads the dklesev/pihole Terraform provider into a filesystem mirror so
# OpenTofu can find it (the provider isn't on the OpenTofu registry).
#
# Emits the resolved PLUGIN_MIRROR_ROOT on its final stdout line so the
# script is useful interactively. The Makefile does NOT consume that
# output — it derives the same path independently from its own
# PLUGIN_MIRROR_ROOT variable (which also honours the env-var override).
#
# Usage:
#   ./scripts/ensure-pihole-provider.sh
#
# Override install location (env var honoured by both this script and
# the Makefile so the two stay aligned):
#   PLUGIN_MIRROR_ROOT=/some/other/path ./scripts/ensure-pihole-provider.sh

set -euo pipefail

PIHOLE_PROVIDER_VERSION="1.0.7"
PLUGIN_MIRROR_ROOT="${PLUGIN_MIRROR_ROOT:-${HOME}/.local/share/opentofu/plugin-mirror}"

# Expected sha256 of each zip artifact, looked up via expected_sha_for
# below — lifted from the upstream v1.0.7 SHA256SUMS. Bump these when
# bumping PIHOLE_PROVIDER_VERSION. The script verifies the download
# against the expected value BEFORE unpacking — a compromised release
# or a MitM with valid TLS termination would otherwise hand us a
# binary that then runs against the Proxmox API and Pi-hole admin.
#
# (Plain `case` rather than `declare -A` to stay portable — macOS
# ships bash 3.2 by default and lacks associative-array support.)
expected_sha_for() {
    case "$1" in
        linux_amd64) echo "8863a0f450613d48ba3ea8ea6735dde2edad27dfe5001c7a93a15b262043c638" ;;
        linux_arm64) echo "3d37ac1f238764eb210f18281a2cbf92b2031b9470401f42e09b78973ccf9b35" ;;
        *)           echo "" ;;
    esac
}

# ---------------------------------------------------------------------------
# Detect OS / arch (for the path computation only — the supported-OS
# guard further down only fires when a fresh download is needed).
# ---------------------------------------------------------------------------
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$(uname -m)" in
    x86_64)        ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *)             ARCH="$(uname -m)" ;;
esac

PROVIDER_DIR="${PLUGIN_MIRROR_ROOT}/registry.terraform.io/dklesev/pihole/${PIHOLE_PROVIDER_VERSION}/${OS}_${ARCH}"
PROVIDER_BINARY="${PROVIDER_DIR}/terraform-provider-pihole_v${PIHOLE_PROVIDER_VERSION}"

# ---------------------------------------------------------------------------
# Idempotency fast-path — if a binary for the host already lives in the
# mirror, accept it regardless of platform. Lets existing installs
# survive the supported-OS narrowing below.
# ---------------------------------------------------------------------------
if [[ -x "${PROVIDER_BINARY}" ]]; then
    echo "${PLUGIN_MIRROR_ROOT}"
    exit 0
fi

# ---------------------------------------------------------------------------
# Supported-OS guard — only fires when a fresh download is needed.
# The homelab targets Linux operator workstations on amd64 or arm64
# (same shape install.sh provisions). YAGNI: don't carry darwin /
# freebsd / windows download paths until a real consumer needs them.
# ---------------------------------------------------------------------------
if [[ "$OS" != "linux" ]]; then
    echo "unsupported OS: $(uname -s). The homelab targets Linux operator workstations only." >&2
    exit 1
fi
if [[ "$ARCH" != "amd64" && "$ARCH" != "arm64" ]]; then
    echo "unsupported arch: $(uname -m). The homelab targets amd64 and arm64 only." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
for _cmd in curl unzip; do
    command -v "${_cmd}" >/dev/null 2>&1 || {
        echo "${_cmd} is required but not installed." >&2
        exit 1
    }
done

# ---------------------------------------------------------------------------
# Download and install
# ---------------------------------------------------------------------------
ZIP_NAME="terraform-provider-pihole_${PIHOLE_PROVIDER_VERSION}_${OS}_${ARCH}.zip"
DOWNLOAD_URL="https://github.com/dklesev/terraform-provider-pihole/releases/download/v${PIHOLE_PROVIDER_VERSION}/${ZIP_NAME}"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

echo "Downloading dklesev/pihole v${PIHOLE_PROVIDER_VERSION} (${OS}/${ARCH})..." >&2
curl -fsSL -o "${TMPDIR}/${ZIP_NAME}" "${DOWNLOAD_URL}"

# Verify the zip's sha256 matches the expected value pinned above
# before unpacking — otherwise a tampered release runs as the
# operator's tofu binary the moment ` make apply ` is invoked.
expected_sha="$(expected_sha_for "${OS}_${ARCH}")"
if [[ -z "${expected_sha}" ]]; then
    echo "No expected sha256 pinned for ${OS}_${ARCH}; refusing to install an unverified binary." >&2
    exit 1
fi
actual_sha="$(sha256sum "${TMPDIR}/${ZIP_NAME}" | awk '{print $1}')"
if [[ "${actual_sha}" != "${expected_sha}" ]]; then
    echo "sha256 mismatch for ${ZIP_NAME}:" >&2
    echo "  expected: ${expected_sha}" >&2
    echo "  actual:   ${actual_sha}" >&2
    exit 1
fi

echo "Unpacking..." >&2
unzip -q "${TMPDIR}/${ZIP_NAME}" -d "${TMPDIR}/unpacked"

mkdir -p "${PROVIDER_DIR}"
mv "${TMPDIR}/unpacked/terraform-provider-pihole_v${PIHOLE_PROVIDER_VERSION}" \
   "${PROVIDER_BINARY}"
chmod +x "${PROVIDER_BINARY}"

echo "Installed: ${PROVIDER_BINARY}" >&2
echo "${PLUGIN_MIRROR_ROOT}"
