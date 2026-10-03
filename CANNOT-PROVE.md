# What the QEMU smoke test cannot prove

Written by `rootfs-engineer` (task-9). Read this before quoting a green QEMU run as
evidence about the phone.

The smoke test boots this initramfs on QEMU's arm64 `virt` machine, with **stand-in
kernels**: a pinned Debian 6.1 arm64 kernel (4K pages, `virt` platform), and a minimal
Linux 6.1.176 arm64 defconfig kernel built here with **16K pages** to match the A9
granule. Neither is the arlo A9 kernel (task-6, hoolock, 16K pages, Apple platform) and
neither is bootable on the phone even in principle — different platform, different
device tree.

## Proven by the smoke test (MEASURED)

- The initramfs archive is well formed and the kernel's initramfs unpacker accepts it
  — on a 4K kernel and on a **16K** kernel.
- PID 1 (`/init`) runs from RAM, with a static busybox as its interpreter.
- `/proc`, `/sys`, `devtmpfs` and a RAM-backed `/tmp` come up.
- A shell is reachable on the console, through `/etc/inittab`, and it executes
  commands typed at the console; `/etc/profile` hands that console to Debian `dash`.
- The Debian glibc binaries in the image execute: `dash`, coreutils `ls`,
  `dpkg --version` and `dpkg -l` (the last one reads the synthesized package
  database, so it also proves `/var/lib/dpkg/status` parses) — on both granules.
- The image is 7,504,935 bytes compressed and carries no dependency on storage,
  networking or a clock.

## NOT proven — every one of these is a real risk on the device

1. **The real kernel's 16K-page behaviour — and the loader hand-off.**
   The page-granule risk is now largely **MEASURED**: all three images were booted on a
   16K-granule kernel (`dist/standin-kernels/Image-16k-6.1.176`, arm64 defconfig,
   `CONFIG_ARM64_16K_PAGES=y`, `-cpu max`) and the guest reported `pagesize 16 kB` with
   the smoke test passing (`evidence/qemu-console-smoke-*-16k.log`).
   What that still does **not** cover: it is a generic `virt` platform kernel, not the
   hoolock kernel; and nothing here tests the MMU/cache/EL state that `a9boot` must
   leave behind. Those remain INFERRED.
2. **The A9 bootrom/loader hand-off, including the initrd window.** Nothing here says
   the loader can place a 33 MB kernel plus the initramfs in DRAM, or that the addresses
   it picks are free. That contract belongs to `a9boot` and
   `a9linux/dts/LOADER-FILL.md`. One part of it is already known to be wrong for the
   larger images: the device tree declares a 2,670,592-byte initrd window
   (`a9linux/dts/n69-loader-target.dts` lines 1198-1199), and only the 997,191-byte
   `min` image fits inside it — `dash` needs 4,015,918 and `debian` needs 7,478,005.
   Handed a larger image with that end address the kernel unpacks a **truncated**
   archive and dies late with a misleading unpack/VFS error. Measured, not guessed:
   `debian-ios/scripts/check-loader-window.sh`.
3. **The real DRAM map.** QEMU was given `-m 1024` by our choice. A9/n69ap amounts
   and layout come from the loader's `/memory` node; the `2 GiB` figure used in the
   size budget is INFERRED from the device model.
4. **The real console.** QEMU's console is `ttyAMA0` (PL011). `config_16k` has
   `# CONFIG_SERIAL_AMBA_PL011 is not set` and `CONFIG_SERIAL_SAMSUNG=y` — so on the
   phone the serial console is a *different tty name* (Apple's `apple,s5l-uart`
   probed by the samsung_tty driver, i.e. a `ttySAC*` port, or whatever the DT's
   `stdout-path` resolves to). The initramfs sidesteps this by using `/dev/console`
   for everything and never hardcoding a tty name, but the *bootargs* on the device
   must still name the right console.
5. **The screen.** `config_16k` has `CONFIG_DRM_SIMPLEDRM=y`,
   `CONFIG_FRAMEBUFFER_CONSOLE=y` and `CONFIG_VT=y`, so a framebuffer console is
   possible. Whether a picture appears depends on the loader filling
   `/chosen/framebuffer0` (`simple-framebuffer`) — dt-engineer's and a9boot's side,
   not this image. QEMU's `virt` machine exposes no such framebuffer in these runs,
   so the framebuffer path is entirely untested here (`/dev/fb0 absent` in the log).
6. **Absence of drivers on A9.** "No storage, no network, no PMIC" is a statement
   about upstream A9 support (HANDOFF §4), not something QEMU can demonstrate.
   QEMU *does* have virtio and an RTC; the phone will not.
7. **Time.** QEMU's `virt` machine has a PL031 RTC, so the guest clock is correct in
   the log. On A9 there is no RTC driver upstream (it lives in the PMIC), so the
   clock will read 1970-01-01. That is expected, not a fault.
8. **Kernel version.** The stand-in is 6.1. Ours is 7.2 (`config_16k` header). An
   initramfs is a stable interface, but "stable" is a claim about the interface, not
   a measurement of our kernel.
9. **Transfer.** Neither QEMU nor this document says anything about uploading 7.5 MB
   over DFU into pwned DFU mode, or about how long that takes.

## The honest one-line summary

A green smoke test says: *this userland is well formed, and a Linux kernel can boot
it to a working shell from RAM.* It does not say: *this runs on the iPhone.*
