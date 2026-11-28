# shellcheck shell=bash
# Sourced by install.sh. Installs a release download only when its SHA-256
# matches the checksum file published with the same release.

# fetch_verified <url> <sums_url> <asset_name> <dest>
fetch_verified() {
    local url="$1" sums_url="$2" asset="$3" dest="$4" tmp sums want
    tmp="$(mktemp)" || return 1
    if ! curl -fsSL -o "$tmp" "$url" || ! sums="$(curl -fsSL "$sums_url")"; then
        rm -f "$tmp"
        return 1
    fi
    # "<hash>  <name>" lines (a leading * marks binary mode), or kubectl's bare hash.
    if [[ "$(wc -w <<<"$sums")" -eq 1 ]]; then
        want="$sums"
    else
        want="$(awk -v a="$asset" '$2 == a || $2 == "*" a {print $1; exit}' <<<"$sums")"
    fi
    if [[ ! "$want" =~ ^[0-9a-f]{64}$ ]]; then
        echo "no checksum for: $asset" >&2
        rm -f "$tmp"
        return 1
    fi
    if [[ "$(sha256sum "$tmp" | awk '{print $1}')" != "$want" ]]; then
        echo "checksum mismatch: $asset" >&2
        rm -f "$tmp"
        return 1
    fi
    install -m 0755 "$tmp" "$dest"
    rm -f "$tmp"
}
