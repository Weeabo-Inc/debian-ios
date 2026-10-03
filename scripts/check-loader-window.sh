#!/bin/bash
# debian-ios/scripts/check-loader-window.sh
#
# Guard against a silent cross-artefact defect: the device tree declares a window for
# the initramfs, and a kernel handed more bytes than the window was told about unpacks
# a TRUNCATED archive and then dies late with a misleading unpack/VFS error. That is a
# confusing failure on a device we get limited attempts at, so it gets checked here
# instead of being discovered on the phone.
#
# USAGE
#   check-loader-window.sh                       # use the window recorded below
#   check-loader-window.sh --dtb path/to.dtb     # read /chosen/linux,initrd-* from a DTB
#   check-loader-window.sh --window 4194304      # explicit byte budget
#
# Exit 0 = every artefact in DIST fits. Exit 1 = at least one does not.
#
# WINDOW RECORDED 2026-10-03 from a9linux/dts/n69-loader-target.dts lines 1198-1199
# (dt-engineer's file, read-only from here):
#     linux,initrd-start = <0x08 0x10000000>;   -> 0x810000000
#     linux,initrd-end   = <0x08 0x1028c000>;   -> 0x81028c000
#   = 2,670,592 bytes.
# FOR CONTEXT, because it explains the number: a9linux/artefacts/initramfs.gz, the
# stock Alpine netboot initramfs that happened to be in the tree, is 2,669,875 bytes --
# the window is 717 bytes larger than that file. It was sized to a file that is not
# ours, which is exactly why this check exists.

set -euo pipefail

DIST=${DIST:-/root/arlo/dist}
WINDOW=${WINDOW:-2670592}
DTB=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dtb)    DTB=$2; shift 2 ;;
    --window) WINDOW=$2; shift 2 ;;
    --dist)   DIST=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [ -n "$DTB" ]; then
  command -v dtc >/dev/null 2>&1 || { echo "ERROR: --dtb needs dtc (apt install device-tree-compiler)" >&2; exit 1; }
  [ -s "$DTB" ] || { echo "ERROR: no such DTB: $DTB" >&2; exit 1; }
  # A 64-bit address is TWO 32-bit cells here (address-cells = 2):
  #   <0x08 0x10000000>  ->  (0x08 << 32) | 0x10000000  ->  0x810000000
  # TWO earlier versions of this were wrong, and the second one was wrong QUIETLY:
  #   v1 concatenated the cells as TEXT ("0x08" + "0x10000000" = "0x080x10000000")
  #      and printed `value too great for base` on every --dtb run, then carried on
  #      with the compiled-in default. Found by qemu-validator, who ran the path I had
  #      never executed.
  #   v2 SUMMED the cells: 0x08 + 0x10000000 = 0x10000008. The window SIZE still came
  #      out right, because the high cell cancels in the subtraction -- so it printed a
  #      correct-looking 2,670,592 bytes beside a nonsense address. That is this
  #      project's documented recurring injury, which is why the addresses are printed
  #      and range-checked now, not just the size.
  cells_of() { # cells_of <dtb> <property> -> one hex cell per line
    dtc -I dtb -O dts "$1" 2>/dev/null \
      | grep -m1 "$2" \
      | grep -oE '0x[0-9a-fA-F]+'
  }
  value_of() { # value_of <dtb> <property> -> decimal on stdout, non-zero exit if absent
    local cells n
    cells=$(cells_of "$1" "$2")
    [ -n "$cells" ] || return 1
    n=$(printf '%s\n' "$cells" | wc -l)
    case "$n" in
      1) set -- $cells; echo $(( $1 )) ;;
      2) set -- $cells; echo $(( ($1 << 32) | $2 )) ;;
      *) echo "ERROR: $2 has $n cells; this script handles 1 or 2" >&2; return 1 ;;
    esac
  }
  START=$(value_of "$DTB" 'linux,initrd-start') || { echo "ERROR: cannot read /chosen/linux,initrd-start from $DTB" >&2; exit 1; }
  END=$(value_of "$DTB" 'linux,initrd-end')     || { echo "ERROR: cannot read /chosen/linux,initrd-end from $DTB" >&2; exit 1; }
  if [ "$END" -le "$START" ]; then
    echo "ERROR: initrd window is empty or inverted: start=0x$(printf '%x' "$START") end=0x$(printf '%x' "$END")" >&2
    exit 1
  fi
  WINDOW=$((END - START))
  echo "window read from $DTB: 0x$(printf '%x' "$START") .. 0x$(printf '%x' "$END") = $WINDOW bytes"
fi

echo "window: $WINDOW bytes"
echo
printf '%-34s %12s %10s %14s  %s\n' artefact bytes result slack sha256
RC=0
for f in "$DIST"/arlo-initramfs-*.cpio.gz "$DIST"/arlo-initramfs-*.cpio; do
  [ -s "$f" ] || continue
  SZ=$(stat -c %s "$f")
  SHA=$(sha256sum "$f" | cut -c1-16)
  if [ "$SZ" -le "$WINDOW" ]; then
    printf '%-34s %12s %10s %14s  %s\n' "$(basename "$f")" "$SZ" "FITS" "$((WINDOW - SZ))" "$SHA..."
  else
    printf '%-34s %12s %10s %14s  %s\n' "$(basename "$f")" "$SZ" "TRUNCATED" "$((WINDOW - SZ))" "$SHA..."
    RC=1
  fi
done

echo
echo "what the window would have to be, per variant (compressed, as a loader would carry it):"
for v in min dash debian; do
  f="$DIST/arlo-initramfs-$v.cpio.gz"
  [ -s "$f" ] || continue
  SZ=$(stat -c %s "$f")
  if [ "$SZ" -le "$WINDOW" ]; then
    echo "  $v: $SZ  -> fits today's $WINDOW-byte window"
  else
    echo "  $v: $SZ  -> window must grow to at least $SZ bytes (+$((SZ - WINDOW)) vs today)"
  fi
done

echo
if [ "$RC" -eq 0 ]; then
  echo "OK: every artefact fits the declared initrd window."
else
  echo "FAIL: at least one artefact is larger than the window the device tree declares." >&2
  echo "      The kernel would unpack a TRUNCATED initramfs and fail late and misleadingly." >&2
  echo "      Fix is on the loader/DTB side -- write end = start + actual size, or enlarge" >&2
  echo "      the window -- OR use a smaller variant that fits. Do not paper over it here." >&2
fi
exit "$RC"
