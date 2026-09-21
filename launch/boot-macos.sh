#!/bin/bash
# launch/boot-macos.sh - end-to-end vmapple macOS boot (two-stage launcher).
#
# Mirrors the reference project's scripts/launch-gui-kvm.sh:
#   1. start QEMU paused with a gdbstub and a QMP socket (via ./run-vm.sh)
#   2. run the XNU handoff injector (inject/inject-xnu-kvm.gdb):
#        - inject XNU boot arguments + CSR config into boot_args
#        - patch the pre-indexed GIC MMIO store that KVM cannot emulate
#        - seed the vmapple PAC default keys
#        - rewrite the DT cpu frequency properties to the host CNTFRQ
#          (a 1 GHz host timer vs the 24 MHz the DT claims makes guest time
#          run ~41.7x fast; TIMEBASE_FREQ=<hz> overrides, 0 skips the patch)
#   3. let QEMU run to completion
#
# Everything written stays inside the bundle (../logs, ../work).
#
# Usage:
#   ./boot-macos.sh                 # boot until the guest stops (Ctrl-C to stop)
#   RUNSEC=120 ./boot-macos.sh      # kill after 120s
#   GDB_PORT=1235 ./boot-macos.sh
#   XNU_BOOT_ARGS='-v serial=11 debug=0x14c' ./boot-macos.sh
#   NOINJECT=1 ./boot-macos.sh      # skip the injector (baseline A/B run)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"     # bundle/launch
BUNDLE="$(cd "$HERE/.." && pwd)"
cd "$HERE"

GDB_PORT=${GDB_PORT:-1234}
RUNSEC=${RUNSEC:-0}
XNU_BOOT_ARGS=${XNU_BOOT_ARGS:--v serial=11 debug=0x14c}
CSR_CONFIG=${CSR_CONFIG:-0x2}
NOINJECT=${NOINJECT:-0}
INJECT_TIMEOUT=${INJECT_TIMEOUT:-240}   # give up if the handoff is never reached
STAMP=$(date +%Y%m%d-%H%M%S)
LOG=${LOG:-$BUNDLE/logs/serial-$STAMP.log}
ERRLOG=${ERRLOG:-$BUNDLE/logs/qemu-$STAMP.log}
QMP=${QMP:-$BUNDLE/work/qmp-$STAMP.sock}
INJLOG=${INJLOG:-$BUNDLE/logs/inject-$STAMP.log}

mkdir -p "$BUNDLE/logs" "$BUNDLE/work"
rm -f "$QMP"

qemu_pid=
stop_vm() {
  # QEMU runs as a child of run-vm.sh in its own process group, so kill the
  # whole group: killing only the wrapper leaves QEMU holding 2222/5901.
  if [ -n "$qemu_pid" ] && kill -0 "$qemu_pid" 2>/dev/null; then
    kill -INT -- "-$qemu_pid" 2>/dev/null
    sleep 0.5
    kill -TERM -- "-$qemu_pid" 2>/dev/null
    wait "$qemu_pid" 2>/dev/null
  fi
}
trap stop_vm EXIT HUP INT TERM

echo "=== starting QEMU (paused, gdb :$GDB_PORT) ==="
PAUSE=1 GDBPORT="$GDB_PORT" NOREB="${NOREB:-1}" RUNSEC="$RUNSEC" \
  LOG="$LOG" ERRLOG="$ERRLOG" QMP="$QMP" \
  setsid ./run-vm.sh &
qemu_pid=$!

for _ in $(seq 1 300); do
  kill -0 "$qemu_pid" 2>/dev/null || { echo "FATAL: QEMU exited before QMP appeared"; exit 1; }
  [ -S "$QMP" ] && break
  sleep 0.1
done
[ -S "$QMP" ] || { echo "FATAL: QMP socket did not appear: $QMP"; exit 1; }
echo "=== QMP ready: $QMP ==="

if [ "$NOINJECT" = 1 ]; then
  echo "=== NOINJECT=1: continuing without the XNU handoff patch ==="
  python3 - "$QMP" <<'PY' || true
import json, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1]); f = s.makefile("rwb", buffering=0)
f.readline()
f.write(json.dumps({"execute": "qmp_capabilities"}).encode() + b"\n"); f.readline()
f.write(json.dumps({"execute": "cont"}).encode() + b"\n"); f.readline()
PY
else
  echo "=== running XNU handoff injector (boot args: $XNU_BOOT_ARGS) ==="
  QEMU_27ON86_GDB_PORT="$GDB_PORT" \
  QEMU_27ON86_XNU_BOOT_ARGS="$XNU_BOOT_ARGS" \
  QEMU_27ON86_CSR_CONFIG="$CSR_CONFIG" \
  QEMU_27ON86_TIMEBASE_FREQ="${TIMEBASE_FREQ:-1000000000}" \
  QEMU_27ON86_KVM_MMIO_PATCH=1 \
  QEMU_27ON86_ISAR1_PATCH="${ISAR1_PATCH:-}" \
  QEMU_27ON86_QMP_SOCKET="$QMP" \
  QEMU_27ON86_PAC_TRACE="${QEMU_27ON86_PAC_TRACE:-}" \
  QEMU_27ON86_PAC_FIX="${QEMU_27ON86_PAC_FIX:-}" \
  QEMU_27ON86_PAC_TRAMPOLINE="${QEMU_27ON86_PAC_TRAMPOLINE:-}" \
  QEMU_27ON86_KERNEL_DUMP="${QEMU_27ON86_KERNEL_DUMP:-}" \
  QEMU_27ON86_PAC_DEFAULTS="${QEMU_27ON86_PAC_DEFAULTS:-}" \
  QEMU_27ON86_PAC_FORENSICS="${QEMU_27ON86_PAC_FORENSICS:-}" \
    timeout --foreground "$INJECT_TIMEOUT" "$HERE/inject/inject-xnu-kvm.sh" 2>&1 | tee "$INJLOG"
  inj_rc=${PIPESTATUS[0]}
  echo "=== injector rc=$inj_rc (log: $INJLOG) ==="
  if [ "$inj_rc" != 0 ]; then
    echo "FATAL: XNU injector failed; stopping QEMU (serial: $LOG, qemulog: $ERRLOG)"
    stop_vm
    qemu_pid=
    exit 1
  fi
fi

echo "=== waiting for QEMU ==="
wait "$qemu_pid"
rc=$?
qemu_pid=
echo "=== qemu exit rc=$rc ==="
echo "=== serial tail ==="
tail -c 4000 "$LOG" 2>/dev/null
exit $rc
