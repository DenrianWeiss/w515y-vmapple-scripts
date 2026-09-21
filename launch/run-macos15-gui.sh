#!/bin/bash
# launch/run-macos15-gui.sh
#
# Boot the macOS (vmapple) guest on the "macOS 15 paired changes" stack:
#
#   QEMU    src/reims-vgpu/vendor/qemu/build/qemu-system-aarch64 (from ../build.sh)
#   vGPU    src/reims-vgpu -> src/metal2vulkan (Vulkan backend + host window)
#
# It mirrors the proven Ventura launcher:
#   * rmmod/insmod the four KVM shims from ../kmod (cache/psci11/isar1/probe);
#   * point metal2vulkan's in-process libLLVM at an LLVM 22 runtime
#     (METAL2VULKAN_LLVM_LIBRARY; host-provided, not bundled);
#   * force winit onto X11 by default (the Maleoon Wayland WSI never returns
#     swapchain images: presents=0 busy_acquire>0);
#   * hand off to ./boot-macos.sh, which starts QEMU paused + gdbstub + QMP
#     and runs the XNU handoff injector (inject/).
#
# Everything written stays inside the bundle (../logs, ../work).
#
# usage:
#   RUNSEC=900 ./run-macos15-gui.sh
#   RUNSEC=900 WINIT_BACKEND=wayland ./run-macos15-gui.sh
#
# Root is needed only to (re)load the KVM shims and to read dmesg: the script
# calls sudo for those, which prompts on the terminal you started it from, or
# you can run it as root yourself. There is no password variable.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"     # bundle/launch
BUNDLE="$(cd "$HERE/.." && pwd)"                         # bundle root

QEMU="${QEMU:-${QEMU_BIN:-$BUNDLE/src/reims-vgpu/vendor/qemu/build/qemu-system-aarch64}}"
KMOD_DIR="${KMOD_DIR:-$BUNDLE/kmod}"
INJECT_DIR="$HERE/inject"
[ -x "$QEMU" ] || { echo "FATAL: no QEMU at $QEMU (run ../build.sh first, or set QEMU=)" >&2; exit 2; }

RUNSEC="${RUNSEC:-900}"
CPUS="${CPUS:-4}"
KMOD_LOAD="${KMOD_LOAD:-1}"
KMOD_HCR="${KMOD_HCR:-1}"

# Host-provided guest images: env vars, or ../images/ defaults.
export BOOTER="${BOOTER:-$BUNDLE/images/AVPBooter.vmapple2.bin}"
export AUX="${AUX:-$BUNDLE/images/aux.img}"
export DISK="${DISK:-$BUNDLE/images/disk.img}"

# --- metal2vulkan: in-process LLVM 22 -----------------------------------------
# The macOS15 metal2vulkan branch loads libLLVM's C API in-process for AIR
# bitcode (no more llvm-dis/spirv-val execs) and statically links SPIRV-Tools.
# A system libLLVM (10/11) is too old for AIR bitcode, so point
# METAL2VULKAN_LLVM_LIBRARY at an LLVM 22 runtime; extra runtime libs
# (libstdc++, libgcc, libxml2, iconv) go via LLVM_LD_LIBRARY_PATH.
if [ -n "${METAL2VULKAN_LLVM_LIBRARY:-}" ]; then
  export METAL2VULKAN_LLVM_LIBRARY
else
  echo "warning: METAL2VULKAN_LLVM_LIBRARY unset; bitcode AIR will fail to load" >&2
fi

# glib/nettle runtimes (QEMU needs glib >= 2.66); override with LOCAL_LIB.
LOCAL_LIB="${LOCAL_LIB:-$HOME/.local/lib/usr/local/lib/aarch64-linux-gnu:$HOME/.local/lib/lib64}"

# run-vm.sh prepends its own LOCAL_LIB to this, so order stays: QEMU/glib first,
# then the LLVM 22 runtime.
export LD_LIBRARY_PATH="${LLVM_LD_LIBRARY_PATH:-}:$LOCAL_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# --- host window --------------------------------------------------------------
# The macOS15 branch makes the Rust host window opt-in behind REIMS_VGPU_WINDOW
# (the Ventura branch opened it unconditionally). Presence enables it; set
# REIMS_VGPU_WINDOW=0 to boot with no host window (QEMU owns no display either).
case "${REIMS_VGPU_WINDOW-1}" in
  0|no|off|false) unset REIMS_VGPU_WINDOW ;;
  *)              export REIMS_VGPU_WINDOW=1 ;;
esac
WINIT_BACKEND="${WINIT_BACKEND:-x11}"
if [ "$WINIT_BACKEND" = x11 ]; then
  # winit prefers Wayland whenever WAYLAND_DISPLAY is set, and this host's
  # Wayland WSI stalls the swapchain. Clear it to select X11.
  unset WAYLAND_DISPLAY
fi
export DISPLAY="${DISPLAY:-:0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
[ -n "${XAUTHORITY:-}" ] && export XAUTHORITY

# QEMU gates VMApple HVC forwarding on getenv()!=NULL; this Kylin 5.10 KVM
# rejects it, so the default is unset. HVC=1 opts back in.
if [ "${HVC:-0}" = 1 ]; then export QEMU_VMAPPLE_KVM_HVC=1; else unset QEMU_VMAPPLE_KVM_HVC; fi

# --- privileges ---------------------------------------------------------------
# insmod/rmmod and `dmesg -C` need root. No password is carried in the
# environment: root is obtained by calling sudo, which prompts on the terminal
# this script was started from (and does nothing at all when you already are
# root). KMOD_LOAD=0 needs no privileges.
if [ "$(id -u)" = 0 ]; then
  as_root() { "$@"; }
elif sudo -n true 2>/dev/null; then
  as_root() { sudo -n -- "$@"; }
elif [ -t 0 ]; then
  as_root() { sudo -- "$@"; }
else
  as_root() {
    echo "cannot become root: there is no terminal here for sudo to prompt on." >&2
    echo "Start this script from a terminal (sudo will ask for your password then), or" >&2
    echo "run the launcher with sudo yourself, or load the KVM shims by hand and use KMOD_LOAD=0." >&2
    return 1
  }
fi

if [ "$KMOD_LOAD" = 1 ] && ! as_root true; then
  # Fail here rather than halfway through the boot; the interactive branch
  # above has cached the sudo timestamp by now.
  exit 2
fi

STAMP=$(date +%Y%m%d-%H%M%S)
LOGDIR="$BUNDLE/logs"; mkdir -p "$LOGDIR" "$BUNDLE/work"
LOG="${LOG:-$LOGDIR/gui-serial-$STAMP.log}"
ERRLOG="${ERRLOG:-$LOGDIR/gui-qemu-$STAMP.log}"
QMP="${QMP:-$BUNDLE/work/qmp-gui-$STAMP.sock}"
INJLOG="${INJLOG:-$LOGDIR/gui-inject-$STAMP.log}"
REIMSLOG="${REIMSLOG:-$LOGDIR/gui-reims-$STAMP.log}"
DMESG="${DMESG:-$LOGDIR/gui-dmesg-$STAMP.log}"

echo "=== macOS graphical boot (reims vGPU) ==="
echo "qemu   : $QEMU"
echo "display: DISPLAY=${DISPLAY:-} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-} WINIT_BACKEND=$WINIT_BACKEND"
echo "llvm   : ${METAL2VULKAN_LLVM_LIBRARY:-<unset>}"
echo "logs   : $LOGDIR"

# --- stop stale QEMU (comm is truncated to 15 chars) --------------------------
for p in /proc/[0-9]*; do
  [ "$(cat "$p/comm" 2>/dev/null)" = "qemu-system-aar" ] && kill -9 "${p#/proc/}" 2>/dev/null
done
sleep 1

# --- (re)load host KVM shims --------------------------------------------------
# kvm_psci11 + kvm_cache_norm are mandatory for -M vmapple on Kylin 5.10;
# kvm_isar1_fix carries the Apple PAuth / Apple-HVC fixes; hcr_probe is the
# read-only HCR/ID diagnostic the Ventura baseline also loads.
if [ "$KMOD_LOAD" = 1 ]; then
  as_root dmesg -C 2>/dev/null
  for m in vmapple_pac hcr_probe kvm_isar1_fix kvm_psci11 kvm_cache_norm; do
    as_root rmmod "$m" 2>/dev/null
  done

  ISAR_PARAMS=${ISAR_PARAMS:-"fix_hcr=0 apa=5 api=4 gpa=1 fix_keys=1 zero_keys=0 dbg=0 pac_log=200"}
  PROBE_PARAMS=${PROBE_PARAMS:-"hcr_api=1 hcr_apk=1 hcr_tid3=1 hcr_tvm=0 clear_sctlr_en=0 clear_at_entry=0 dbg=1"}

  as_root insmod "$KMOD_DIR/extra/kvm_cache_norm.ko" \
    || { echo "FATAL: kvm_cache_norm insmod ($KMOD_DIR/extra/kvm_cache_norm.ko)"; exit 1; }
  as_root insmod "$KMOD_DIR/extra/kvm_psci11.ko" \
    || { echo "FATAL: kvm_psci11 insmod ($KMOD_DIR/extra/kvm_psci11.ko)"; exit 1; }
  # shellcheck disable=SC2086
  as_root insmod "$KMOD_DIR/kvm_isar1_fix/kvm_isar1_fix.ko" $ISAR_PARAMS \
    || { echo "FATAL: kvm_isar1_fix insmod ($KMOD_DIR/kvm_isar1_fix/kvm_isar1_fix.ko)"; exit 1; }
  if [ "$KMOD_HCR" = 1 ]; then
    HCR_KO="${HCR_PROBE_KO:-$KMOD_DIR/hcr_probe/hcr_probe.ko}"
    # shellcheck disable=SC2086
    as_root insmod "$HCR_KO" $PROBE_PARAMS \
      || { echo "FATAL: hcr_probe insmod ($HCR_KO)"; exit 1; }
  fi
fi

# Fresh Reims sink.
rm -f /tmp/reims-vgpu-fail.log

echo "=== starting QEMU via $HERE/boot-macos.sh (RUNSEC=$RUNSEC CPUS=$CPUS) ==="
(
  while :; do
    sleep 5
    [ -f /tmp/reims-vgpu-fail.log ] && cp -f /tmp/reims-vgpu-fail.log "$REIMSLOG"
  done
) &
SNAP_PID=$!
trap 'kill $SNAP_PID 2>/dev/null' EXIT

# boot-macos.sh starts QEMU paused with a gdbstub + QMP socket, then runs
# inject/inject-xnu-kvm.gdb (boot-args/CSR, GIC store rewrite, PAC default-key
# seed). Only QEMU and the log destinations are overridden here.
QEMU="$QEMU" CPUS="$CPUS" RUNSEC="$RUNSEC" \
  LOG="$LOG" ERRLOG="$ERRLOG" QMP="$QMP" INJLOG="$INJLOG" \
  bash "$HERE/boot-macos.sh"
rc=$?

kill $SNAP_PID 2>/dev/null; trap - EXIT
[ -f /tmp/reims-vgpu-fail.log ] && cp -f /tmp/reims-vgpu-fail.log "$REIMSLOG"
# Best-effort dmesg snapshot. Skipped when it would need a fresh root password
# prompt after a long run (already root, or passwordless sudo, works silently).
if [ "$(id -u)" = 0 ] || sudo -n true 2>/dev/null; then
  as_root dmesg > "$DMESG" 2>/dev/null || rm -f "$DMESG"
fi

echo "=== macOS gui boot rc=$rc ==="
echo "SERIAL=$LOG"
echo "REIMS=$REIMSLOG"
echo "QEMU=$ERRLOG"
echo "INJECT=$INJLOG"
echo "DMESG=$DMESG"
echo "--- reims capability / display lines ---"
grep -nE 'vk_caps|vk_linear|device_info|display_online|display_enable|present_content|present_black|guest_attach|host_window|error|failed' "$REIMSLOG" 2>/dev/null | head -40
echo "--- window (xwininfo) ---"
command -v xwininfo >/dev/null 2>&1 && xwininfo -root -tree 2>/dev/null | grep -i 'Reims vGPU' || true
exit $rc
