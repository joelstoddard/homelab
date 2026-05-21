#!/usr/bin/env bash
# Emits the TF_ENCRYPTION HCL for OpenTofu state encryption.
# Reads state_encryption_passphrase from opentofu/secrets.sops.yaml.
#
# OpenTofu accepts the entire encryption config via the TF_ENCRYPTION
# env var. HCL form (not JSON) — JSON form rejects bare cross-block
# references (key_provider.pbkdf2.main etc.) with an "Invalid expression"
# parser error.

set -euo pipefail

HERE="$(cd "$(dirname "$0")"/.. && pwd)"
SECRETS="$HERE/secrets.sops.yaml"

if [[ ! -f "$SECRETS" ]]; then
    echo "$SECRETS missing; run 'make bootstrap-secrets' from repo root." >&2
    exit 1
fi

PASSPHRASE="$(sops -d --extract '["state_encryption_passphrase"]' "$SECRETS")"

# Passphrase is base64 (no quotes/backslashes) but escape defensively.
ESCAPED_PASSPHRASE="${PASSPHRASE//\\/\\\\}"
ESCAPED_PASSPHRASE="${ESCAPED_PASSPHRASE//\"/\\\"}"

cat <<EOF
key_provider "pbkdf2" "main" {
  passphrase = "${ESCAPED_PASSPHRASE}"
}
method "aes_gcm" "main" {
  keys = key_provider.pbkdf2.main
}
state {
  method = method.aes_gcm.main
}
plan {
  method = method.aes_gcm.main
}
EOF
