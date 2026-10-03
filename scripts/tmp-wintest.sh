#!/bin/bash
# tmp: v3 test of check-loader-window.sh -- all paths, with the addresses checked
# against the .dts source rather than merely "it ran".
set -u
S=/root/arlo/src/scripts/check-loader-window.sh
cp -a /mnt/e/Reverseing/Arlo/debian-ios/scripts/. /root/arlo/src/scripts/
sed -i 's/\r$//' "$S"

echo "############ A. --dtb must print the address from the .dts, not a sum ############"
echo "source says (n69-loader-target.dts:1198-1199): 0x810000000 .. 0x81028c000 = 2670592"
GOT=$(bash "$S" --dtb /mnt/e/Reverseing/Arlo/a9linux/dts/n69-loader-target.dtb 2>/dev/null | head -1)
echo "script says: $GOT"
case "$GOT" in
  *"0x810000000 .. 0x81028c000 = 2670592 bytes"*) echo "PASS: address and size both match the source" ;;
  *) echo "FAIL: mismatch" ;;
esac

echo
echo "############ B. stderr must contain NO arithmetic noise ############"
bash "$S" --dtb /mnt/e/Reverseing/Arlo/a9linux/dts/n69-loader-target.dtb 2>/tmp/e.txt >/dev/null
echo "stderr lines: $(grep -c . /tmp/e.txt)  (1 = the intentional FAIL block only)"
grep -iE 'value too great|syntax error|invalid arithmetic|unbound' /tmp/e.txt && echo "FAIL: arithmetic noise" || echo "PASS: no arithmetic noise"

echo
echo "############ C. other DTBs with DIFFERENT windows (does it really decode?) ############"
for d in /mnt/e/Reverseing/Arlo/a9linux/qemu/dts/n69-qemu-stub.dtb \
         /mnt/e/Reverseing/Arlo/a9linux/qemu/dts/qemu-dumped-virt-patched.dtb; do
  printf '  %-34s %s\n' "$(basename "$d")" "$(bash "$S" --dtb "$d" 2>/dev/null | head -1)"
done
echo "  (cross-check with dtc directly:)"
dtc -I dtb -O dts /mnt/e/Reverseing/Arlo/a9linux/qemu/dts/n69-qemu-stub.dtb 2>/dev/null | grep -E 'linux,initrd-(start|end)'

echo
echo "############ D. default window still correct ############"
bash "$S" 2>/dev/null | head -1

echo
echo "############ E. --window override, proper exit codes ############"
bash "$S" --window 8000000 >/dev/null 2>&1; echo "  window=8000000 -> exit=$? (0 expected: all three fit)"
bash "$S" --window 5000000 >/dev/null 2>&1; echo "  window=5000000 -> exit=$? (1 expected: debian 7.48 MB does not fit)"

echo
echo "############ F. error paths ############"
bash "$S" --dtb /nonexistent.dtb >/dev/null 2>&1; echo "  nonexistent dtb      -> exit=$? (1 expected)"
bash "$S" --dtb /mnt/e/Reverseing/Arlo/a9linux/dts/ref/dts/s8003-n69.dtb >/dev/null 2>&1; echo "  dtb without initrd   -> exit=$? (1 expected)"
