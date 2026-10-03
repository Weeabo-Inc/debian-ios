#!/bin/bash
# debian-ios/scripts/fetch-standin-kernel.sh
#
# THE KERNEL THIS FETCHES IS A STAND-IN, NOT OURS.
#
# The initramfs is the artefact under test; to boot it on a virtual arm64 machine
# we need *an* arm64 kernel that boots on QEMU's `virt` machine. Our real target is
# the A9 hoolock kernel built by task-6 (16K pages, Apple platform) -- it would not
# boot on `virt` even if it existed, because the DT platform is a different world.
#
# So: pull ONLY /boot/vmlinuz out of a pinned Debian arm64 kernel package (same
# signed index, same SHA-256 verification as the userland), and label every result
# produced from it as a stand-in. It is a 4K-page kernel; see README.md for what
# that does and does not invalidate.
set -euo pipefail

CACHE=${CACHE:-/root/arlo/cache}
DEST=${DEST:-/root/arlo/kernel-standin}
PINS=${PINS:-}
HERE=$(cd "$(dirname "$0")" && pwd)
KPKG=${KPKG:-linux-image-6.1.0-50-arm64}

mkdir -p "$CACHE" "$DEST"
MANIFEST="$CACHE/manifest-standin-kernel.tsv"

if [ -n "$PINS" ]; then
  "$HERE/fetch-inputs.sh" --packages "$KPKG" --cache "$CACHE" --pins "$PINS" \
    --no-deps --manifest "$MANIFEST" >/dev/null
else
  "$HERE/fetch-inputs.sh" --packages "$KPKG" --cache "$CACHE" \
    --no-deps --manifest "$MANIFEST" >/dev/null
fi

base=$(awk -F'\t' 'NF>=3 {print $3; exit}' "$MANIFEST")
ver=$(awk -F'\t' 'NF>=3 {print $2; exit}' "$MANIFEST")
sha=$(awk -F'\t' 'NF>=3 {print $4; exit}' "$MANIFEST")
[ -s "$CACHE/$base" ] || { echo "ERROR: kernel deb not in cache: $CACHE/$base" >&2; exit 1; }

echo "== stand-in kernel package: $KPKG $ver"
echo "== deb: $base  sha256=$sha"

# Extract only /boot/* -- the package also carries modules and DTBs we do not want.
rm -rf "$DEST/boot"
dpkg-deb --fsys-tarfile "$CACHE/$base" | tar -x -C "$DEST" --wildcards './boot/vmlinuz-*' './boot/config-*'

VMLINUZ=$(ls "$DEST"/boot/vmlinuz-* | head -1)
echo "== extracted: $VMLINUZ"
echo "== size: $(stat -c %s "$VMLINUZ") bytes"
echo "== sha256: $(sha256sum "$VMLINUZ" | cut -d' ' -f1)"
file "$VMLINUZ"

# Record provenance next to the kernel so no log can be read without it.
{
  echo "STAND-IN KERNEL -- NOT the arlo A9 kernel, NOT a 16K-page kernel."
  echo "package   : $KPKG $ver"
  echo "deb sha256: $sha"
  echo "file      : $VMLINUZ"
  echo "size      : $(stat -c %s "$VMLINUZ")"
  echo "sha256    : $(sha256sum "$VMLINUZ" | cut -d' ' -f1)"
  echo "purpose   : boot the initramfs on QEMU's arm64 'virt' machine to prove the"
  echo "            userland reaches a shell. It says nothing about the A9."
} > "$DEST/STANDIN-KERNEL.txt"
cat "$DEST/STANDIN-KERNEL.txt"
