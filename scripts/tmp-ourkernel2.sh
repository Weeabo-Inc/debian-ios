#!/bin/bash
# tmp: boot all three images on OUR kernel (16K granule, console-test variant), which
# is the closest stand-in to the real target available. QEMU virt, -cpu max.
set -e
cp -a /mnt/e/Reverseing/Arlo/debian-ios/scripts/. /root/arlo/src/scripts/
find /root/arlo/src -name '*.sh' -exec sed -i 's/\r$//' {} +

NOTE="OUR kernel (hoolock, shipping config + PL011 only; CONFIG_ARM64_16K_PAGES=y), QEMU virt, -cpu max -- sha256 2697e77d901d44844cb8871400ee59119148be08182ccf57bbb6df9b766fde88"

for v in min dash debian; do
  echo "===== $v on OUR kernel ====="
  KERNEL_NOTE="$NOTE" LABEL=ourkernel CPU=max INPUT_DELAY=45 VARIANT=$v \
    KERNEL_DIR=/root/arlo/ourkernel \
    KERNEL_FILE=/root/arlo/ourkernel/Image-16k-qemu-pl011 \
    bash /root/arlo/src/scripts/smoke-test-qemu.sh
done

echo
echo "===== pagesize and identity as the guest reported them ====="
for v in min dash debian; do
  printf '%-8s %s | %s | %s\n' "$v" \
    "$(grep -m1 '^kernel ' /root/arlo/evidence/qemu-console-smoke-$v-ourkernel.log)" \
    "$(grep -m1 '^pagesize ' /root/arlo/evidence/qemu-console-smoke-$v-ourkernel.log)" \
    "$(grep -m1 'ARLO-INITRAMFS-SMOKE:' /root/arlo/evidence/qemu-console-smoke-$v-ourkernel.log)"
done
echo
sha256sum /root/arlo/evidence/*-ourkernel.log
stat -c '%s %n' /root/arlo/evidence/*-ourkernel.log
