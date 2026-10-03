#!/bin/bash
# debian-ios/scripts/fetch-inputs.sh
#
# Fetch the arm64 Debian packages that make up the RAM-backed initramfs, from the
# Debian archive's own signed-by-hash package index. Nothing here is installed:
# every .deb is downloaded into a cache and its SHA-256 is checked against the
# SHA256 field of the index stanza it was selected from.
#
# USAGE (inside a Linux VM/container):
#   fetch-inputs.sh --packages "busybox-static dash coreutils" [--cache DIR] [--pins FILE] [--print-only]
#
# EXIT: 0 = every requested package resolved, downloaded and hash-verified.
#       1 = hard failure (index unreachable, package missing, hash mismatch, pin drift).
#
# WHY THIS SHAPE: reproducibility needs a pinned, verifiable input set. The index
# gives us both the exact version and the digest, so a rebuild three months from
# now either reproduces byte-for-byte or fails loudly with the drift named.

set -euo pipefail

MIRROR=${MIRROR:-http://deb.debian.org/debian}
SUITE=${SUITE:-bookworm}
COMPONENT=${COMPONENT:-main}
ARCH=${ARCH:-arm64}
CACHE=${CACHE:-/root/arlo/cache}
PINS=${PINS:-}
PRINT_ONLY=0
NO_DEPS=0
MANIFEST_OVERRIDE=""
PACKAGES=""

while [ $# -gt 0 ]; do
  case "$1" in
    --packages) PACKAGES=$2; shift 2 ;;
    --cache)    CACHE=$2; shift 2 ;;
    --pins)     PINS=$2; shift 2 ;;
    --manifest) MANIFEST_OVERRIDE=$2; shift 2 ;;
    --print-only) PRINT_ONLY=1; shift ;;
    --no-deps)  NO_DEPS=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

[ -n "$PACKAGES" ] || { echo "ERROR: --packages is required" >&2; exit 1; }

mkdir -p "$CACHE"
INDEX_XZ="$CACHE/Packages-$SUITE-$ARCH.xz"
INDEX_TXT="$CACHE/Packages-$SUITE-$ARCH"
FLAT="$CACHE/packages-$SUITE-$ARCH.flat"
MANIFEST=${MANIFEST_OVERRIDE:-$CACHE/manifest-inputs.tsv}

# ---------------------------------------------------------------- index ----
if [ ! -s "$INDEX_TXT" ]; then
  echo "== fetching $MIRROR/dists/$SUITE/$COMPONENT/binary-$ARCH/Packages.xz"
  curl -fsSL -o "$INDEX_XZ.part" "$MIRROR/dists/$SUITE/$COMPONENT/binary-$ARCH/Packages.xz"
  mv "$INDEX_XZ.part" "$INDEX_XZ"
  xz -dc "$INDEX_XZ" > "$INDEX_TXT"
fi
INDEX_SHA=$(sha256sum "$INDEX_TXT" | cut -d' ' -f1)
echo "== index: $INDEX_TXT  sha256=$INDEX_SHA"

# Flatten the stanza format to one tab-separated line per package: a lookup table
# that is cheap to grep and easy to audit.
if [ ! -s "$FLAT" ] || [ "$FLAT" -ot "$INDEX_TXT" ]; then
  awk 'BEGIN{RS="";FS="\n"}
    {p="";v="";f="";s="";d="";pd="";
     for(i=1;i<=NF;i++){ L=$i;
       if      (L ~ /^Package: /)     p=substr(L,10);
       else if (L ~ /^Version: /)     v=substr(L,10);
       else if (L ~ /^Filename: /)    f=substr(L,11);
       else if (L ~ /^SHA256: /)      s=substr(L,9);
       else if (L ~ /^Depends: /)     d=substr(L,10);
       else if (L ~ /^Pre-Depends: /) pd=substr(L,13);
     }
     if(p!="") printf "%s\t%s\t%s\t%s\t%s\t%s\n", p,v,f,s,d,pd;
    }' "$INDEX_TXT" > "$FLAT.part"
  mv "$FLAT.part" "$FLAT"
fi
echo "== flattened index: $(wc -l < "$FLAT") packages"

field() { # field <package> <column>
  awk -F'\t' -v p="$1" -v n="$2" '$1==p {print $n; exit}' "$FLAT"
}

pin_for() { # pin_for <package> -> version or empty
  [ -n "$PINS" ] && [ -s "$PINS" ] || return 0
  awk -v p="$1" '!/^#/ && NF>=2 && $1==p {print $2; exit}' "$PINS"
}

# ------------------------------------------------------------- resolve ----
# Debian dependency resolution, deliberately minimal and honest:
#   * first alternative of each "a | b" group,
#   * Depends and Pre-Depends only (no Recommends/Suggests — a shell does not need them),
#   * :any / :arm64 qualifiers and "(>= x)" version constraints stripped,
#   * an unresolvable name is reported, not silently dropped.
declare -A WANT=()
declare -a ORDER=()
declare -a MISSING=()

resolve() {
  local pkg="$1"
  [ -n "${WANT[$pkg]:-}" ] && return 0
  WANT[$pkg]=1
  local ver
  ver=$(field "$pkg" 2)
  if [ -z "$ver" ]; then
    MISSING+=("$pkg")
    return 0
  fi
  ORDER+=("$pkg")
  # --no-deps: fetch exactly what was asked for. Used for the stand-in QEMU kernel,
  # whose Depends (kmod, linux-base, ...) are meaningless in an initramfs and would
  # drag in tens of megabytes to no purpose.
  if [ "$NO_DEPS" -eq 1 ]; then return 0; fi
  local deps
  deps=$(field "$pkg" 5)$'\n'$(field "$pkg" 6)
  local group item
  while IFS= read -r group; do
    item=$(printf '%s' "$group" | cut -d'|' -f1 | sed -e 's/([^)]*)//g' -e 's/:any//g' -e "s/:$ARCH//g" -e 's/[[:space:]]//g')
    [ -n "$item" ] || continue
    resolve "$item"
  done < <(printf '%s\n' "$deps" | tr ',' '\n')
}

for p in $PACKAGES; do resolve "$p"; done

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "ERROR: names not present in $SUITE/$COMPONENT/binary-$ARCH index: ${MISSING[*]}" >&2
  exit 1
fi

# ----------------------------------------------------------------- pins ----
PIN_DRIFT=0
for p in "${ORDER[@]}"; do
  pin=$(pin_for "$p")
  got=$(field "$p" 2)
  if [ -n "$pin" ] && [ "$pin" != "$got" ]; then
    echo "PIN DRIFT: $p pinned=$pin index=$got" >&2
    PIN_DRIFT=1
  fi
done
if [ "$PIN_DRIFT" -ne 0 ]; then
  echo "ERROR: the archive no longer offers the pinned versions. Refusing to build a" >&2
  echo "       different artefact than the one documented in pins/. Update pins/ and" >&2
  echo "       re-verify, or pin SUITE to a snapshot archive." >&2
  exit 1
fi

# -------------------------------------------------------------- fetch ----
: > "$MANIFEST.part"
TOTAL_BYTES=0
for p in "${ORDER[@]}"; do
  ver=$(field "$p" 2); fn=$(field "$p" 3); sha=$(field "$p" 4)
  base=$(basename "$fn")
  dest="$CACHE/$base"

  if [ -s "$dest" ] && [ "$(sha256sum "$dest" | cut -d' ' -f1)" = "$sha" ]; then
    echo "== cached    $p $ver"
  else
    echo "== download  $p $ver  <- $MIRROR/$fn"
    if [ "$PRINT_ONLY" -eq 1 ]; then
      echo "   (--print-only: not downloading)"
    else
      curl -fsSL -o "$dest.part" "$MIRROR/$fn"
      got=$(sha256sum "$dest.part" | cut -d' ' -f1)
      if [ "$got" != "$sha" ]; then
        echo "ERROR: SHA-256 mismatch for $base" >&2
        echo "  index says $sha" >&2
        echo "  got        $got" >&2
        rm -f "$dest.part"
        exit 1
      fi
      mv "$dest.part" "$dest"
    fi
  fi
  size=0
  [ -s "$dest" ] && size=$(stat -c %s "$dest")
  TOTAL_BYTES=$((TOTAL_BYTES + size))
  printf '%s\t%s\t%s\t%s\t%s\n' "$p" "$ver" "$base" "$sha" "$fn" >> "$MANIFEST.part"
done

mv "$MANIFEST.part" "$MANIFEST"
{
  echo "# debian-ios input manifest"
  echo "# mirror: $MIRROR  suite: $SUITE  component: $COMPONENT  arch: $ARCH"
  echo "# index sha256: $INDEX_SHA"
  echo "# fetched: (unset on purpose - a timestamp here would break reproducibility)"
  echo "# package	version	file	sha256	pool-path"
  cat "$MANIFEST"
} > "$MANIFEST.txt"

echo "== packages: ${#ORDER[@]}  .deb bytes total: $TOTAL_BYTES"
echo "== manifest: $MANIFEST"
cat "$MANIFEST"
