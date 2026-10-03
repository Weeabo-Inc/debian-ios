# debian-ios — the RAM-backed Debian arm64 initramfs

For the arlo workstream: mainline Linux on an iPhone SE 1st gen (Apple A9 `s8003`,
board `n69ap`), with a Debian userland on top.

**What this is.** A reproducible recipe that builds an arm64 initramfs which a kernel
boots from RAM to a working shell, the built images, and a QEMU smoke test that proves
they reach that shell. This is the project's first real milestone: a console with a
shell.

**What this is not.** A usable computer. Upstream A9 support has **no storage, no USB
host, no PMIC and no Wi-Fi driver** (HANDOFF §4), so nothing persists, nothing can be
installed, and there is no network. The kernel we actually need (16K pages, Apple
platform, task-6) does not exist yet; every boot below used a **stand-in kernel**, and
[`CANNOT-PROVE.md`](CANNOT-PROVE.md) lists exactly what that does and does not
establish. Read it before quoting any result here as evidence about the phone.

**Read §5.2 before planning a device attempt.** The device tree currently declares a
2,670,592-byte window for the initramfs and only the `min` variant fits inside it.

---

## 1. Contents

| Path | What |
|---|---|
| `scripts/fetch-inputs.sh` | resolve + download + SHA-256-verify the pinned Debian arm64 packages |
| `scripts/build-initramfs.sh` | assemble a rootfs, prune, overlay, pack reproducibly (`--variant min\|dash\|debian\|both\|all`) |
| `scripts/check-reproducible.sh` | build twice, prove byte-identical artefacts |
| `scripts/check-loader-window.sh` | assert every artefact fits the initrd window the DTB declares |
| `scripts/fetch-standin-kernel.sh` | pull **only vmlinuz** out of the pinned Debian stand-in kernel |
| `scripts/build-16k-standin-kernel.sh` | build a minimal **16K-page** kernel, to test the A9 granule |
| `scripts/smoke-test-qemu.sh` | boot in QEMU, capture the console, decide pass/fail from the log |
| `scripts/run-in-vm.ps1` | host glue: sync the recipe into the VM's ext4, run it, copy artefacts out |
| `pins/bookworm-arm64.pins` | the version lock (22 packages + the stand-in kernel) |
| `overlay/` | `/init`, `/etc/inittab`, `rcS`, `profile`, `motd`, the inventory + smoke scripts, `CAPABILITY.txt` |
| `dist/` | built artefacts, input manifests, stand-in kernels |
| `evidence/` | captured QEMU console logs + stand-in kernel provenance |
| `SHA256SUMS` | hashes of every artefact and log (`sha256sum -c SHA256SUMS`) |

## 2. The artefacts (MEASURED)

| Variant | File | Bytes | SHA-256 |
|---|---|---|---|
| **min** — fits today's window | `dist/arlo-initramfs-min.cpio.gz` | 997,191 | `c8b2dbb4a10c6510fab492c9b2eebc452fa4b2c5270f30b69710cad7c4ec2608` |
| dash — smallest Debian userland | `dist/arlo-initramfs-dash.cpio.gz` | 4,015,918 | `9eb1964db74b50d66bc0ab296238dbc76b743752a2fbef51e955d89c6365239f` |
| debian — fullest userland | `dist/arlo-initramfs-debian.cpio.gz` | 7,478,005 | `0dae863c10bddd615a5a026ecb8bbc9768296a216b895e3f47e226cd6eb0c9dd` |
| min, uncompressed | `dist/arlo-initramfs-min.cpio` | 1,906,688 | `51911627ac6d15ae7f36c580eec4427629853016b4690f7d8ce9eb54acdd6fa2` |
| dash, uncompressed | `dist/arlo-initramfs-dash.cpio` | 9,805,312 | `ec9bbb120af701e0b8bfecb0c80f8c149ebeb38f33319ad139b051e11a760a18` |
| debian, uncompressed | `dist/arlo-initramfs-debian.cpio` | 20,251,648 | `800e48f88ee76a8fde53b4d73a6b04b8937c700d9d5d5ec05f9e91272a51758c` |

* **min** — static busybox only (1 package, 1,868,032 bytes of rootfs). The smallest
  thing that reaches a shell, and the **only variant that fits the initrd window the
  device tree currently declares** (§5.2).
* **dash** — busybox + Debian dash + glibc (16 packages, 9,752,106 bytes of rootfs).
  The smallest variant that is a *real Debian userland* rather than applets only.
  It is 16 packages and not 2 because **Debian's `dash` Depends on `dpkg (>= 1.19.1)`,
  and `dpkg` Pre-Depends on `tar`** — read from the index, not assumed. A "minimal
  Debian shell" is inherently ~4 MB compressed; shipping dash without its declared
  dependencies would be an unsupported configuration, so we do not.
* **debian** — dash, coreutils, dpkg, sed, grep, tar, gzip and their closure
  (22 packages, 20,186,049 bytes of rootfs). Static busybox remains the boot shell.
* All three ship gzipped *and* uncompressed: gzip is what the kernel is configured for
  (`CONFIG_RD_GZIP=y`, §8), and the raw `.cpio` is the fallback if that ever changes.
* Stand-in kernels live in `dist/standin-kernels/` (`vmlinuz` is fetched on demand; the
  16K kernel is kept because nothing else in this project can currently produce one).

## 3. Reproduce it

Prerequisites inside a Linux VM — never over a 9p/drvfs mount (HANDOFF §9.3):
`bash curl xz-utils cpio gzip dpkg make qemu-system-arm qemu-user-static`.
`qemu-user-static` is a build-time input for one reason: it runs the arm64 busybox to
enumerate its applets, so the applet farm cannot drift from the binary in the image.

```powershell
# from E:\Reverseing\Arlo        (host side: thin glue only)
pwsh -File debian-ios/scripts/run-in-vm.ps1 -Action build       # -> dist/
pwsh -File debian-ios/scripts/run-in-vm.ps1 -Action reproduce   # proves the recipe
pwsh -File debian-ios/scripts/run-in-vm.ps1 -Action smoke       # QEMU, stand-in kernel
```

If the host's execution policy blocks `.ps1` files (it does on this machine by
default), run the same script through a bypass instead of changing machine policy:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File debian-ios/scripts/run-in-vm.ps1 -Action build
```

The VM-side commands those wrap, verbatim:

```bash
scripts/fetch-inputs.sh --packages "busybox-static dash coreutils dpkg sed grep tar gzip" \
    --cache /root/arlo/cache --pins pins/bookworm-arm64.pins
scripts/build-initramfs.sh --variant all --out dist --cache /root/arlo/cache \
    --work /root/arlo/work --overlay overlay --pins pins/bookworm-arm64.pins
scripts/check-reproducible.sh
scripts/check-loader-window.sh
```

**Reproducibility is measured, not asserted.** `check-reproducible.sh` builds every
variant twice into independent work and output trees and compares both the compressed
and the uncompressed archive. Last run, all six artefacts:

```
arlo-initramfs-min.cpio.gz         IDENTICAL  c8b2dbb4a10c6510fab492c9b2eebc45...
arlo-initramfs-min.cpio            IDENTICAL  51911627ac6d15ae7f36c580eec442762...
arlo-initramfs-dash.cpio.gz        IDENTICAL  9eb1964db74b50d66bc0ab296238dbc7...
arlo-initramfs-dash.cpio           IDENTICAL  ec9bbb120af701e0b8bfecb0c80f8c14...
arlo-initramfs-debian.cpio.gz      IDENTICAL  0dae863c10bddd615a5a026ecb8bbc97...
arlo-initramfs-debian.cpio         IDENTICAL  800e48f88ee76a8fde53b4d73a6b04b8...
REPRODUCIBLE: two independent builds produced byte-identical artefacts.
```

What makes it deterministic: every `.deb` is pinned by version *and* verified against
the SHA-256 in the Debian index stanza it came from; `fetch-inputs.sh` **fails on pin
drift** instead of silently building something else; every file gets one fixed mtime
(`SOURCE_DATE_EPOCH`), one owner (`0:0`), a sorted member order, `cpio --reproducible`
and `gzip -n`.

## 4. Proof it boots

Six boot configurations, two runs each. Pass/fail is decided by marker strings in the
captured log, not by reading it and forming an impression.

| Kernel | Variant | smoke (`arlo.smoke=1`) | interactive | Log |
|---|---|---|---|---|
| Debian 6.1.0-50, **4K** | min | `PASS (0 failures)` | PASS | `evidence/qemu-console-{smoke,interactive}-min.log` |
| Debian 6.1.0-50, **4K** | dash | `PASS (0 failures)` | PASS | `evidence/qemu-console-{smoke,interactive}-dash.log` |
| Debian 6.1.0-50, **4K** | debian | `PASS (0 failures)` | PASS | `evidence/qemu-console-{smoke,interactive}-debian.log` |
| defconfig 6.1.176, **16K** | min | `PASS (0 failures)` | PASS | `evidence/qemu-console-{smoke,interactive}-min-16k.log` |
| defconfig 6.1.176, **16K** | dash | `PASS (0 failures)` | PASS | `evidence/qemu-console-{smoke,interactive}-dash-16k.log` |
| defconfig 6.1.176, **16K** | debian | `PASS (0 failures)` | PASS | `evidence/qemu-console-{smoke,interactive}-debian-16k.log` |

Invocation, recorded in the header of every log:

```
qemu-system-aarch64 -M virt -cpu cortex-a57 -m 1024 -smp 1 \
  -kernel <stand-in vmlinuz> -initrd dist/arlo-initramfs-debian.cpio.gz \
  -append "console=ttyAMA0 rdinit=/init arlo.smoke=1" \
  -display none -monitor none -serial stdio -no-reboot
```

**Both kernels are STAND-INS, not ours.** The A9 kernel is 16K-page and Apple-platform;
it cannot boot on QEMU's `virt` machine at all, and task-6 is still building it.

* **4K stand-in**: pinned Debian `linux-image-6.1.0-50-arm64`, `vmlinuz` 32,956,352 B,
  `Linux kernel ARM64 boot executable Image`, 4K pages — `evidence/STANDIN-KERNEL.txt`.
* **16K stand-in**: Linux 6.1.176 arm64 `defconfig` built by
  `scripts/build-16k-standin-kernel.sh` with `CONFIG_ARM64_16K_PAGES=y` and
  `CONFIG_ARM64_4K_PAGES` unset, `-cpu max` (Cortex-A57 cannot do 16K), 32,381,440 B —
  `evidence/STANDIN-KERNEL-16K.txt`.

The 16K runs exist because "user space is granule-agnostic" is the load-bearing
assumption for A9 and deserved a measurement rather than an inference. Result: all three
images reach a shell and report **`pagesize 16 kB`**, matching the A9 granule. It removes
one real risk (see `CANNOT-PROVE.md`); it does not make the kernel ours.

Console excerpt — debian variant, 4K, smoke run (MEASURED):

```
--- 4. what this kernel and board are ---
kernel       Linux 6.1.0-50-arm64 aarch64
machine      linux,dummy-virt | linux,dummy-virt
cpus         1 x 0xd07
pagesize     4 kB
memory       1000964 kB total
consoles     ttyAMA0
fb           none bound (/proc/fb is empty)
fbdev        /dev/fb0 absent
dtb          live device tree present at /sys/firmware/devicetree/base
memnode      memory@40000000 reg=00 00 00 00 40 00 00 00 00 00 00 00 40 00 00 00
storage       (expected empty -- upstream A9 has no storage driver)
network      lo  (expected: lo only -- no Wi-Fi/Ethernet driver upstream)
--- 6. summary ---
ARLO-INITRAMFS-SMOKE: PASS (0 failures)
```

Interactive run, same image (MEASURED; the console shell at the prompt is Debian dash,
handed over by `/etc/profile` as described in §7):

```
arlo:\w# echo "whoami=$(id -un) shell=$0 variant=$(cat /etc/arlo/VARIANT)"
whoami=root shell=/bin/dash variant=debian
arlo:\w# echo "PATH resolution: sh=$(command -v sh) ls=$(command -v ls)"
PATH resolution: sh=/bin/sh ls=/bin/ls
arlo:\w# echo "ARLO-DEBIAN-DASH-OK $((21*2))"
ARLO-DEBIAN-DASH-OK 42
ls (GNU coreutils) 9.1
Debian 'dpkg' package management program version 1.21.23 (arm64).
```

## 5. Size, and the two budgets it has to satisfy

### 5.1 DRAM budget

A9 is a 16K-page part and the loader has to place all of this in DRAM at once:

| Item | Bytes | Basis |
|---|---|---|
| Kernel `Image` | ~33,000,000 | **MEASURED** for both stand-ins (32,381,440 / 32,956,352); **INFERRED** for ours — task-6 owns the real number |
| Device tree `s8003-n69.dtb` | 22,880–23,061 | **INSPECTED** — HANDOFF §5 (22,880) and dt-engineer's `n69-loader-target.dtb` (23,061) |
| **This initramfs (debian, gzipped)** | **7,478,005** | **MEASURED** |
| This initramfs (min, gzipped) | 997,191 | **MEASURED** |
| Framebuffer 640×1136×32bpp | 2,908,160 | **INSPECTED** — HANDOFF §4 panel size |
| Loader trampoline + page tables | ~1,000,000 | **INFERRED**, order of magnitude |
| **Total, debian variant** | **≈ 44,409,000 (42.4 MiB)** | sum; min variant ≈ 37,901,000 (36.1 MiB) |

* DRAM assumed: **2 GiB** (**INFERRED** — iPhone SE 1st gen has 2 GB; the authoritative
  figure is whatever the loader writes into `/memory`, HANDOFF §8.11).
* The whole boot payload is **~2.1% of 2 GiB**, or **~4.1% of a deliberately
  pessimistic 1 GiB**. The initramfs alone is 0.35% of 2 GiB (0.046% for min).
* **Size is not the DRAM constraint at this rung** — there is ~25× headroom. The
  constraint is drivers, and (see below) one address window.

### 5.2 The initrd window — read this before planning a device attempt

The device tree does not just say "there is an initramfs", it declares **where**:
`a9linux/dts/n69-loader-target.dts` lines 1198–1199 (dt-engineer's file, read-only from
here):

```
linux,initrd-start = <0x08 0x10000000>;   -> 0x810000000
linux,initrd-end   = <0x08 0x1028c000>;   -> 0x81028c000   = 2,670,592 bytes
```

Measured against our artefacts (`scripts/check-loader-window.sh`):

| Variant | Bytes | vs the 2,670,592-byte window |
|---|---|---|
| min | 997,191 | **fits**, 1,673,401 to spare |
| dash | 4,015,918 | needs a window ≥ 4,015,918 (+1,345,326) |
| debian | 7,478,005 | needs a window ≥ 7,478,005 (+4,807,413) |

If the loader places the debian image at `0x810000000` and the kernel is told the
initramfs ends at `0x81028c000`, it unpacks a **truncated** archive and then dies late
with a misleading unpack/VFS error. That is a bad failure to meet on a device we get
limited attempts at, so it is checked mechanically rather than remembered.

For context on where the number came from: `a9linux/artefacts/initramfs.gz` — the stock
Alpine netboot initramfs that happened to be in the tree — is 2,669,875 bytes. The
window is 717 bytes larger than **that** file. It was sized to an image that is not ours.

The fix belongs on the loader/DTB side: write `end = start + actual size` (these
placeholders are loader-filled by definition, HANDOFF §8.11), or enlarge the window to
at least the variant in use. `min` is the safe choice for a first attempt; the window
must grow before any Debian userland can ride in it.

## 6. What is inside

Common to all variants:

* `/init` — PID 1: mounts `proc`, `sysfs`, `devtmpfs` (and creates `/dev/console` by
  hand if devtmpfs is unavailable), then either runs the self-test or `exec`s busybox
  `init` through `/etc/inittab`.
* `/etc/inittab` — `::respawn:-/bin/sh`, so the console cannot be left dead.
* `/bin/busybox` (static; 267 applets symlinked into `/bin` for `min`, 265 for `dash`,
  231 for `debian` — the farm never overwrites a real Debian binary).
* `/usr/lib/arlo/inventory.sh` — prints what the kernel and board actually are.
* `/usr/lib/arlo/smoke.sh` — the deterministic self-test that produces the evidence.
* `/etc/arlo/CAPABILITY.txt` — the honest capability statement, shipped *inside* the
  image so it travels with the artefact.
* `/etc/arlo/manifest.tsv` — the exact package versions in this image.

Variant-specific: `dash` and `debian` add Debian `dash` at `/bin/dash` and glibc;
`debian` adds coreutils, dpkg, sed, grep, tar, gzip. Both add a synthesized
`/var/lib/dpkg/status` so `dpkg -l` answers truthfully (generated whenever dpkg is
present — the `dash` variant gets dpkg through dash's own dependency).

## 7. Design decisions, and why

1. **`/bin/sh` is static busybox, not dash.** The boot path must not depend on the
   dynamic linker: if glibc is broken on the device, we still get a console to diagnose
   it from. Debian's dash stays at `/bin/dash`, and `/etc/profile` hands the interactive
   console to it once it has *proved* it runs (`/bin/dash -c ':'`), guarded by an
   environment variable so `dash -l` re-reading `/etc/profile` cannot loop. Visible in
   the interactive log in §4.
2. **Busybox ash shadows the Debian binaries by name — measured, and documented.**
   Debian's busybox is built with standalone-applet support, so inside it `ls`, `sed`,
   `grep` and `tar` are *applets*: `command -v ls` answers `ls`, and `ls --version`
   prints busybox usage. Everything that must run the Debian binary calls it by path or
   runs under dash. Without that note it reads as "coreutils is missing".
3. **`/dev/console`, never a hardcoded tty.** On A9 we do not yet know the console name
   (§8), so nothing in the image names one.
4. **gzip, not xz/zstd.** `config_16k` has `CONFIG_RD_GZIP=y`; the uncompressed `.cpio`
   ships too in case that changes.
5. **No `ld.so.cache`.** glibc's built-in search path is enough, so the image does not
   depend on host tooling (`ldconfig` under qemu-user) to be correct. Measured working:
   dash, coreutils and dpkg all execute.
6. **Pruned on purpose:** `usr/share/{doc,man,info,locale,i18n,gdb,lintian}`, `var/cache`,
   `var/log`, glibc's `gconv` modules and `libnss_*`. UTF-8 and the wide/multibyte
   converters are built into libc and nothing here calls `iconv`; NSS is `files`-only
   (`/etc/nsswitch.conf`), which is compiled in. Measured effect: 272 KB of libnss
   modules left the image the first time this was written correctly.
7. **No RTC, storage or network assumptions anywhere.** The clock is reported as it is,
   with a note that a real date means "this is a VM, not the phone".
8. **The applet farm is generated from the binary itself** (`busybox --list` under
   qemu-user), with a curated fallback list if that tool is missing, so it cannot drift
   from the busybox in the image; the build records which source was used.
9. **A per-variant input manifest** (`manifest-<variant>-<hash>.tsv`). Hygiene only:
   `fetch-inputs.sh` writes a fixed `<manifest>.part` and renames it, so a shared path
   would be racy if two builds ever ran at once.

### 7.1 Things this workstream got wrong first, and how they were caught

Recorded because the project's documented recurring injury is a plausible-looking wrong
value, and every one of these was exactly that:

| Wrong claim | Caught by | Truth |
|---|---|---|
| A "manifest race" explained a 16-package `dash` closure. I wrote that into a code comment as fact. | Running the resolver alone and reading the index stanzas | **Debian's dash Depends on dpkg; dpkg Pre-Depends on tar.** No race. The comment is corrected; the per-variant manifest is hygiene, not a fix. |
| `/usr/bin/ls` "missing" → "no coreutils in this variant" | `ls -l` on the built rootfs | These bookworm debs install to **classic paths**: coreutils is at `/bin/ls`, and `/bin/sh` belongs to the dash package. |
| `tool_check sed` passed on a busybox applet | Reading the value it matched | Busybox sed prints "This is not GNU sed version 4.0" — which *contains* "GNU sed". The checks now match the pinned upstream version. |
| `consoles` printed nothing while `ttyAMA0` was registered | Comparing with `/proc/consoles` read directly | `/proc/consoles` has **no header line**; an `NR>1` filter skipped its only row. |
| `memnode: no /memory/reg - loader did not fill it` on a machine whose memory was filled | Looking at the live DT | The node is unit-addressed (`memory@40000000`); the lookup now globs `memory*`. |
| The 16K run's log header said "4K pages" | Reading the generated header | The note was hardcoded. It is now a parameter, and the header claims no page size it was not told. |
| `usr/lib/*/gconv` etc. pruned | `du` on the built rootfs | The globs targeted the merged-`/usr` shape; these debs use `/lib/...`, so **nothing was pruned**. Both shapes are listed now. |

## 8. Does our kernel support this image? (INSPECTED — `a9linux/artefacts/config_16k`)

| Option | Value | Why it matters here |
|---|---|---|
| `CONFIG_ARM64_16K_PAGES` | `=y` | the A9 granule; the reason for the 16K parity runs in §4 |
| `CONFIG_BLK_DEV_INITRD` / `CONFIG_RD_GZIP` | `=y` / `=y` | an initramfs, and a gzipped one, will unpack |
| `CONFIG_BINFMT_SCRIPT` | `=y` | `/init` is a script (`#!/bin/busybox sh`); without this the kernel cannot exec it |
| `CONFIG_DEVTMPFS` / `CONFIG_DEVTMPFS_MOUNT` | `=y` / `=y` | `/dev/console` exists before userspace runs |
| `CONFIG_PROC_FS`, `CONFIG_SYSFS`, `CONFIG_TMPFS` | `=y` | the inventory and the RAM filesystems |
| `CONFIG_VT`, `CONFIG_FRAMEBUFFER_CONSOLE` | `=y`, `=y` | a console on the panel, if a framebuffer is supplied |
| `CONFIG_DRM_SIMPLEDRM` | `=y` | binds DT `simple-framebuffer` — the loader-provided panel path |
| `CONFIG_SYSFB_SIMPLEFB` | *not set* | irrelevant for the DT path; noted so nobody chases it |
| `CONFIG_SERIAL_AMBA_PL011` | *not set* | **the phone's serial console is NOT `ttyAMA0`** |
| `CONFIG_SERIAL_SAMSUNG` (+`_CONSOLE`) | `=y` | the driver family that probes Apple's `apple,s5l-uart`; its ports are `ttySAC*` |

So the initramfs itself is fine for our kernel. The **bootargs** must name the right
console (dt-engineer's DTB already says `console=ttySAC0 console=ttyGS0`, which agrees),
and this image does not care which, because it writes to `/dev/console`.

## 9. Prior work: what was read, what was **not** reused, and why

| Input | Verdict |
|---|---|
| `stage/` (61 MB, `rootfs-armhf`) | **Not reused.** armhf — 32-bit ARM userspace on an arm64 device. Wrong architecture; and 32-bit compat at a 16K granule is not something we can rely on either. |
| `arm64-test/rootfs-arm64` (104 MB) | **Not reused.** An Ubuntu arm64 *chroot* tree: no `/init`, no `/sbin/init`, no `/bin/sh` — never an initramfs, and it carries 100 MB we do not need. |
| `arm64-test/busybox-armv8l` | **Not reused, and this is the trap worth recording:** `file` reports `ELF 32-bit LSB executable, ARM` — "armv8l" is the *32-bit* ABI name, not arm64. It would have failed at exec on the device. |
| `arm64-test/*.deb` (dash, coreutils arm64) | Not reused: superseded by the pinned, hash-verified Debian bookworm set, which brings its own verified library closure. |
| `a9linux/artefacts/initramfs.gz` | **Not reused.** Inspected: a stock Alpine **netboot** initramfs (`lib/ld-musl-aarch64.so.1`, `init_functions.sh`, `extract.cpio.lzma`), musl-based, nothing to do with this userland. (It is, however, where the DTB's initrd window size appears to have come from — §5.2.) |
| `a9linux/artefacts/config_16k` | **Read** — the source of §8, and real evidence about our kernel. |
| `a9linux/dts/n69-loader-target.dts` | **Read** (not written) — the source of the initrd window in §5.2 and of the bootargs console names in §8. |

Everything in `dist/` is built from the Debian archive: 22 packages, pinned in
`pins/bookworm-arm64.pins`, each verified against the SHA-256 in its index stanza
(`dist/inputs-manifest.tsv`).

## 10. Honest capability statement

A console with a shell is the first real milestone here, and it is worth having. It is
not a usable system:

* **No storage.** No NAND/NVMe/MMC driver upstream: no disk to install to, nowhere for
  anything to persist. A reboot loses everything, by design.
* **No USB host, no Wi-Fi, no network.** `lo` is the only interface. No apt, no ssh.
* **No PMIC.** No battery, charger, regulators or RTC; the clock reads 1970-01-01.
* **No GPU or display-pipe driver.** A picture is possible only as a linear framebuffer
  the loader left behind, inherited through `simple-framebuffer` — one static image, no
  acceleration, and not yet demonstrated on A9.
* **No KVM, ever** — A9 has no EL2.

The same statement ships inside every image at `/etc/arlo/CAPABILITY.txt`.

## 11. Residual risk, ranked

1. **The real kernel and the loader hand-off.** The 16K-parity runs (§4) remove the page
   -granule risk; what remains is that a defconfig kernel is not the hoolock kernel, and
   nothing here tests the MMU/cache/EL state `a9boot` must leave behind.
2. **The initrd window (§5.2).** A window smaller than the image means a truncated
   initramfs and a misleading late failure. Use `min` until the loader computes the end
   address, or until the window is enlarged.
3. **Console discovery on A9.** The serial console is not `ttyAMA0` (§8). If
   `stdout-path`/bootargs are wrong there is no output at all — and no way to tell a
   console misconfiguration from a boot failure. `min` first also reduces variables here.
4. **Loader placement and the real DRAM map.** Whether kernel + initramfs land somewhere
   free is a9boot's contract, not this image's.
5. **DFU transfer of 4–7.5 MB** into pwned DFU mode: rate and reliability unmeasured.
6. **Framebuffer console on the panel**: needs the loader to fill `/chosen/framebuffer0`
   so `simple-framebuffer` → `simpledrm` → `fbcon` can bind; unproven end to end.

## 12. Evidence index, and how claims are labelled

| Claim | Label | Where |
|---|---|---|
| every image reaches a shell from RAM | **MEASURED** | `evidence/qemu-console-smoke-*.log` (PASS marker), 3 variants × 2 kernels |
| the console shell executes commands | **MEASURED** | `evidence/qemu-console-interactive-*.log` |
| the Debian glibc userland runs (dash, coreutils, dpkg) | **MEASURED** | interactive logs for `dash` and `debian` |
| the images run on a 16K-granule kernel | **MEASURED** | `evidence/qemu-console-*-16k.log` (`pagesize 16 kB`) |
| the build is reproducible | **MEASURED** | `scripts/check-reproducible.sh` output (§3) |
| artefact hashes and sizes | **MEASURED** | `SHA256SUMS`, `dist/*.sha256` |
| which artefacts fit the declared initrd window | **MEASURED** | `scripts/check-loader-window.sh` (§5.2) |
| our kernel's relevant config options | **INSPECTED** | `a9linux/artefacts/config_16k` (§8) |
| the phone's console is a `ttySAC*` port | **INFERRED** | config + driver naming; agrees with dt-engineer's bootargs |
| DRAM is 2 GiB | **INFERRED** | device model; the loader's `/memory` node is authoritative |
| it will boot on the iPhone | **NOT ESTABLISHED** | [`CANNOT-PROVE.md`](CANNOT-PROVE.md) |
