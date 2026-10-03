#!/bin/bash
# Recon inside the Linux VM: which Debian versions are current for the packages
# this initramfs needs, and what is already installed here.
set -uo pipefail

CACHE=${CACHE:-/root/arlo/cache}
mkdir -p "$CACHE"
cd "$CACHE"

MIRROR=${MIRROR:-http://deb.debian.org/debian}
SUITE=${SUITE:-bookworm}

if [ ! -s Packages ]; then
  echo "fetching $MIRROR/dists/$SUITE/main/binary-arm64/Packages.xz"
  curl -fsSL -o Packages.xz "$MIRROR/dists/$SUITE/main/binary-arm64/Packages.xz" || exit 1
  xz -dc Packages.xz > Packages || exit 1
fi
echo "Packages index lines: $(wc -l < Packages)"

echo "=== versions of candidate packages ==="
for p in busybox-static dash coreutils dpkg sed grep tar gzip procps debianutils libc6 libacl1 libattr1 libselinux1 libmd0 libbz2-1.0 liblzma5 zlib1g libpcre2-8-0 libgmp10 libncursesw6 libtinfo6; do
  awk -v want="$p" '
    BEGIN{RS="";FS="\n"}
    { name=""; ver=""; fn="";
      for(i=1;i<=NF;i++){
        if ($i ~ /^Package: /) name=substr($i,10);
        if ($i ~ /^Version: /) ver=substr($i,10);
        if ($i ~ /^Filename: /) fn=substr($i,11);
      }
      if (name==want) printf "%-18s %-22s %s\n", name, ver, fn;
    }' Packages | tail -3 | sed "s/^/  /"
done

echo "=== tooling present in this VM ==="
for t in qemu-system-aarch64 cpio gzip xz curl dpkg-deb awk sha256sum file; do
  printf '  %-22s %s\n' "$t" "$(command -v $t || echo MISSING)"
done

echo "=== how many CPUs / RAM ==="
echo "  nproc=$(nproc)"
free -m | awk 'NR==2{print "  mem_total_MB="$2}'
