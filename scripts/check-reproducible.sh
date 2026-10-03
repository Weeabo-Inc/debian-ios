#!/bin/bash
# debian-ios/scripts/check-reproducible.sh
#
# Prove the recipe is reproducible instead of claiming it. Builds every variant
# twice, from the same pinned and SHA-256-verified inputs, into two independent
# output and work trees, then compares the artefacts byte for byte.
#
# Two comparisons are made on purpose:
#   * the compressed .cpio.gz  -- this is the shipped artefact;
#   * the uncompressed .cpio   -- identical member list AND member order, which is
#     the part a naive rebuild usually gets wrong (timestamps, inode order, owner).
#
# Exit 0 only if every variant matched.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CACHE=${CACHE:-/root/arlo/cache}
SRC=${SRC:-/root/arlo/src}
RA=${RA:-/root/arlo/repro-a}
RB=${RB:-/root/arlo/repro-b}
PINS="$SRC/pins/bookworm-arm64.pins"

for D in "$RA" "$RB"; do rm -rf "$D"; mkdir -p "$D/dist" "$D/work"; done

echo "=== build A (independent work tree) ==="
"$HERE/build-initramfs.sh" --variant all --out "$RA/dist" --cache "$CACHE" \
  --work "$RA/work" --overlay "$SRC/overlay" --pins "$PINS" > "$RA/build.log" 2>&1
tail -n 4 "$RA/build.log"

echo "=== build B (from scratch again, same inputs) ==="
"$HERE/build-initramfs.sh" --variant all --out "$RB/dist" --cache "$CACHE" \
  --work "$RB/work" --overlay "$SRC/overlay" --pins "$PINS" > "$RB/build.log" 2>&1
tail -n 4 "$RB/build.log"

RC=0
echo
echo "=== comparison ==="
printf '%-34s %-10s %s\n' artefact result sha256
for v in min dash debian; do
  for ext in cpio.gz cpio; do
    f="arlo-initramfs-$v.$ext"
    A=$(sha256sum "$RA/dist/$f" | cut -d' ' -f1)
    B=$(sha256sum "$RB/dist/$f" | cut -d' ' -f1)
    if [ "$A" = "$B" ]; then
      printf '%-34s %-10s %s\n' "$f" "IDENTICAL" "$A"
    else
      printf '%-34s %-10s A=%s B=%s\n' "$f" "DIFFERS" "$A" "$B"
      RC=1
    fi
  done
done

echo
if [ "$RC" -eq 0 ]; then
  echo "REPRODUCIBLE: two independent builds produced byte-identical artefacts."
else
  echo "NOT REPRODUCIBLE: see the DIFFERS rows above." >&2
fi
exit "$RC"
