#!/usr/bin/env bash
# launch/inject/inject-xnu-kvm.sh - run the XNU handoff injector.
# Wraps inject-xnu-kvm.gdb in batch-mode gdb; the QEMU_27ON86_* variables
# (GDB port, boot args, QMP socket, PAC options) must be in the environment.
set -euo pipefail

# gdb's embedded Python imports apple_device_tree.py from this directory; without
# this it drops a __pycache__/*.pyc (binary) into the bundle on every boot.
export PYTHONDONTWRITEBYTECODE=1

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${QEMU_27ON86_GDB_PORT:?set QEMU_27ON86_GDB_PORT}"
: "${QEMU_27ON86_XNU_BOOT_ARGS:?set QEMU_27ON86_XNU_BOOT_ARGS}"
: "${QEMU_27ON86_QMP_SOCKET:?set QEMU_27ON86_QMP_SOCKET}"
export VMAPPLE_INJECT_SCRIPT_DIR="$script_dir"
exec "${GDB_BIN:-gdb}" -nx -q -batch -x "$script_dir/inject-xnu-kvm.gdb"
