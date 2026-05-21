#!/bin/bash
# Lands the operator-private credentials this repo expects:
#   - ~/.config/sops/age/keys.txt   (age private key, points SOPS_AGE_KEY_FILE)
#     decrypts ansible/inventory/host_vars/*.sops.yaml at apply time.
#   - ~/.config/netbox/env          (NETBOX_API + NETBOX_TOKEN exports)
#     sourced by the operator's shell rc so the netbox.netbox inventory
#     plugin can reach NetBox.
#
# Idempotent: refuses to overwrite an existing file unless --force is
# passed. Run as the operator account, NOT root — these are user-private.
#
# Usage:
#   ./bootstrap-secrets.sh [--force]

set -euo pipefail

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    echo "Run as your operator user, not root. Secrets live under \$HOME." >&2
    exit 1
fi

FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

AGE_KEY_FILE="${HOME}/.config/sops/age/keys.txt"
NETBOX_ENV_FILE="${HOME}/.config/netbox/env"

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing '$1'. Run install.sh first." >&2
        exit 1
    fi
}

write_protected() {
    # $1: path. $2: contents (from stdin). Locks 0600 + parent dir 0700.
    local path="$1"
    install -d -m 0700 "$(dirname "$path")"
    install -m 0600 /dev/null "$path"
    cat > "$path"
}

# ---- age private key ----
echo ">> Age private key  -> $AGE_KEY_FILE"
if [[ -f "$AGE_KEY_FILE" && $FORCE -ne 1 ]]; then
    echo "  exists, skipping (re-run with --force to replace)"
else
    require_cmd age-keygen
    echo
    echo "  1) Generate a new key (new operator)"
    echo "  2) Paste an existing key (copying from another machine)"
    read -rp "  choice [1/2]: " choice
    case "$choice" in
        1)
            install -d -m 0700 "$(dirname "$AGE_KEY_FILE")"
            age-keygen -o "$AGE_KEY_FILE" 2>&1
            chmod 600 "$AGE_KEY_FILE"
            echo
            echo "  Add the public key above to .sops.yaml under 'creation_rules',"
            echo "  then re-encrypt covered files:"
            echo "    sops updatekeys ansible/inventory/host_vars/<host>.sops.yaml"
            ;;
        2)
            echo "  Paste the full key file contents (including '# created:' /"
            echo "  '# public key:' header lines). End with Ctrl-D on its own line."
            write_protected "$AGE_KEY_FILE" </dev/stdin
            ;;
        *)
            echo "Invalid choice." >&2
            exit 1
            ;;
    esac
fi

# ---- NetBox env file ----
echo
echo ">> NetBox credentials  -> $NETBOX_ENV_FILE"
if [[ -f "$NETBOX_ENV_FILE" && $FORCE -ne 1 ]]; then
    echo "  exists, skipping (re-run with --force to replace)"
else
    read -rp "  NetBox URL (e.g. https://netbox.example.com): " netbox_url
    read -rsp "  NetBox API token: " netbox_token
    echo
    if [[ -z "$netbox_url" || -z "$netbox_token" ]]; then
        echo "Both URL and token are required." >&2
        exit 1
    fi
    write_protected "$NETBOX_ENV_FILE" <<EOF
# Sourced by the operator's shell rc. The netbox.netbox.nb_inventory
# plugin reads NETBOX_API (note: not NETBOX_URL — the plugin's
# documented var name) and NETBOX_TOKEN at inventory-resolution time.
export NETBOX_API="$netbox_url"
export NETBOX_TOKEN="$netbox_token"
EOF
fi

# ---- OpenTofu secrets ----
# secrets.sops.yaml holds the state encryption passphrase and the
# Proxmox API endpoint URL. Unlike the Age key + NetBox env (which are
# operator-private under $HOME), this file is committed to the repo —
# the contents are SOPS-encrypted at rest.
#
# --force rotates the passphrase, which renders every existing
# encrypted state file unreadable. Don't pass --force unless you have
# rebuilt state from scratch.
OPENTOFU_SECRETS_FILE="opentofu/secrets.sops.yaml"
echo
echo ">> OpenTofu secrets   -> $OPENTOFU_SECRETS_FILE (SOPS-encrypted, committed)"
if [[ -f "$OPENTOFU_SECRETS_FILE" && $FORCE -ne 1 ]]; then
    echo "  exists, skipping (re-run with --force to ROTATE — DESTRUCTIVE)"
else
    require_cmd sops
    require_cmd openssl
    if [[ ! -f "$AGE_KEY_FILE" ]]; then
        echo "  Age key file ($AGE_KEY_FILE) missing; cannot encrypt." >&2
        exit 1
    fi
    if ! grep -q 'opentofu/.\*\\.sops\\.ya' .sops.yaml; then
        echo "  .sops.yaml is missing the opentofu/ creation_rule." >&2
        echo "  Add a rule for path_regex 'opentofu/.*\\.sops\\.ya?ml\$' and re-run." >&2
        exit 1
    fi
    if [[ -f "$OPENTOFU_SECRETS_FILE" && $FORCE -eq 1 ]]; then
        echo "  --force given; rotating passphrase. All existing state files will become unreadable." >&2
        echo "  Press Ctrl-C in the next 5s to abort." >&2
        sleep 5
    fi
    read -rp "  Proxmox API endpoint URL (e.g. https://<leader>.example.com:8006/): " proxmox_endpoint
    if [[ -z "$proxmox_endpoint" ]]; then
        echo "Endpoint URL is required." >&2
        exit 1
    fi
    PASSPHRASE="$(openssl rand -base64 32)"
    SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" \
        sops --encrypt --input-type yaml --output-type yaml \
        --filename-override "$OPENTOFU_SECRETS_FILE" /dev/stdin \
        > "$OPENTOFU_SECRETS_FILE" <<EOF
state_encryption_passphrase: "$PASSPHRASE"
proxmox_endpoint: "$proxmox_endpoint"
EOF
    echo "  Wrote $OPENTOFU_SECRETS_FILE. Commit it."
fi

# ---- Final hints ----
echo
echo "Done. Add these lines to your shell rc (~/.zshrc, ~/.bashrc, …):"
echo "  export SOPS_AGE_KEY_FILE=\"$AGE_KEY_FILE\""
echo "  source \"$NETBOX_ENV_FILE\""
echo
echo "Then start a fresh shell (or 'source' your rc) and run 'make build' from ansible/."
