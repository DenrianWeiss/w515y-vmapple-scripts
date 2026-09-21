#!/bin/bash
# launch/run-vm.sh - the vmapple macOS QEMU command line.
#
# Everything this script writes stays inside the bundle (../logs, ../work).
# QEMU and the guest images are only read. Images default to ../images/
# (override with BOOTER=/AUX=/DISK=, or FW_DIR= for the directory).
#
# Usage:
#   RUNSEC=20 ./run-vm.sh                 # run 20s, then kill
#   RUNSEC=0 ./run-vm.sh                  # run until killed
#   GDBPORT=1234 PAUSE=1 RUNSEC=0 ./run-vm.sh
#   ACCEL=tcg CPU=max RUNSEC=20 ./run-vm.sh
#   TRACE="enable=bdif_vblk_read" RUNSEC=10 ./run-vm.sh
#
# Variables:
#   QEMU FW_DIR BOOTER AUX DISK RUNSEC GFX CPUS ACCEL CPU RAM GDBPORT PAUSE NOREB
#   TRACE GLOBALS EXTRA_D LOG ERRLOG QMP COPYAUX DISPLAY SERIAL_SOCK
#   SSH_PORT VNC_PORT UUID HVC LOCAL_LIB
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"     # bundle/launch
BUNDLE="$(cd "$HERE/.." && pwd)"

QEMU=${QEMU:-$BUNDLE/src/reims-vgpu/vendor/qemu/build/qemu-system-aarch64}
FW_DIR=${FW_DIR:-$BUNDLE/images}

BOOTER=${BOOTER:-$FW_DIR/AVPBooter.vmapple2.bin}
AUX=${AUX:-$FW_DIR/aux.img}
DISK=${DISK:-$FW_DIR/disk.img}
RUNSEC=${RUNSEC:-0}            # 0 = run until killed
GFX=${GFX:-reims-vgpu-mmio}
CPUS=${CPUS:-4}
ACCEL=${ACCEL:-kvm}
CPU=${CPU:-host,sve=off}
RAM=${RAM:-8G}
GDBPORT=${GDBPORT:-}
PAUSE=${PAUSE:-0}              # 1 = start paused (-S)
NOREB=${NOREB:-0}              # 1 = -no-reboot
EXTRA_D=${EXTRA_D:-}
TRACE=${TRACE:-}
GLOBALS=${GLOBALS:-}
COPYAUX=${COPYAUX:-1}          # 1 = work on a throwaway copy of AUX
STAMP=$(date +%Y%m%d-%H%M%S)
LOG=${LOG:-$BUNDLE/logs/serial-$STAMP.log}
ERRLOG=${ERRLOG:-$BUNDLE/logs/qemu-$STAMP.log}
QMP=${QMP:-$BUNDLE/work/qmp-$STAMP.sock}
UUID=${UUID:-17424695602996444353}

# QEMU gates VMApple HVC forwarding on getenv()!=NULL. The reference launcher
# sets it to 1; on Kylin 5.10 KVM rejects it, so the default here is unset.
# HVC=1 opts back in.
if [ "${HVC:-0}" = 1 ]; then export QEMU_VMAPPLE_KVM_HVC=1; else unset QEMU_VMAPPLE_KVM_HVC; fi
# Locally built glib/nettle (QEMU needs glib >= 2.66); override with LOCAL_LIB.
LOCAL_LIB=${LOCAL_LIB:-$HOME/.local/lib/usr/local/lib/aarch64-linux-gnu:$HOME/.local/lib/lib64}
export LD_LIBRARY_PATH="$LOCAL_LIB:${LD_LIBRARY_PATH:-}"

[ -x "$QEMU" ] || { echo "FATAL: QEMU not executable: $QEMU (set QEMU=)" >&2; exit 2; }
[ -f "$BOOTER" ] || { echo "FATAL: booter not found: $BOOTER (set BOOTER= or FW_DIR=)" >&2; exit 2; }
[ -f "$AUX" ] || { echo "FATAL: aux image not found: $AUX (set AUX=)" >&2; exit 2; }
[ -f "$DISK" ] || { echo "FATAL: disk image not found: $DISK (set DISK=)" >&2; exit 2; }

mkdir -p "$BUNDLE/logs" "$BUNDLE/work"

if [ "$COPYAUX" = 1 ]; then
  AUXRUN="$BUNDLE/work/aux-$STAMP.img"
  cp --sparse=always "$AUX" "$AUXRUN"
else
  AUXRUN="$AUX"
fi

rm -f "$QMP"

ARGS=(
  -monitor none
  -m "$RAM"
  -accel "$ACCEL"
  -cpu "$CPU"
  -smp "$CPUS"
  -display none
  -M "vmapple,uuid=$UUID,gfx-device=$GFX"
  -bios "$BOOTER"
  -drive "file=$AUXRUN,if=pflash,format=raw"
  -drive "file=$DISK,if=pflash,format=raw"
  -drive "file=$AUXRUN,if=none,id=aux,format=raw"
  -drive "file=$DISK,if=none,id=root,format=raw"
  -device vmapple-virtio-blk-pci,variant=aux,drive=aux
  -device vmapple-virtio-blk-pci,variant=root,drive=root
  -netdev user,id=net0,ipv6=off,hostfwd=tcp::${SSH_PORT:-2222}-:22,hostfwd=tcp::${VNC_PORT:-5901}-:5900
  -device virtio-net-pci,netdev=net0,mac=52:54:00:76:61:70
  -qmp "unix:$QMP,server=on,wait=off"
)
# With SERIAL_SOCK=<path> the guest serial console is attached to a unix
# socket (bidirectional) while the chardev logfile still captures everything,
# matching the old -serial file: behavior.
if [ -n "${SERIAL_SOCK:-}" ]; then
  rm -f "$SERIAL_SOCK"
  ARGS+=(-chardev "socket,id=ser0,path=$SERIAL_SOCK,server=on,wait=off,logfile=$LOG,logappend=on")
  ARGS+=(-serial chardev:ser0)
else
  ARGS+=(-serial "file:$LOG")
fi
[ -n "$GDBPORT" ] && ARGS+=(-gdb "tcp::$GDBPORT")
[ "$PAUSE" = 1 ] && ARGS+=(-S)
[ "$NOREB" = 1 ] && ARGS+=(-no-reboot)
[ -n "$EXTRA_D" ] && ARGS+=(-d "$EXTRA_D")
[ -n "$TRACE" ] && ARGS+=(-trace "$TRACE")
[ -n "$GLOBALS" ] && ARGS+=(-global "$GLOBALS")

echo "accel  : $ACCEL  cpu=$CPU cpus=$CPUS ram=$RAM"
echo "booter : $BOOTER"
echo "aux    : $AUXRUN"
echo "disk   : $DISK"
echo "serial : $LOG"
echo "qemulog: $ERRLOG"
echo "qmp    : $QMP"
echo "gdb    : ${GDBPORT:-none}  pause=$PAUSE runsec=$RUNSEC"

if [ "$RUNSEC" != 0 ]; then
  timeout --foreground "$RUNSEC" "$QEMU" "${ARGS[@]}" >"$ERRLOG" 2>&1
  rc=$?
  echo "=== qemu exit rc=$rc after ${RUNSEC}s ==="
else
  "$QEMU" "${ARGS[@]}" >"$ERRLOG" 2>&1
  rc=$?
  echo "=== qemu exit rc=$rc ==="
fi
echo "=== serial tail ==="
tail -c 2000 "$LOG" 2>/dev/null
exit $rc
