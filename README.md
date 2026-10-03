<div align="center">
	<h2>debian-ios</h2>
</div>

[![License](https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square)]()
[![Platform](https://img.shields.io/badge/platform-arm64-0078D6.svg?style=flat-square)]()
[![Language](https://img.shields.io/badge/language-shell%20%2B%20overlay-orange.svg?style=flat-square)]()
[![Status](https://img.shields.io/badge/status-boots%20to%20a%20shell%20in%20QEMU-brightgreen.svg?style=flat-square)]()

### A RAM-backed Debian arm64 initramfs that boots to a shell — the project's first working console.

The userland half of mainline Linux on an iPhone SE 1st gen (Apple A9 `s8003`, board `n69ap`). A reproducible recipe that builds an arm64 initramfs a kernel can boot from RAM, the built images, and a QEMU smoke test that proves they reach a shell.

---

### What is this, and what is it not?

**It is** a console with a shell — the milestone that everything after it depends on.

**It is not** a usable computer. Upstream A9 support has no storage, no USB host, no PMIC and no Wi-Fi driver, so nothing persists, nothing can be installed, and there is no network. The kernel this really needs (16K pages, Apple platform) does not exist yet; every boot here used a **stand-in kernel**, and this repository says so rather than implying otherwise.

---

### What does this do?

```
scripts/build-initramfs.sh     # reproducible: fixed mtimes, sorted order, gzip -9n
scripts/smoke-test-qemu.sh     # boot it and prove it reaches the shell
scripts/check-reproducible.sh  # two builds, one hash
```

`overlay/` carries the init and the files the rootfs needs; `pins/` records the exact Debian packages; `CANNOT-PROVE.md` states what this setup cannot establish even when it passes.

---

### The failure this exists to prevent

**"It booted" being mistaken for "it works."** The smoke test proves the image reaches a shell in QEMU — nothing more. The A9's real peripherals, real DRAM map, real interrupt controller and real console are not exercised by it, and a passing test here has no bearing on whether the phone would boot.

The reproducible-build check exists because the first archive embedded its build time: its hash could never be re-derived, so nothing could be verified. Fixed mtimes, sorted packing and `gzip -9n` now make two consecutive builds hash identically — which is what makes "this is the image we tested" a checkable claim.

---

### Status

Builds and boots to a shell under QEMU (reproduced on bare-metal Linux, no root, no KVM). Package pins recorded; the stand-in kernel's provenance is documented in `evidence/`. The real kernel — 16K pages, Apple platform — is the one still missing.
