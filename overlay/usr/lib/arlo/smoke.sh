#!/bin/sh
# /usr/lib/arlo/smoke.sh -- the initramfs self-test.
#
# This is what produces the QEMU evidence log. It must be deterministic and must
# need no input, no clock, no storage and no network: it is the same script that
# would run on the phone with `arlo.smoke=1` on the command line.
#
# It prints PASS/FAIL per requirement and exits non-zero if any hard requirement
# fails, so the caller (and the log reader) never has to interpret a wall of text.

FAIL=0
VARIANT=$(cat /etc/arlo/VARIANT 2>/dev/null || echo unknown)
ok()  { echo "  [ ok ] $*"; }
bad() { echo "  [FAIL] $*"; FAIL=$((FAIL + 1)); }
skip(){ echo "  [ -- ] $*"; }

echo ""
echo "=================== arlo initramfs smoke test ======================="
echo "marker: ARLO-INITRAMFS-SMOKE-BEGIN"
echo "init  : PID $$ running /usr/lib/arlo/smoke.sh"
echo ""

echo "--- 1. pseudo-filesystems and console ---"
if [ -r /proc/version ]; then ok "/proc mounted: $(cat /proc/version)"; else bad "/proc not readable"; fi
if [ -d /sys/class ]; then ok "/sys mounted"; else bad "/sys not mounted"; fi
if [ -c /dev/console ]; then ok "/dev/console is a character device"; else bad "/dev/console missing"; fi
if [ -w /tmp ]; then
  if echo arlo > /tmp/.arlo-write-test 2>/dev/null && [ "$(cat /tmp/.arlo-write-test)" = arlo ]; then
    ok "RAM-backed /tmp is writable and readable"; rm -f /tmp/.arlo-write-test
  else
    bad "/tmp is not writable"
  fi
else
  bad "/tmp is not writable"
fi

echo ""
echo "--- 2. the shell itself ---"
ARITH=$(sh -c 'echo $((6 * 7))' 2>/dev/null)
if [ "$ARITH" = "42" ]; then ok "sh executed arithmetic: 6*7=$ARITH"; else bad "sh arithmetic broken (got '$ARITH')"; fi
if [ -x /bin/busybox ]; then
  ok "static busybox: $(/bin/busybox 2>&1 | head -1)"
else
  bad "/bin/busybox missing -- the init interpreter must always be present"
fi
if [ -x /bin/dash ]; then
  D=$(/bin/dash -c 'echo $((21 * 2))' 2>/dev/null)
  if [ "$D" = "42" ]; then ok "Debian dash (dynamic, glibc) executed: 21*2=$D"; else bad "Debian dash failed to run (got '$D')"; fi
else
  skip "no /bin/dash in this variant"
fi

echo ""
echo "--- 3. the Debian userland, if this variant carries one ---"
# NOTE ON PATHS: Debian's coreutils/dash/grep/sed/tar packages in bookworm install to
# the CLASSIC paths (/bin/ls, not /usr/bin/ls) -- verified against the packages, and
# an earlier version of this script got it wrong and reported "no coreutils" while
# coreutils was running fine. Each check therefore resolves the tool first and only
# then looks at what it says it is.
tool_check() { # tool_check <absolute path> <substring that only the Debian tool prints>
  local p="$1" want="$2" out
  if [ ! -x "$p" ]; then skip "$p: not in this variant"; return 0; fi
  out=$("$p" --version 2>&1 | head -1)
  if printf '%s' "$out" | grep -q "$want"; then
    ok "$(basename "$p") at $p -> $out"
  elif [ "$VARIANT" = "debian" ]; then
    bad "$p is not the pinned Debian tool (expected *$want*): '$out'"
  else
    ok "$p -> busybox applet: $out"
  fi
}
mf_version() { awk -F'\t' -v p="$1" '$1==p {print $2; exit}' /etc/arlo/manifest.tsv 2>/dev/null; }
# The manifest carries Debian's version (coreutils "9.1-1", tar "1.34+dfsg-1.2+deb12u1")
# while the tool prints its upstream version ("9.1", "1.34"). Reduce one to the other
# instead of hardcoding a number here that would silently rot when the pins move.
upstream_version() { local v="${1%%+*}"; printf '%s' "${v%%-*}"; }
# These are called BY ABSOLUTE PATH, and that is not cosmetic. Debian's busybox is
# built with standalone-shell support: inside a busybox ash, the name `ls` resolves
# to the built-in APPLET and the real /bin/ls is never consulted. Measured, not
# assumed -- `command -v ls` in that shell answers "ls", and `ls --version` prints
# busybox usage. The expected strings carry the pinned version, so this also proves
# the running binary is the one the pins file names.
tool_check /bin/ls   "GNU coreutils) $(upstream_version "$(mf_version coreutils)")"
tool_check /bin/sed  "GNU sed) $(upstream_version "$(mf_version sed)")"
tool_check /bin/grep "GNU grep) $(upstream_version "$(mf_version grep)")"
tool_check /bin/tar  "GNU tar) $(upstream_version "$(mf_version tar)")"
if [ -x /bin/dash ]; then
  D=$(/bin/dash -c 'echo $((21 * 2))' 2>/dev/null)
  if [ "$D" = "42" ]; then ok "/bin/dash (Debian, dynamic glibc) ran arithmetic: 21*2=$D"; else bad "/bin/dash failed to run (got '$D')"; fi
else
  skip "no /bin/dash in this variant"
fi
if [ "$(command -v ls 2>/dev/null)" = "ls" ]; then
  echo "  [note] this shell is busybox ash with standalone-applet support: typing 'ls',"
  echo "         'sed', 'grep' or 'tar' here runs the BUSYBOX applet, not the Debian"
  echo "         binary. The Debian tools above ran because they were called by path;"
  echo "         /etc/profile hands over to /bin/dash, where bare names are Debian's."
fi
if [ -x /usr/bin/dpkg ]; then
  ok "dpkg: $(/usr/bin/dpkg --version 2>&1 | head -1)"
  echo "  installed packages as dpkg sees them:"
  /usr/bin/dpkg -l 2>/dev/null | sed -n '6,40p' | sed 's/^/    /'
  N=$(/usr/bin/dpkg -l 2>/dev/null | grep -c '^ii' || true)
  if [ "${N:-0}" -ge 8 ]; then ok "dpkg database lists $N installed packages"; else bad "dpkg database lists only ${N:-0} packages"; fi
else
  skip "no dpkg in this variant"
fi
echo "  user database: $(id -un 2>/dev/null || echo '?') (uid $(id -u 2>/dev/null || echo '?'))"
if [ "$(id -un 2>/dev/null)" = "root" ]; then ok "num->name resolution works (/etc/passwd is present)"; else bad "id -un did not resolve to root -- /etc/passwd missing?"; fi

echo ""
echo "--- 4. what this kernel and board are ---"
/usr/lib/arlo/inventory.sh

echo ""
echo "--- 5. honest capability statement ---"
cat /etc/arlo/CAPABILITY.txt 2>/dev/null || echo "  (CAPABILITY.txt missing)"
echo ""

echo "--- 6. summary ---"
if [ "$FAIL" -eq 0 ]; then
  echo "ARLO-INITRAMFS-SMOKE: PASS (0 failures)"
  echo "marker: ARLO-INITRAMFS-SMOKE-END"
  echo "====================================================================="
  exit 0
else
  echo "ARLO-INITRAMFS-SMOKE: FAIL ($FAIL failing requirement(s))"
  echo "marker: ARLO-INITRAMFS-SMOKE-END"
  echo "====================================================================="
  exit 1
fi
