#!/bin/bash
# tmp: how long does OUR kernel take to reach userspace under TCG? Measure, then size
# the interactive test's pacing from the measurement instead of from a guess.
set -u
L=/root/arlo/evidence/qemu-console-smoke-min-ourkernel.log
echo "=== milestones in the our-kernel smoke log ==="
grep -nE 'Freeing unused kernel memory|Run /init|ARLO-INITRAMFS-SMOKE: PASS|Power down|Kernel command line|Machine model' "$L" | head -10
echo
echo "=== last 5 timestamped kernel lines (latest boot progress) ==="
grep -oE '^\[ *[0-9]+\.[0-9]+\]' "$L" | tail -3
echo
echo "=== wall-clock duration actually used by each run (from the log headers/qemu lines) ==="
for f in /root/arlo/evidence/qemu-console-smoke-min-ourkernel.log /root/arlo/evidence/qemu-console-interactive-min-ourkernel.log; do
  echo "-- $(basename "$f")  size=$(stat -c %s "$f")"
  tail -3 "$f" | sed 's/^/     /'
done
