#!/bin/bash
# debian-ios/scripts/smoke-test-qemu.sh
#
# Boot the initramfs on QEMU's arm64 `virt` machine, capture the console, and
# decide pass/fail from the log -- not from an impression of the log.
#
# THE KERNEL IS A STAND-IN. It is a pinned Debian 6.1 arm64 kernel (4K pages), not
# the arlo A9 kernel and not a 16K-page kernel. What this proves is that the
# initramfs contents work: PID 1 runs from RAM, the static busybox shell starts, the
# Debian glibc binaries execute, /proc and devtmpfs come up, and the console is
# reachable. What it cannot prove about the phone is listed in
# debian-ios/CANNOT-PROVE.md.
#
# TWO RUNS, because they prove different things:
#   1. smoke mode  (arlo.smoke=1)  -- deterministic, no input, ends in poweroff.
#   2. interactive -- drives the console shell through /etc/inittab, proving the
#      respawn path and that commands typed at the console are executed.
set -euo pipefail

DIST=${DIST:-/root/arlo/dist}
EVID=${EVID:-/root/arlo/evidence}
KERNEL_DIR=${KERNEL_DIR:-/root/arlo/kernel-standin}
QEMU=${QEMU:-qemu-system-aarch64}
RAM_MB=${RAM_MB:-1024}
CPU=${CPU:-cortex-a57}
BOOT_TIMEOUT=${BOOT_TIMEOUT:-300}
VARIANT=${VARIANT:-debian}
INPUT_DELAY=${INPUT_DELAY:-30}
# LABEL distinguishes evidence from a second kernel (e.g. the 16K-parity run) without
# overwriting the primary logs.
LABEL=${LABEL:-}
SUFFIX="$VARIANT${LABEL:+-$LABEL}"

mkdir -p "$EVID"
VMLINUZ=${KERNEL_FILE:-$(ls "$KERNEL_DIR"/boot/vmlinuz-* 2>/dev/null | head -1)}
INITRD="$DIST/arlo-initramfs-$VARIANT.cpio.gz"
[ -n "$VMLINUZ" ] || { echo "ERROR: no stand-in kernel in $KERNEL_DIR -- run fetch-standin-kernel.sh" >&2; exit 1; }
[ -s "$INITRD" ]  || { echo "ERROR: no initramfs at $INITRD -- run build-initramfs.sh" >&2; exit 1; }

QEMU_VERSION=$("$QEMU" --version | head -1)
KERNEL_SHA=$(sha256sum "$VMLINUZ" | cut -d' ' -f1)
INITRD_SHA=$(sha256sum "$INITRD" | cut -d' ' -f1)
# The header must not assert a page size it was not told. An earlier revision
# hardcoded "4K pages" and then stamped it on a 16K-kernel run -- precisely the
# plausible-looking wrong value this project keeps paying for. Callers pass the
# provenance note explicitly; the default claims nothing.
KERNEL_NOTE=${KERNEL_NOTE:-"page size NOT asserted by this script -- see the STANDIN-KERNEL*.txt provenance"}

header() { # header <log> <mode> <append>
  {
    echo "###############################################################"
    echo "# arlo initramfs QEMU smoke test -- console capture"
    echo "#"
    echo "# KERNEL: STAND-IN, NOT OURS. $(basename "$VMLINUZ")"
    echo "#   $KERNEL_NOTE"
    echo "#   kernel sha256 : $KERNEL_SHA"
    echo "#   the A9 kernel (task-6) is 16K-page and cannot boot on QEMU 'virt'."
    echo "#   Nothing in this log is evidence about the iPhone."
    echo "#"
    echo "# INITRAMFS UNDER TEST: $(basename "$INITRD")"
    echo "#   sha256 : $INITRD_SHA"
    echo "#   size   : $(stat -c %s "$INITRD") bytes"
    echo "#"
    echo "# host   : $(uname -srm)  ($QEMU_VERSION)"
    echo "# machine: -M virt -cpu $CPU -m $RAM_MB -smp 1"
    echo "# append : $3"
    echo "# mode   : $2"
    echo "###############################################################"
  } >> "$1"
}

run_smoke() {
  local log="$EVID/qemu-console-smoke-$SUFFIX.log" append="console=ttyAMA0 rdinit=/init arlo.smoke=1"
  : > "$log"
  header "$log" "smoke (arlo.smoke=1, no input, powers off at the end)" "$append"
  echo "== run 1/2: smoke mode -> $log"
  set +e
  timeout "$BOOT_TIMEOUT" "$QEMU" \
      -M virt -cpu "$CPU" -m "$RAM_MB" -smp 1 \
      -kernel "$VMLINUZ" -initrd "$INITRD" \
      -append "$append" \
      -display none -monitor none -serial stdio -no-reboot \
      >> "$log" 2>&1
  local rc=$?
  set -e
  echo "# qemu exit status: $rc (0 = guest powered off cleanly)" >> "$log"
  if grep -q 'ARLO-INITRAMFS-SMOKE: PASS' "$log"; then
    echo "   PASS: found 'ARLO-INITRAMFS-SMOKE: PASS' in the console log"
    return 0
  fi
  echo "   FAIL: no PASS marker in $log" >&2
  tail -n 30 "$log" >&2
  return 1
}

run_interactive() {
  local log="$EVID/qemu-console-interactive-$SUFFIX.log" append="console=ttyAMA0 rdinit=/init"
  : > "$log"
  header "$log" "interactive (commands fed to the console shell through /etc/inittab)" "$append"
  echo "== run 2/2: interactive shell -> $log"
  # The script below is typed at the console, exactly as a person would. It ends by
  # powering off, so the run terminates by itself rather than by timeout.
  #
  # The sleeps are load-bearing, not decoration: QEMU hands stdin to the UART as
  # soon as it is read, and a guest that is still booting has nothing draining the
  # FIFO -- pipe the whole script in at once and the first commands are simply
  # dropped, which looks exactly like a dead console. Measured: feeding immediately
  # produced a shell prompt with no commands executed at all.
  set +e
  {
    sleep "$INPUT_DELAY"
    printf 'echo ARLO-INTERACTIVE-SHELL-OK\n';            sleep 0.5
    printf 'uname -a\n';                                  sleep 0.5
    printf 'echo "whoami=$(id -un 2>/dev/null) shell=$0 variant=$(cat /etc/arlo/VARIANT)"\n'; sleep 0.5
    printf 'ls -l /init /bin/sh /bin/busybox\n';          sleep 0.5
    printf 'echo "readlink /bin/sh -> $(readlink /bin/sh)"\n'; sleep 0.5
    printf 'echo "PATH resolution: sh=$(command -v sh) ls=$(command -v ls) cat=$(command -v cat)"\n'; sleep 0.5
    printf 'echo "shell=$0 ARLO_DEBIAN_SHELL=${ARLO_DEBIAN_SHELL:-unset}"\n'; sleep 0.5
    printf 'if [ -x /bin/dash ]; then /bin/dash -c "echo ARLO-DEBIAN-DASH-OK $((21*2))"; else echo ARLO-DEBIAN-DASH-ABSENT-in-min-variant; fi\n'; sleep 0.5
    printf '/bin/ls --version 2>/dev/null | head -n 1\n';  sleep 0.5
    printf '/usr/bin/dpkg --version 2>/dev/null | head -n 1\n'; sleep 0.5
    printf 'cat /proc/consoles\n';                        sleep 0.5
    printf 'cat /proc/version\n';                         sleep 0.5
    printf 'echo "tmpfs write: $(echo hi > /tmp/x && cat /tmp/x)"\n'; sleep 0.5
    printf 'echo ARLO-INTERACTIVE-END\n';                 sleep 0.5
    printf 'poweroff -f\n'
    sleep 2
  } | timeout "$BOOT_TIMEOUT" "$QEMU" \
      -M virt -cpu "$CPU" -m "$RAM_MB" -smp 1 \
      -kernel "$VMLINUZ" -initrd "$INITRD" \
      -append "$append" \
      -display none -monitor none -serial stdio -no-reboot \
      >> "$log" 2>&1
  local rc=$?
  set -e
  echo "# qemu exit status: $rc" >> "$log"
  local ok=0
  grep -q 'ARLO-INTERACTIVE-SHELL-OK' "$log" || { echo "   FAIL: shell did not execute the first command" >&2; ok=1; }
  grep -q 'ARLO-INTERACTIVE-END'      "$log" || { echo "   FAIL: the console script did not run to the end" >&2; ok=1; }
  grep -q 'whoami=root'               "$log" || { echo "   FAIL: id -un did not resolve to root (/etc/passwd problem)" >&2; ok=1; }
  if [ "$VARIANT" = "debian" ] || [ "$VARIANT" = "dash" ]; then
    grep -q 'ARLO-DEBIAN-DASH-OK 42'  "$log" || { echo "   FAIL: Debian dash did not run (glibc problem?)" >&2; ok=1; }
    grep -q 'ARLO_DEBIAN_SHELL=1'     "$log" || { echo "   FAIL: /etc/profile did not hand the console over to Debian dash" >&2; ok=1; }
  fi
  if [ "$VARIANT" = "debian" ]; then
    grep -q "Debian 'dpkg'"           "$log" || { echo "   FAIL: dpkg did not report itself" >&2; ok=1; }
    grep -q 'GNU coreutils)'          "$log" || { echo "   FAIL: the Debian coreutils binary did not run" >&2; ok=1; }
  fi
  if [ "$VARIANT" = "min" ]; then
    grep -q 'ARLO-DEBIAN-DASH-ABSENT-in-min-variant' "$log" || { echo "   FAIL: min variant did not report dash absence" >&2; ok=1; }
  fi
  [ "$ok" -eq 0 ] && echo "   PASS: console shell answered, ran the whole script, userland checks satisfied"
  [ "$ok" -eq 0 ] || tail -n 30 "$log" >&2
  return "$ok"
}

RC=0
run_smoke || RC=1
run_interactive || RC=1

echo
echo "== logs:"
for f in "$EVID"/*.log; do
  printf '   %-52s %8s bytes  sha256=%s\n' "$f" "$(stat -c %s "$f")" "$(sha256sum "$f" | cut -c1-16)"
done
exit "$RC"
