#!/bin/bash
# tmp: isolate the interactive-run stall on OUR kernel.
#   A: same cmdline, stdin from /dev/null  -> does the guest reach userspace at all?
#   B: same cmdline, piped stdin, short delay -> reproduce the stall?
#   C: defconfig 16K kernel, piped stdin -> control (this combination is known good)
set -u
Q=qemu-system-aarch64
K=/root/arlo/ourkernel/Image-16k-qemu-pl011
K16=/root/arlo/kernel16k/dist/Image-16k-6.1.176
I=/root/arlo/dist/arlo-initramfs-min.cpio.gz
E=/root/arlo/evidence

run() { # run <name> <kernel> <cmdline> <stdin mode> <timeout>
  local name="$1" kern="$2" cmd="$3" mode="$4" tmo="$5" log="$E/probe-$1.log"
  : > "$log"
  echo "== $name  (stdin=$mode, timeout=${tmo}s)"
  if [ "$mode" = "null" ]; then
    timeout "$tmo" $Q -M virt -cpu max -m 1024 -smp 1 -kernel "$kern" -initrd "$I" \
      -append "$cmd" -display none -monitor none -serial stdio -no-reboot \
      < /dev/null >> "$log" 2>&1
  else
    { sleep 5; printf 'echo PROBE-OK\n'; sleep 1; printf 'echo PROBE-END\n'; sleep 1; printf 'poweroff -f\n'; sleep 2; } \
      | timeout "$tmo" $Q -M virt -cpu max -m 1024 -smp 1 -kernel "$kern" -initrd "$I" \
        -append "$cmd" -display none -monitor none -serial stdio -no-reboot >> "$log" 2>&1
  fi
  local rc=$?
  printf '   rc=%-4s Run/init=%-3s prompt=%-3s PROBE-OK=%-3s PowerDown=%-3s size=%s\n' \
    "$rc" \
    "$(grep -c 'Run /init as init process' "$log")" \
    "$(grep -cE 'arlo:/#|arlo:\\\\w#|arlo # ' "$log")" \
    "$(grep -c 'PROBE-OK' "$log")" \
    "$(grep -c 'reboot: Power down' "$log")" \
    "$(stat -c %s "$log")"
}

run A-null-stdin          "$K"  "console=ttyAMA0 rdinit=/init"            null  90
run B-piped-ourkernel     "$K"  "console=ttyAMA0 rdinit=/init"            pipe  90
run C-piped-defconfig     "$K16" "console=ttyAMA0 rdinit=/init"           pipe  90
run D-null-ourkernel-smoke "$K" "console=ttyAMA0 rdinit=/init arlo.smoke=1" null 90
echo
echo "== which consoles each probe registered =="
for f in "$E"/probe-*.log; do
  printf '%-34s %s\n' "$(basename "$f")" "$(grep -m1 'printk: console' "$f" || echo '(never enabled one)')"
done
