#!/bin/bash
# debian-ios/scripts/build-initramfs.sh
#
# Build the RAM-backed arm64 initramfs for the arlo A9 (iPhone SE 1st gen, n69ap)
# workstream. Runs INSIDE a Linux VM/container -- never over a 9p/drvfs mount
# (HANDOFF 9.3: no real hardlinks, broken symlink and permission semantics).
#
# USAGE (inside the VM):
#   build-initramfs.sh --variant both --out /root/arlo/dist \
#                      --cache /root/arlo/cache --work /root/arlo/work \
#                      --overlay <repo>/debian-ios/overlay --pins <repo>/debian-ios/pins/bookworm-arm64.pins
#
# VARIANTS
#   min     : static busybox only. Smallest thing that reaches a shell.
#   dash    : busybox + Debian dash + glibc. Smallest thing that is a real Debian
#             userland; fits the initrd window the DTB currently declares.
#   debian  : busybox + genuine Debian arm64 glibc binaries (dash, coreutils,
#             dpkg, sed, grep, tar, gzip) with their library closure.
#
# REPRODUCIBILITY CONTRACT
#   * every input .deb is pinned by version and verified against the SHA-256 in
#     the Debian index stanza it came from;
#   * every file in the image gets one fixed mtime (SOURCE_DATE_EPOCH), one
#     owner (0:0) and a sorted member order;
#   * cpio is written with --reproducible and gzip with -n (no name, no time);
#   * therefore two runs from the same inputs produce the same SHA-256. The
#     check-reproducible.sh script proves this rather than asserting it.

set -euo pipefail

VARIANT=both
OUT=/root/arlo/dist
CACHE=/root/arlo/cache
WORK=/root/arlo/work
OVERLAY=""
PINS=""
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1700000000}   # 2023-11-14T22:13:20Z, fixed on purpose
HERE=$(cd "$(dirname "$0")" && pwd)

while [ $# -gt 0 ]; do
  case "$1" in
    --variant) VARIANT=$2; shift 2 ;;
    --out)     OUT=$2; shift 2 ;;
    --cache)   CACHE=$2; shift 2 ;;
    --work)    WORK=$2; shift 2 ;;
    --overlay) OVERLAY=$2; shift 2 ;;
    --pins)    PINS=$2; shift 2 ;;
    --epoch)   SOURCE_DATE_EPOCH=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

[ -n "$OVERLAY" ] && [ -d "$OVERLAY" ] || { echo "ERROR: --overlay DIR is required and must exist" >&2; exit 1; }

# Package sets. busybox-static is FIRST in both lists on purpose: it is extracted
# first so that any later real Debian package overwrites an applet symlink rather
# than the other way round. Precedence must favour the real binary.
PKGS_MIN="busybox-static"
# dash: the smallest variant that is a REAL Debian userland (dynamic glibc shell)
# rather than only applets. It exists because the device tree currently declares a
# 2,670,592-byte initrd window (a9linux/dts/n69-loader-target.dts line 1198) that the
# full `debian` variant cannot fit into -- see scripts/check-loader-window.sh.
PKGS_DASH="busybox-static dash"
PKGS_DEBIAN="busybox-static dash coreutils dpkg sed grep tar gzip"

mkdir -p "$OUT" "$CACHE" "$WORK"

# Directories that are dead weight in an initramfs with a C-locale text console.
# Named explicitly, with the reason, rather than pruned by a clever pattern.
PRUNE_DIRS="
usr/share/doc
usr/share/man
usr/share/info
usr/share/lintian
usr/share/locale
usr/share/i18n
usr/share/gdb
usr/share/bash-completion
usr/share/gettext
var/cache
var/log
var/lib/apt
var/lib/dpkg/alternatives
"
# gconv is glibc's character-set conversion module set. UTF-8 and the internal
# wide/multibyte converters are built into libc; the modules only serve other
# charsets, and nothing in this image calls iconv. Pruned deliberately.
#
# BOTH path shapes are listed because these bookworm arm64 packages use the CLASSIC
# layout (/lib/..., not /usr/lib/...): a glob written only for `usr/lib/*` silently
# pruned nothing there, which is how 272 KB of libnss modules stayed in the first
# images while the build's own comments claimed otherwise.
PRUNE_GLOBS="usr/lib/*/gconv lib/*/gconv usr/lib/*/libnss_* lib/*/libnss_* usr/lib/*/security lib/*/security"

log() { echo "== $*"; }

# ------------------------------------------------------------- assemble ----
build_one() {
  local variant="$1" pkgs="$2"
  local rootfs="$WORK/rootfs-$variant"
  local cpiname="arlo-initramfs-$variant.cpio"
  local gzname="$cpiname.gz"

  log "variant=$variant : assembling $rootfs"
  rm -rf "$rootfs"
  mkdir -p "$rootfs"

  # 1. inputs (pinned + hash-verified).
  # The manifest name is per variant and per package-set hash. That is HYGIENE, not a
  # bug fix: fetch-inputs.sh writes `<manifest>.part` and renames it into place, so a
  # fixed shared path would be racy if two builds ever ran at once (the Lead or another
  # engineer can start one at any time).
  # It is NOT the explanation for anything you might notice about package counts: an
  # earlier version of this comment blamed a race for a 16-package `dash` closure. That
  # was wrong. Debian's dash genuinely Depends on dpkg (>= 1.19.1), and dpkg Pre-Depends
  # on tar, so the "small" Debian-shell variant really is those 16 packages. Check the
  # index before inventing a mechanism -- the data is in $CACHE/packages-$SUITE-$ARCH.flat.
  local setid mf
  setid=$(printf '%s' "$pkgs" | sha256sum | cut -c1-8)
  mf="$CACHE/manifest-$variant-$setid.tsv"
  if [ -n "$PINS" ]; then
    "$HERE/fetch-inputs.sh" --packages "$pkgs" --cache "$CACHE" --pins "$PINS" --manifest "$mf" >/dev/null
  else
    "$HERE/fetch-inputs.sh" --packages "$pkgs" --cache "$CACHE" --manifest "$mf" >/dev/null
  fi
  [ -s "$mf" ] || { echo "ERROR: no input manifest at $mf" >&2; exit 1; }

  # 2. unpack the .debs, in manifest order (= dependency order, busybox first)
  local pkg ver base sha pool desc
  local unpacked=0
  while IFS=$'\t' read -r pkg ver base sha pool desc; do
    case "$pkg" in \#*|"") continue ;; esac
    log "  unpack $pkg $ver"
    dpkg-deb -x "$CACHE/$base" "$rootfs"
    unpacked=$((unpacked + 1))
  done < "$mf"
  log "  $unpacked packages unpacked (manifest: $(basename "$mf"))"

  # 3. prune
  local d
  for d in $PRUNE_DIRS; do rm -rf "${rootfs:?}/$d"; done
  local g
  for g in $PRUNE_GLOBS; do rm -rf $rootfs/$g; done
  # empty /var/lib/dpkg/info would break `dpkg -l`; the .list files stay (small,
  # and they are what makes `dpkg -L` answer honestly).
  rm -f "$rootfs"/var/lib/dpkg/info/*.md5sums 2>/dev/null || true

  # 4. overlay (ours wins over anything the packages installed)
  cp -a "$OVERLAY/." "$rootfs/"

  # 5. the small set of things the overlay cannot know
  mkdir -p "$rootfs/dev" "$rootfs/proc" "$rootfs/sys" "$rootfs/tmp" "$rootfs/run" \
           "$rootfs/root" "$rootfs/etc/arlo" "$rootfs/var/lib/dpkg/info" "$rootfs/newroot"
  chmod 1777 "$rootfs/tmp"
  cp "$mf" "$rootfs/etc/arlo/manifest.tsv"
  echo "$variant" > "$rootfs/etc/arlo/VARIANT"
  {
    echo "arlo initramfs variant : $variant"
    echo "built by              : debian-ios/scripts/build-initramfs.sh"
    echo "inputs                : Debian arm64, pinned + SHA-256 verified (see manifest.tsv)"
    echo "mtime epoch           : $SOURCE_DATE_EPOCH (fixed so rebuilds are byte-identical)"
    echo "page size assumption  : none. User space here is granule-agnostic; it runs on a"
    echo "                        4K or a 16K kernel. The A9 kernel must still be built 16K."
  } > "$rootfs/etc/arlo/build-info.txt"

  # 6. a synthesized dpkg status database, so `dpkg -l` answers truthfully about
  #    what is actually in this image. It is generated from the index stanzas --
  #    dpkg itself never ran here, and the README says so.
  #    KEYED ON dpkg BEING PRESENT, not on the variant's name: the `dash` variant pulls
  #    dpkg in through dash's own Depends, and an image with dpkg and no database
  #    answers `dpkg -l` with nothing -- which its own self-test then correctly flags.
  if [ -x "$rootfs/usr/bin/dpkg" ]; then
    : > "$rootfs/var/lib/dpkg/status"
    while IFS=$'\t' read -r pkg ver base sha pool desc; do
      case "$pkg" in \#*|"") continue ;; esac
      {
        echo "Package: $pkg"
        echo "Status: install ok installed"
        echo "Priority: optional"
        echo "Architecture: arm64"
        echo "Version: $ver"
        echo "Maintainer: Debian archive (status synthesized by arlo debian-ios; dpkg never ran)"
        echo "Description: $desc"
        echo " Unpacked from the Debian $pool stanza, SHA-256 verified, for a RAM-backed"
        echo " initramfs. Documentation, man pages and locales were pruned; dpkg -l is"
        echo " meaningful, dpkg --verify is not."
        echo ""
      } >> "$rootfs/var/lib/dpkg/status"
    done < "$mf"
  fi

  # 7. Shell wiring. Debian's dash package owns /bin/sh. We deliberately take it
  #    back for the STATIC busybox: /bin/sh is what PID 1 and /etc/inittab run, and
  #    a broken dynamic userland must never be able to cost us the console. Debian's
  #    dash stays exactly where the package put it (/bin/dash) and the smoke test
  #    runs it explicitly -- so the log always says whether glibc works, without the
  #    boot depending on it.
  mkdir -p "$rootfs/sbin" "$rootfs/usr/sbin"
  rm -f "$rootfs/bin/sh"
  ln -s busybox "$rootfs/bin/sh"
  log "  /bin/sh -> busybox (static; Debian dash remains at /bin/dash)"
  if [ -x "$rootfs/usr/bin/dash" ] && [ ! -e "$rootfs/bin/dash" ]; then
    ln -s /usr/bin/dash "$rootfs/bin/dash"
  fi

  # 8. busybox applet farm. Debian's busybox-static ships ONLY /bin/busybox -- no
  #    applet symlinks at all -- so the classic names have to be created here or
  #    the min variant would have almost nothing but `busybox <applet>`.
  #    A name that already exists is never overwritten: in the debian variant the
  #    genuine Debian binary wins, which is exactly what a real Debian system with
  #    busybox installed does. The names come from the binary itself (run under
  #    qemu-user), so the farm cannot drift from the busybox in the image.
  local farm_source farm_count
  if [ -x "$rootfs/bin/busybox" ]; then
    local applets=""
    if command -v qemu-aarch64-static >/dev/null 2>&1; then
      applets=$(qemu-aarch64-static "$rootfs/bin/busybox" --list 2>/dev/null | LC_ALL=C sort || true)
      farm_source="busybox --list under qemu-aarch64-static (authoritative for this exact binary)"
    fi
    if [ -z "$applets" ]; then
      farm_source="curated fallback list (qemu-aarch64-static unavailable at build time)"
      applets=$(printf '%s\n' sh ash cat ls cp mv rm mkdir mount umount sleep poweroff reboot \
        sed grep awk head tail tr cut sort uniq wc date uname hostname readlink printf test \
        '[' dd sync mdev cttyhack init find tar chmod chown ln ps free vi df du clear tty stty \
        kill killall pidof yes true false env id whoami xargs expr basename dirname md5sum \
        sha256sum hexdump od diff cmp gzip gunzip zcat cpio mknod switch_root dmesg | LC_ALL=C sort)
    fi
    farm_count=0
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      [ "$a" = busybox ] && continue
      if [ -e "$rootfs/bin/$a" ] || [ -L "$rootfs/bin/$a" ]; then continue; fi
      ln -s busybox "$rootfs/bin/$a"
      farm_count=$((farm_count + 1))
    done <<EOF
$applets
EOF
    log "  applet farm: $farm_count symlinks ($farm_source)"
    {
      echo "applet farm           : $farm_count symlinks in /bin, from $farm_source"
      echo "clean console shell   : /bin/sh -> busybox (static, always present)"
      echo "debian shell          : /usr/bin/dash (dynamic glibc) + /bin/dash symlink"
    } >> "$rootfs/etc/arlo/build-info.txt"
  else
    echo "ERROR: /bin/busybox missing after extraction" >&2
    exit 1
  fi

  # 9. normalize: one owner, one mtime, executable bits on the scripts
  chown -R 0:0 "$rootfs"
  chmod 0755 "$rootfs/init"
  find "$rootfs" -name '*.sh' -type f -exec chmod 0755 {} +
  if [ -f "$rootfs/etc/init.d/rcS" ]; then chmod 0755 "$rootfs/etc/init.d/rcS"; fi
  find "$rootfs" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

  # 10. pack: sorted member order, no device/inode noise, no gzip timestamp
  log "  packing $cpiname"
  ( cd "$rootfs" && find . -mindepth 1 -printf '%P\0' \
      | LC_ALL=C sort -z \
      | cpio --null -o --format=newc --reproducible --owner=0:0 --quiet ) > "$OUT/$cpiname"
  gzip -9n -c "$OUT/$cpiname" > "$OUT/$gzname"

  local ucs gcs usize
  ucs=$(stat -c %s "$OUT/$cpiname")
  gcs=$(stat -c %s "$OUT/$gzname")
  usize=$(du -sb --apparent-size "$rootfs" | cut -f1)
  echo "$(sha256sum "$OUT/$gzname" | cut -d' ' -f1)  $gzname" > "$OUT/$gzname.sha256"
  echo "$(sha256sum "$OUT/$cpiname" | cut -d' ' -f1)  $cpiname" >> "$OUT/$gzname.sha256"

  printf '%-28s rootfs=%-10s cpio=%-10s gz=%-10s sha256(gz)=%s\n' \
    "$gzname" "$usize" "$ucs" "$gcs" "$(cut -d' ' -f1 < "$OUT/$gzname.sha256")"
  echo "$(cut -d' ' -f1 < "$OUT/$gzname.sha256")" > "$OUT/$gzname.sha256.only"
}

case "$VARIANT" in
  min)    build_one min    "$PKGS_MIN" ;;
  dash)   build_one dash   "$PKGS_DASH" ;;
  debian) build_one debian "$PKGS_DEBIAN" ;;
  both)   build_one min    "$PKGS_MIN"; build_one debian "$PKGS_DEBIAN" ;;
  all)    build_one min    "$PKGS_MIN"; build_one dash "$PKGS_DASH"; build_one debian "$PKGS_DEBIAN" ;;
  *) echo "ERROR: --variant must be min|dash|debian|both|all" >&2; exit 1 ;;
esac

log "done. artefacts in $OUT"
