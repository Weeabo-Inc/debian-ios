#!/bin/bash
# debian-ios/scripts/build-16k-standin-kernel.sh
#
# Build a MINIMAL 16K-page arm64 kernel, for one purpose only: to run the initramfs
# on the same page granule as the A9, so that "user space is granule-agnostic" stops
# being an inference and becomes a measurement.
#
# THIS IS STILL A STAND-IN, NOT THE A9 KERNEL:
#   * generic arm64 `defconfig`, i.e. QEMU `virt` platform -- no Apple platform support;
#   * no modules, no device tree of ours, no hoolock patches;
#   * the only thing it shares with our target is the 16K granule and the kernel
#     version family (6.1.x, matching the other stand-in so results are comparable).
#
# Its result proves something narrow and worth having: the same initramfs bytes reach
# a working shell when the kernel uses 16K pages.
set -euo pipefail

VER=${VER:-6.1.176}
WORK=${WORK:-/root/arlo/kernel16k}
JOBS=${JOBS:-$(nproc)}
TOOLCHAIN=${TOOLCHAIN:-LLVM=1}
BASE=https://cdn.kernel.org/pub/linux/kernel/v6.x

mkdir -p "$WORK/src" "$WORK/dist"
cd "$WORK"

# ---------------------------------------------------------------- fetch ----
if [ ! -s "linux-$VER.tar.xz" ]; then
  echo "== downloading $BASE/linux-$VER.tar.xz"
  curl -fsSL -o "linux-$VER.tar.xz.part" "$BASE/linux-$VER.tar.xz"
  mv "linux-$VER.tar.xz.part" "linux-$VER.tar.xz"
fi
curl -fsSL -o sha256sums.asc "$BASE/sha256sums.asc"
WANT=$(grep -E " linux-$VER\.tar\.xz\$" sha256sums.asc | awk '{print $1}')
GOT=$(sha256sum "linux-$VER.tar.xz" | cut -d' ' -f1)
echo "== tarball sha256 (kernel.org published list, PGP signature NOT verified):"
echo "   expected $WANT"
echo "   got      $GOT"
[ -n "$WANT" ] || { echo "ERROR: could not find linux-$VER.tar.xz in the published list" >&2; exit 1; }
[ "$WANT" = "$GOT" ] || { echo "ERROR: tarball hash mismatch" >&2; exit 1; }

if [ ! -d "linux-$VER" ]; then
  echo "== extracting"
  tar -xf "linux-$VER.tar.xz"
fi
cd "linux-$VER"

# --------------------------------------------------------------- config ----
# Start from defconfig (boots on virt, all the generic drivers), then make the two
# changes that matter: 16K pages instead of 4K, and the console/initramfs bits we
# depend on being definitely on rather than merely defaulted.
echo "== configuring"
make ARCH=arm64 defconfig >/dev/null
./scripts/config --disable ARM64_4K_PAGES
./scripts/config --enable  ARM64_16K_PAGES
./scripts/config --enable  SERIAL_AMBA_PL011
./scripts/config --enable  SERIAL_AMBA_PL011_CONSOLE
./scripts/config --enable  DEVTMPFS
./scripts/config --enable  DEVTMPFS_MOUNT
./scripts/config --enable  BLK_DEV_INITRD
./scripts/config --enable  RD_GZIP
./scripts/config --enable  BINFMT_SCRIPT
./scripts/config --enable  TMPFS
./scripts/config --enable  PROC_FS
./scripts/config --enable  SYSFS
make ARCH=arm64 olddefconfig >/dev/null

echo "== proof the config took (this is the whole point of this kernel)"
for o in CONFIG_ARM64_16K_PAGES CONFIG_ARM64_4K_PAGES CONFIG_RD_GZIP CONFIG_BINFMT_SCRIPT \
         CONFIG_DEVTMPFS_MOUNT CONFIG_SERIAL_AMBA_PL011_CONSOLE CONFIG_BLK_DEV_INITRD; do
  printf '   %-34s %s\n' "$o" "$(grep -E "^$o=|^# $o is not set" .config || echo ABSENT)"
done
grep -q '^CONFIG_ARM64_16K_PAGES=y' .config || { echo "ERROR: 16K pages did not stick" >&2; exit 1; }
grep -q '^CONFIG_ARM64_4K_PAGES=y'  .config && { echo "ERROR: 4K pages still enabled" >&2; exit 1; }

# ---------------------------------------------------------------- build ----
echo "== building Image with $TOOLCHAIN -j$JOBS"
make -j"$JOBS" ARCH=arm64 $TOOLCHAIN Image 2>&1 | tail -n 15

cp -f arch/arm64/boot/Image "$WORK/dist/Image-16k-$VER"
echo "== artefact: $WORK/dist/Image-16k-$VER"
echo "   size  : $(stat -c %s "$WORK/dist/Image-16k-$VER")"
echo "   sha256: $(sha256sum "$WORK/dist/Image-16k-$VER" | cut -d' ' -f1)"
{
  echo "STAND-IN 16K-PAGE KERNEL -- NOT the arlo A9 kernel."
  echo "linux $VER, arm64 defconfig (QEMU virt), $(grep -c '^CONFIG_' .config) config symbols"
  echo "granule: CONFIG_ARM64_16K_PAGES=y (matches A9), CONFIG_ARM64_4K_PAGES unset"
  echo "toolchain: make ARCH=arm64 $TOOLCHAIN Image   ($(command -v clang >/dev/null && clang --version | head -1 || echo '?'))"
  echo "purpose: run the initramfs on a 16K-granule kernel so the page-size claim is"
  echo "         measured rather than inferred. Says nothing about Apple hardware."
  echo "sha256: $(sha256sum "$WORK/dist/Image-16k-$VER" | cut -d' ' -f1)"
} > "$WORK/dist/STANDIN-KERNEL-16K.txt"
cat "$WORK/dist/STANDIN-KERNEL-16K.txt"
