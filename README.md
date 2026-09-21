# macOS (vmapple) + Reims vGPU on aarch64 Linux/KVM - source bundle

This bundle builds and boots an Apple `vmapple` machine emulation with aparavirtualized GPU ("Reims vGPU") on Huawei w515y with a macOS 13 guest.
This repo solely serves as a research project, and you should not use it for running production macOS. Please buy a mac if you need macOS.
You need to have at least 16 GB RAM configuration, 8 GB ones will surely hang the system.

[让我们说中文](README-CN.md)

## Credits

This Repo is based on [imbushuo's work](https://github.com/imbushuo), and steelhead's forked qemu and reims-vgpu. Also, we have referenced Asahi Linux's efforts for Apple Silicon support on Linux, especially for the boot and device initialization sequences.

## Notes

- Due to lacking hardware features, Qcom platforms cannot run XNU kernel from apple, anyone claiming this is either mistaken or doing fraud.
- This repo is checked out from a dirty working environment, and its usability cannot be fully guaranteed.

## Contents

```
build.sh                  clone the pinned repos, apply the patches, build QEMU, verify
README.md                 this file
patches/qemu/             QEMU source adaptations        (applied by build.sh)
patches/reims-vgpu/       Rust vGPU device fixes         (applied by build.sh)
patches/kmod/             adds the hcr_probe kernel module (applied by build.sh)
launch/                   boot chain: launcher -> driver -> QEMU start -> XNU injector
  launch-macos-gui.sh     entry point (host window, sudo for insmod)
  run-macos15-gui.sh      loads the shim modules, sets up the LLVM runtime, hands off
  boot-macos.sh           starts QEMU paused with gdbstub + QMP, runs the injector
  run-vm.sh               the QEMU command line itself
  inject/                 XNU boot-args/CSR injection, GIC store rewrite, PAC key seed
```

`src/`, `kmod/` and `logs/` appear after you run `build.sh`; `work/` after you boot.

Not in the bundle, because they are host- or licence-specific:

- Apple booter firmware (`AVPBooter.vmapple2.bin`) and the guest images
  (`aux.img`, `disk.img`) - see "Boot".
- LLVM 22 shared library used by the metal2vulkan runtime.
- The host's Vulkan driver (the Mali/Maleoon userspace driver and its ICD).

## 1. What you need

### Host

- aarch64 Linux with KVM enabled (`/dev/kvm`), kernel 5.10.x with the KOS
  patches is what the shim modules were written for; other kernels need
  `kmod/*/offsets.h` regenerated (see `kmod/gen_offsets.py`).
- Your user in the `kvm` group, so QEMU can open `/dev/kvm` unprivileged. The
  four KVM shim modules are loaded with `sudo` (the launcher prompts you for the
  password on the terminal you start it from) and `dmesg` is read the same way;
  nothing needs root apart from that.
- X11 (the host window forces the X11 backend; the Wayland path does not
  present frames on this driver).

### Packages

```sh
sudo apt install build-essential ninja-build pkg-config git gdb python3 \
     python3-venv python3-pip zlib1g-dev libpixman-1-dev libslirp-dev \
     libglib2.0-dev libnettle-dev libxkbcommon-dev libwayland-dev \
     libx11-dev libxrandr-dev libxi-dev libxcursor-dev libvulkan-dev \
     vulkan-tools libgtk-3-dev linux-headers-$(uname -r)
```

Notes:

- **gcc >= 10.3** is required (patch `patches/qemu/0002` relaxes QEMU's
  blanket `>= 10.4` gate). On Kylin V10 the system gcc is 9.3, so `build.sh`
  defaults to `CC_BIN=gcc-10` / `CXX_BIN=g++-10` and falls back to `gcc`/`g++`
  when those names do not exist. Override with `CC_BIN`/`CXX_BIN`.
- **nettle is mandatory.** With no crypto library visible QEMU 11 silently
  builds `crypto/cipher-stub.c.inc`; the vmapple AES engine then fails every
  operation and the guest hangs in `AppleVPKeyStore` before `launchd`, with no
  obvious error. `build.sh` disables gnutls, enables nettle, and fails the
  verify step (`ldd` must show `libnettle`) if the stub got linked instead.
- **glib >= 2.66** and **python >= 3.10 with a working `ensurepip`/setuptools
  >= 64** are required by QEMU's build system. On Kylin V10 both are too old in
  the system installation; the reference setup builds glib 2.74.7 and uses a
  newer Python locally, which is why `GLIB_PC_DIR`, `NETTLE_PC_DIR` and
  `QEMU_PYTHON` exist (defaults: `$HOME/.local/...`, see the table below).
  QEMU's `configure` complains instead of guessing, so if it fails, look at
  `logs/configure.log` and point these variables at your own builds.

### Rust

You should install `cargo` with rustup.

## 2. Build

```sh
./build.sh                 # deps check + clone + patch + configure + ninja + verify
RECLONE=1 ./build.sh       # start over from an empty src/ and kmod/
JOBS=8 ./build.sh
KMOD_CHECK=1 ./build.sh    # also compile-check the kernel modules
```

Result: `src/reims-vgpu/vendor/qemu/build/qemu-system-aarch64` (statically links
the Rust vGPU device; Vulkan + host-window backend).

`build.sh` clones the pinned repositories into `src/` and `kmod/`, then applies
`patches/reims-vgpu/` to `src/reims-vgpu`, `patches/qemu/` to
`src/reims-vgpu/vendor/qemu` - the tree it builds - and `patches/kmod/` to the
bundle root (adding `kmod/hcr_probe/`). Patch application is
idempotent: re-running reports "already applied" and skips.

## 3. Kernel modules

The vmapple machine needs four KVM shim modules on a KOS/Kylin 5.10 kernel:
`kvm_cache_norm`, `kvm_psci11`, `kvm_isar1_fix` (from `kmod/`, which `build.sh`
clones from DenrianWeiss/accelerated-macos-for-w515y) and `hcr_probe`, which
this bundle adds through `patches/kmod/0001-add-hcr-probe-module.patch`.

`build.sh` applies that patch (it creates `kmod/hcr_probe/`) unless
`KMOD_PATCH=0`. Then build against your running kernel:

```sh
make -C kmod            KDIR=/lib/modules/$(uname -r)/build   # cache_norm + psci11 + isar1_fix
make -C kmod/hcr_probe  KDIR=/lib/modules/$(uname -r)/build
```

`hcr_probe` is not optional on this kernel (`CONFIG_ARM64_PTR_AUTH=n`): it sets
`HCR_EL2.API/APK/TID3` on every vCPU entry, and without it the guest dies on
the first PAC instruction, long before the XNU handoff. The launcher loads it
from `kmod/hcr_probe/hcr_probe.ko`, so build it before booting (or point
`HCR_PROBE_KO=` at a prebuilt one, or set `KMOD_HCR=0` to skip it).
`kmod/gen_offsets.py` regenerates `offsets.h` from a kernel image if your
kernel differs from 5.10.97-19-9000x.

## 4. Boot

The launcher reads host-provided inputs; nothing is copied into the bundle.
The defaults point at `images/` inside the bundle, so either drop the files
there or set the variable:

| variable | default | meaning |
| --- | --- | --- |
| `FW_DIR` | `images/` | directory holding booter and images |
| `BOOTER` | `images/AVPBooter.vmapple2.bin` | Apple booter firmware |
| `AUX` | `images/aux.img` | aux firmware image |
| `DISK` | `images/disk.img` | macOS root disk image |
| `METAL2VULKAN_LLVM_LIBRARY` | unset (warns) | LLVM 22 `libLLVM` for the metal2vulkan runtime |
| `LLVM_LD_LIBRARY_PATH` | unset | extra runtime libs for that LLVM (libstdc++, libgcc, libxml2, iconv) |
| `LOCAL_LIB` | `$HOME/.local/lib/usr/local/lib/aarch64-linux-gnu:$HOME/.local/lib/lib64` | glib/nettle shared libraries QEMU links against |
| `KMOD_DIR` | `kmod/` | directory with the built shim modules |
| `HCR_PROBE_KO` | `$KMOD_DIR/hcr_probe/hcr_probe.ko` | override if `hcr_probe` is prebuilt elsewhere |

```sh
BOOTER=/path/AVPBooter.vmapple2.bin \
AUX=/path/aux.img \
DISK=/path/disk.img \
METAL2VULKAN_LLVM_LIBRARY=/path/libLLVM.so.22 \
./launch/launch-macos-gui.sh
```

Root is needed only to (re)load the four KVM shim modules and to read `dmesg`.
There is no password variable in this bundle: the launcher runs `sudo` for
those few commands, which prompts on the terminal you started it from
(`sudo -n`, no prompt, when passwordless sudo is configured; nothing is
escalated when you are already root). You can also run the whole launcher as
root yourself (`sudo -E ./launch/launch-macos-gui.sh`) - QEMU then runs as root
too, which works but leaves the host window owned by root and writes `logs/`
and `work/` as root. With `KMOD_LOAD=0` (modules already loaded) no privileges
are needed at all, and a non-interactive start fails with a message instead of
hanging on a password prompt.

The guest serial console, QEMU stderr, the injector log and the Reims vGPU
sink land in `logs/`; `work/` holds the QMP socket and a throwaway copy of the
aux image. The Reims host window opens on X11.

Useful knobs (see the header comments of `launch/launch-macos-gui.sh` and
`launch/run-macos15-gui.sh` for the complete list): `RUNSEC=<seconds>` to stop
automatically, `CPUS=4`, `WINIT_BACKEND=x11|wayland`, `REIMS_VGPU_WINDOW=0`
(no host window), `KMOD_LOAD=0` (no modules), `KMOD_HCR=0` (skip hcr_probe),
`ISAR_PARAMS` / `PROBE_PARAMS` (module parameters), `XNU_BOOT_ARGS`,
`CSR_CONFIG`, `NOINJECT=1`, `GDB_PORT`, `PAUSE=1`, `NOREB=1`,
`ACCEL=tcg CPU=max` (no KVM), `RAM=8G`, `HVC=1`, `SSH_PORT`, `VNC_PORT`,
`SERIAL_SOCK=<path>`, `TRACE="enable=<event>"`, `QEMU=<path>`.

## 5. Build environment variables

| variable | default | meaning |
| --- | --- | --- |
| `SRC` | `./src` | where the pinned repositories are cloned |
| `PATCHES_DIR` | `./patches` | patch tree; set to a nonexistent path for an unpatched build |
| `CC_BIN` / `CXX_BIN` | `gcc-10` / `g++-10`, else `gcc`/`g++` | host compilers |
| `GLIB_PC_DIR` | `$HOME/.local/lib/usr/local/lib/aarch64-linux-gnu/pkgconfig` | pkgconfig dir with glib >= 2.66 |
| `NETTLE_PC_DIR` | `$HOME/.local/lib/lib64/pkgconfig`, else `$HOME/.local/lib/pkgconfig` | pkgconfig dir with nettle |
| `QEMU_PYTHON` | newest of `$HOME/bin/python3.14/bin/python3.14`, `python3.14`, `python3.12`, `python3` | interpreter QEMU's build uses |
| `JOBS` | `nproc` | ninja parallelism |
| `RECLONE` | `0` | `1` = remove `src/` and `kmod/` first |
| `APPLY_PATCHES` | `1` | `0` = build unpatched upstream (A/B runs) |
| `KMOD_PATCH` | `1` | `0` = do not add `kmod/hcr_probe/` |
| `KMOD_CHECK` | `0` | `1` = compile-check the modules after building QEMU |
| `CLONE_STANDALONE_QEMU` | `0` | `1` = also clone a standalone `src/qemu` |
| `METAL2VULKAN_REV`, `REIMS_REV`, `QEMU_REV`, `QEMU_BRANCH`, `KMOD_REV` | see the pins below | override the pinned revisions |

## 6. Pinned revisions and patches

| repo | commit | branch |
| --- | --- | --- |
| imbushuo/metal2vulkan | `0a44257f1f698e75e0852212de4308a1b1b6addd` | binwang/macos15-vm-paired-changes |
| imbushuo/reims-vgpu | `d55da3dc1db3b11e764a343fce37ecca9c142965` | binwang/macos15guest-vulkan-ri |
| imbushuo/qemu | `38818b7e5a65b1bde46f28a840d74ce5a8a20cab` | binwang/kvm-improvement |
| DenrianWeiss/accelerated-macos-for-w515y | `8f47181929d8091ef08f9faf52eb8fab51ae919f` | (kmod sources, cloned to `kmod/` by build.sh) |

Each patch file starts with a prose header explaining the fault it fixes and
the evidence behind it. In short:

| patch | target | fault |
| --- | --- | --- |
| `patches/qemu/0002` | QEMU | `meson.build` demands gcc >= 10.4; relax to >= 10.3 (Kylin ships 10.3.0) |
| `patches/qemu/0003` | QEMU | `hw/intc/arm_gicv5.c`: `0x23b << 31` overflows a signed int and gcc 10 rejects it under `-Werror` |
| `patches/qemu/0004` | QEMU | vmapple AES: wrong IV-context mask and hardcoded context 0, plus a FIFO that desynced after any failed command (guest "kek failed to unwrap vek", silent AES wedges) |
| `patches/qemu/0005` | QEMU | vmapple AES: direction/block mode kept in global state, so interleaved rounds on the two key contexts clobber each other; trace result is now `ok`/`need_more`/`error` |
| `patches/reims-vgpu/0001` | reims-vgpu | image slab grew unbounded on drivers that never return `VK_ERROR_OUT_OF_MEMORY` (guest panic behind never-signalling fences); adds a heap-derived slab budget with reclaim |
| `patches/reims-vgpu/0002` | reims-vgpu | protocol-version register 0x1034 answered 0 when the device lock was busy, so the guest switched its whole feature set off and never started |
| `patches/reims-vgpu/0003` | reims-vgpu | log the head of a payload-carrying `CmdNOP` (the guest does not always obey "no payload") |
| `patches/reims-vgpu/0004` | reims-vgpu | a seedless `DontCare` colour load was refused even though it promised no prior contents, leaving fences outstanding |
| `patches/reims-vgpu/0005` | reims-vgpu | yield between draws of a heavy sync exec packet (convoy relief, not a latency fix) |
| `patches/reims-vgpu/0006` | reims-vgpu | keep the released-page guard a detector: armed-on-its-own refused thousands of legitimate full-frame stores per boot |
| `patches/kmod/0001` | kmod | adds the `hcr_probe` module (HCR_EL2 API/APK/TID3 per vCPU entry) |

## 7. Troubleshooting

- Guest hangs right after `AppleVPKeyStore:32:0: safe xART is supported`, all
  vCPUs idle: QEMU was built without a crypto library. Check
  `ldd build/qemu-system-aarch64 | grep nettle` and rebuild with a valid
  `NETTLE_PC_DIR`.
- Guest resets about a second after the iBoot banner: the guest image itself is
  damaged or its APFS checkpoint selection is inconsistent (this is not an
  emulation fault) - restore the image or roll the container's checkpoint back.
- Repeated `sync_exec_lock_hold` / `draw_prepare_*` lines in the reims log with
  a slow host: expected on a driver that overcommits GPU memory; the patches in
  `patches/reims-vgpu/` bound the worst cases.
- The host window stays black on Wayland: force `WINIT_BACKEND=x11`.
