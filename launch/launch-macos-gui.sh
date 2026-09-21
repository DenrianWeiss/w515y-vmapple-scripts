#!/bin/bash
# launch/launch-macos-gui.sh - boot the macOS (vmapple) guest with the Reims
# vGPU host window on a non-Apple aarch64 KVM host.
#
# Thin interactive wrapper around ./run-macos15-gui.sh (same directory):
#   1. (re)loads the KVM shim modules built from ../kmod (kvm_cache_norm,
#      kvm_psci11, kvm_isar1_fix, hcr_probe) through sudo - which asks for your
#      password on the terminal you start it from; set KMOD_LOAD=0 to skip this
#      when the modules are already loaded
#   2. starts the bundle QEMU (reims-vgpu -> metal2vulkan -> Vulkan + winit,
#      X11 backend) paused, with a QMP socket and a gdbstub
#   3. runs the XNU handoff injector (inject/): boot-args/CSR config,
#      GIC pre-indexed MMIO store rewrite, PAC default-key seed
#   4. resumes the VM; guest serial goes to ../logs/gui-serial-<ts>.log
#
# There is no password variable in this bundle: root is obtained by calling
# sudo (interactively), or by running this wrapper as root yourself. QEMU is
# happier as your own user, though - the host window attaches to your X11
# session and every file the run writes stays inside the bundle.
#
# Host-provided inputs (NOT in the bundle; env vars, or drop them into
# ../images/ to use the defaults):
#   BOOTER  Apple booter firmware (default ../images/AVPBooter.vmapple2.bin)
#   AUX     aux disk image (default ../images/aux.img; throwaway copy per boot)
#   DISK    macOS root disk image (default ../images/disk.img)
#
# usage:
#   ./launch-macos-gui.sh             # boot until Ctrl-C
#   RUNSEC=300 ./launch-macos-gui.sh  # auto-stop after 300 s
#   sudo -E ./launch-macos-gui.sh     # if you prefer to run as root throughout
#
# knobs (passed through):
#   RUNSEC CPUS WINIT_BACKEND=x11|wayland REIMS_VGPU_WINDOW=0 (no host window)
#   TIMEBASE_FREQ=<hz> (DT timer frequency the injector writes, default
#     1000000000 for a 1 GHz host timer; 0 disables the patch)
#   TRACE GLOBALS KMOD_LOAD=0 KMOD_HCR=0 KMOD_DIR METAL2VULKAN_LLVM_LIBRARY
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# RUNSEC=0 = run until killed (Ctrl-C). Override with RUNSEC=<seconds>.
export RUNSEC="${RUNSEC:-0}"
export WINIT_BACKEND="${WINIT_BACKEND:-x11}"

# Quiet defaults: drop the diagnostic '-v debug=0x14c' boot args and the kmod
# PAC dmesg spam (pac_log=200). Override to restore the noisy diagnostics.
export XNU_BOOT_ARGS="${XNU_BOOT_ARGS:-serial=3}"
export ISAR_PARAMS="${ISAR_PARAMS:-fix_hcr=0 apa=5 api=4 gpa=1 fix_keys=1 zero_keys=0 dbg=0 pac_log=0}"
export PROBE_PARAMS="${PROBE_PARAMS:-hcr_api=1 hcr_apk=1 hcr_tid3=1 hcr_tvm=0 clear_sctlr_en=0 clear_at_entry=0 dbg=0}"

exec bash "$HERE/run-macos15-gui.sh"
