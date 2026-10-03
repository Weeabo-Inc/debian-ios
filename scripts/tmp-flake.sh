#!/bin/bash
# tmp: is the pre-/init stall deterministic or a flake? Repeat the two configurations
# that differed, 3 times each, and report per-run facts only.
set -u
Q=qemu-system-aarch64
K=/root/arlo/ourkernel/Image-16k-qemu-pl011
I=/root/arlo/dist/arlo-initramfs-min.cpio.gz
E=/root/arlo/evidence

one() { # one <label> <cmdline> <stdin: null|pipe> <timeout>
  local label="$1" cmd="$2" mode="$3" tmo="$4"
  local log="$E/flake-$label.log"
  : > "$log"
  if [ "$mode" = null ]; then
    timeout "$tmo" $Q -M virt -cpu max -m 1024 -smp 1 -kernel "$K" -initrd "$I" \
      -append "$cmd" -display none -monitor none -serial stdio -no-reboot \
      < /dev/null >> "$log" 2>&1
  else
    { sleep 5; printf 'echo PROBE-OK\n'; sleep 1; printf 'poweroff -f\n'; sleep 2; } \
      | timeout "$tmo" $Q -M virt -cpu max -m 1024 -smp 1 -kernel "$K" -initrd "$I" \
        -append "$cmd" -display none -monitor none -serial stdio -no-reboot >> "$log" 2>&1
  fi
  local rc=$? last
  last=$(grep -oE '^\[ *[0-9]+\.[0-9]+\] [^[]*' "$log" | tail -1 | cut -c1-74)
  printf '%-26s rc=%-4s init=%-2s prompt=%-2s down=%-2s last=[%s]\n' \
    "$label" "$rc" \
    "$(grep -c 'Run /init as init process' "$log")" \
    "$(grep -cE 'arlo:/#|arlo:\\\\w#' "$log")" \
    "$(grep -c 'reboot: Power down' "$log")" "$last"
}

for i in 1 2 3; do
  one "A-null-no-smoke-run$i" "console=ttyAMA0 rdinit=/init" null 60
done
for i in 1 2; do
  one "D-null-smoke-run$i"   "console=ttyAMA0 rdinit=/init arlo.smoke=1" null 60
done
for i in 1 2; do
  one "B-pipe-run$i"         "console=ttyAMA0 rdinit=/init" pipe 60
done
