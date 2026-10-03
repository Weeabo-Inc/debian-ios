#!/bin/sh
# /usr/lib/arlo/inventory.sh -- print what this kernel and this board actually
# are, using only files that exist without any driver we do not have.
# Every line is tolerant: a missing file prints "absent" instead of failing,
# because an inventory that dies halfway is worse than one with holes in it.

say() { printf '%-12s %s\n' "$1" "$2"; }
read_or() { # read_or <file> [fallback]
  if [ -r "$1" ]; then tr -d '\0' < "$1" 2>/dev/null | head -c 400; else printf '%s' "${2:-absent}"; fi
}

echo "--- inventory -------------------------------------------------------"
say kernel  "$(uname -s 2>/dev/null) $(uname -r 2>/dev/null) $(uname -m 2>/dev/null)"
say cmdline "$(read_or /proc/cmdline absent)"
say machine "$(read_or /proc/device-tree/model) | $(read_or /proc/device-tree/compatible absent)"
say cpus    "$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo '?') x $(awk -F': ' '/^CPU part/{print $2; exit}' /proc/cpuinfo 2>/dev/null)"
say pagesize "$(awk '/^KernelPageSize:/{print $2" "$3; exit}' /proc/self/smaps 2>/dev/null || echo '?')"
say memory  "$(awk '/^MemTotal:/{print $2" kB total"; exit}' /proc/meminfo 2>/dev/null || echo '?')"
# /proc/consoles has NO header line -- an earlier `NR>1` filter skipped its only line
# and reported nothing while a console was perfectly well registered.
say consoles "$(awk '{printf "%s ", $1} END{print ""}' /proc/consoles 2>/dev/null | sed 's/ *$//')"

if [ -r /proc/fb ]; then
  FB=$(tr '\n' ';' < /proc/fb 2>/dev/null)
  if [ -n "$FB" ]; then say fb "$FB"; else say fb "none bound (/proc/fb is empty)"; fi
else
  say fb     "no /proc/fb (kernel has no framebuffer support)"
fi
[ -e /dev/fb0 ] && say fbdev "/dev/fb0 present" || say fbdev "/dev/fb0 absent"

if [ -d /sys/firmware/devicetree/base ]; then
  say dtb    "live device tree present at /sys/firmware/devicetree/base"
  # The node is usually unit-addressed (`memory@800000000`), so glob it: looking only
  # for `/memory` reported "loader did not fill it" on a machine whose memory WAS
  # filled, which is exactly the plausible-looking wrong value this project keeps
  # paying for.
  MEMNODE=$(ls -d /sys/firmware/devicetree/base/memory* 2>/dev/null | head -1)
  if [ -n "$MEMNODE" ]; then
    say memnode "$(basename "$MEMNODE") reg=$(od -An -v -tx1 -N16 "$MEMNODE/reg" 2>/dev/null | tr -s ' ' | sed 's/^ //')"
  else
    say memnode "no /memory node in the live device tree"
  fi
else
  say dtb    "no live device tree"
fi
say storage "$( (ls /dev/mmcblk* /dev/nvme* /dev/sd? 2>/dev/null || true) | tr '\n' ' ') (expected empty -- upstream A9 has no storage driver)"
say network "$(ls /sys/class/net 2>/dev/null | tr '\n' ' ') (expected: lo only -- no Wi-Fi/Ethernet driver upstream)"
echo "---------------------------------------------------------------------"
