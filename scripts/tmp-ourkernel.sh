#!/bin/bash
# tmp: verify kernel-engineer's console-variant kernel differs from the shipping
# config ONLY in the console symbols, then boot all three of my images on it.
set -e
K=/mnt/e/Reverseing/Arlo/a9linux/artefacts/kernel
mkdir -p /root/arlo/ourkernel
cp -f "$K/Image-16k-qemu-pl011" /root/arlo/ourkernel/
cp -f "$K/config-qemu-pl011.used" /root/arlo/ourkernel/
cp -f "$K/config.used" /root/arlo/ourkernel/
cp -f "$K/System.map-qemu-pl011" /root/arlo/ourkernel/ 2>/dev/null || true

echo "############ 1. what differs between shipping config and the console variant ############"
diff <(sort "$K/config.used") <(sort "$K/config-qemu-pl011.used") || true
echo "-- count of differing lines: $(diff <(sort "$K/config.used") <(sort "$K/config-qemu-pl011.used") | grep -c '^[<>]')"
echo "-- granule in the console variant:"
grep -E '^CONFIG_ARM64_(16K|4K|64K)_PAGES=' "$K/config-qemu-pl011.used" || true
echo "-- console symbols:"
grep -E '^CONFIG_SERIAL_(AMBA_PL011|AMBA_PL011_CONSOLE|SAMSUNG|SAMSUNG_CONSOLE)=' "$K/config-qemu-pl011.used" || true

echo
echo "############ 2. the image we will boot ############"
f=/root/arlo/ourkernel/Image-16k-qemu-pl011
echo "size  : $(stat -c %s "$f")"
echo "sha256: $(sha256sum "$f" | cut -d' ' -f1)"
file "$f"
