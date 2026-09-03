#!/bin/sh
# Unwrap a Linux EFI zboot kernel into the flat arm64 Image that u-boot's
# `booti` accepts. Talos ships its arm64 kernel as a PE ("MZ") with a zboot
# header:
#   0x00 "MZ"    0x04 "zimg"    0x08 u32 payload offset    0x0C u32 payload size
#   0x18 compression type, NUL-padded (e.g. "zstd22")
# The payload decompresses to a plain Image, recognisable by "ARM\x64" @ 0x38.
#
# usage: unwrap-zboot.sh <kernel-zboot> <out-image>
set -eu

in=$1
out=$2

[ "$(dd if="$in" bs=1 skip=4 count=4 2>/dev/null)" = "zimg" ] \
  || { echo "unwrap-zboot: $in is not an EFI zboot image" >&2; exit 1; }

comp=$(dd if="$in" bs=1 skip=24 count=4 2>/dev/null)
[ "$comp" = "zstd" ] \
  || { echo "unwrap-zboot: unsupported compression '$comp' (want zstd)" >&2; exit 1; }

off=$(od -An -tu4 -j 8  -N 4 "$in" | tr -d ' ')
size=$(od -An -tu4 -j 12 -N 4 "$in" | tr -d ' ')

tmp=$(mktemp "$out.XXXXXX")
trap 'rm -f "$tmp"' EXIT

tail -c +"$((off + 1))" "$in" | head -c "$size" | zstd -d -q -f -o "$tmp"

# "ARM\x64" — 0x64 is 'd'.
[ "$(dd if="$tmp" bs=1 skip=56 count=4 2>/dev/null)" = "ARMd" ] \
  || { echo "unwrap-zboot: decompressed payload lacks the arm64 Image magic" >&2; exit 1; }

mv "$tmp" "$out"
trap - EXIT
echo "unwrap-zboot: wrote $out ($(wc -c < "$out" | tr -d ' ') bytes)"
