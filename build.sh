#!/bin/bash
# build.sh - build the macOS (vmapple) + Reims vGPU QEMU on a non-Apple
# aarch64 Linux host, from this bundle.
#
#   src/metal2vulkan             imbushuo/metal2vulkan @ 0a44257f (binwang/macos15-vm-paired-changes)
#   src/reims-vgpu               imbushuo/reims-vgpu   @ d55da3dc (binwang/macos15guest-vulkan-ri)
#   src/reims-vgpu/vendor/qemu   imbushuo/qemu         @ 38818b7e (binwang/kvm-improvement)
#   kmod/                        DenrianWeiss/accelerated-macos-for-w515y @ 8f471819 (KVM shims)
#
# Patches applied after cloning (all idempotent, re-running skips what is done):
#
#   patches/qemu/*.patch        -> src/reims-vgpu/vendor/qemu  (the tree that is built)
#   patches/reims-vgpu/*.patch  -> src/reims-vgpu             (the Rust vGPU device)
#   patches/kmod/*.patch        -> this bundle root           (adds kmod/hcr_probe/)
#
# Artifact:
#   src/reims-vgpu/vendor/qemu/build/qemu-system-aarch64
# which statically links crates/reims-vgpu (Rust) -> metal2vulkan (Rust), with
# the Vulkan + winit host-window backend. The launcher in launch/ uses it.
#
# usage:
#   ./build.sh                    # deps check + clone + patch + configure + ninja + verify
#   RECLONE=1 ./build.sh          # throw away src/ and kmod/ and clone again
#   JOBS=8 ./build.sh
#   KMOD_CHECK=1 ./build.sh       # additionally compile-check the kernel modules
#   PATCHES_DIR=/nonexistent ./build.sh   # build an unpatched upstream tree (A/B runs)
#
# Environment overrides:
#   SRC PATCHES_DIR KMOD_DIR LOG_DIR CC_BIN CXX_BIN
#   GLIB_PC_DIR NETTLE_PC_DIR QEMU_PYTHON JOBS RECLONE APPLY_PATCHES KMOD_PATCH
#   KMOD_CHECK CLONE_STANDALONE_QEMU METAL2VULKAN_REV REIMS_REV QEMU_REV QEMU_BRANCH
#   KMOD_REV
echo "If you paid for this, you have been scammed. This bundle is for research purposes only."
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SRC:-$HERE/src}"
PATCHES_DIR="${PATCHES_DIR:-$HERE/patches}"
KMOD_DIR="${KMOD_DIR:-$HERE/kmod}"
LOG_DIR="${LOG_DIR:-$HERE/logs}"

# --- pins -------------------------------------------------------------------
METAL2VULKAN_REV="${METAL2VULKAN_REV:-0a44257f1f698e75e0852212de4308a1b1b6addd}"
REIMS_REV="${REIMS_REV:-d55da3dc1db3b11e764a343fce37ecca9c142965}"
QEMU_REV="${QEMU_REV:-38818b7e5a65b1bde46f28a840d74ce5a8a20cab}"
QEMU_BRANCH="${QEMU_BRANCH:-binwang/kvm-improvement}"
KMOD_REV="${KMOD_REV:-8f47181929d8091ef08f9faf52eb8fab51ae919f}"

git_url() {  # git_url <owner/repo>
  printf 'https://github.com/%s.git\n' "$1"
}

# --- host toolchain ---------------------------------------------------------
# QEMU 11 wants gcc >= 10.4 and glib >= 2.66. The pinned branches are built with
# gcc-10 (10.3.0, accepted through patches/qemu/0002) and a locally installed
# glib 2.74 on Kylin V10, whose system gcc is 9.3 and glib 2.64.
CC_BIN="${CC_BIN:-gcc-10}"
CXX_BIN="${CXX_BIN:-g++-10}"
command -v "$CC_BIN" >/dev/null 2>&1 || CC_BIN=gcc
command -v "$CXX_BIN" >/dev/null 2>&1 || CXX_BIN=g++

# pkgconfig dirs for the locally built glib / nettle; override to match your host.
GLIB_PC_DIR="${GLIB_PC_DIR:-$HOME/.local/lib/usr/local/lib/aarch64-linux-gnu/pkgconfig}"
# nettle is mandatory: with no crypto library visible, QEMU 11 silently builds
# crypto/cipher-stub.c.inc and every vmapple AES operation fails, which hangs
# the macOS guest in AppleVPKeyStore before launchd. gnutls stays disabled.
NETTLE_PC_DIR="${NETTLE_PC_DIR:-$HOME/.local/lib/lib64/pkgconfig}"
[ -f "$NETTLE_PC_DIR/nettle.pc" ] || NETTLE_PC_DIR="$HOME/.local/lib/pkgconfig"

# QEMU's mkvenv needs a Python whose ensurepip provides setuptools >= 64
# (PEP 660 editable installs). A system python3.9 with setuptools 45 fails, so
# prefer a newer interpreter if one is present.
QEMU_PYTHON="${QEMU_PYTHON:-}"
if [ -z "$QEMU_PYTHON" ]; then
  for cand in "$HOME/bin/python3.14/bin/python3.14" python3.14 python3.12 python3; do
    if command -v "$cand" >/dev/null 2>&1; then QEMU_PYTHON="$cand"; break; fi
  done
fi

JOBS="${JOBS:-$(nproc)}"
RECLONE="${RECLONE:-0}"
APPLY_PATCHES="${APPLY_PATCHES:-1}"
KMOD_PATCH="${KMOD_PATCH:-1}"
KMOD_CHECK="${KMOD_CHECK:-0}"
# The built tree is src/reims-vgpu/vendor/qemu; a standalone src/qemu checkout at
# the same commit is only useful for reading patches, so it is off by default.
CLONE_STANDALONE_QEMU="${CLONE_STANDALONE_QEMU:-0}"

QEMU_SRC="$SRC/reims-vgpu/vendor/qemu"
QEMU_BIN="$QEMU_SRC/build/qemu-system-aarch64"

log() { printf '\n=== %s ===\n' "$*"; }
die() { echo "FATAL: $*" >&2; exit 1; }

# --- phase 0: dependency check ----------------------------------------------
log "phase 0: dependency check"
missing=0
need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "  MISSING tool: $1 ($2)"; missing=1
  fi
}
need git        "clone the pinned repositories"
need patch      "apply the patches in patches/"
need cargo      "build the reims-vgpu / metal2vulkan Rust crates (rustup.rs)"
need ninja      "run the QEMU build (or use make)"
need pkg-config "find glib / nettle"
need make       "kernel modules and QEMU's configure"
need "$CC_BIN"  "C compiler, gcc >= 10.3 (see README.md)"
need "$CXX_BIN" "C++ compiler"
[ -d "$GLIB_PC_DIR" ] || { echo "  MISSING glib pkgconfig dir: $GLIB_PC_DIR (see README.md, GLIB_PC_DIR)"; missing=1; }
[ -f "$NETTLE_PC_DIR/nettle.pc" ] || { echo "  MISSING nettle.pc in $NETTLE_PC_DIR (see README.md, NETTLE_PC_DIR)"; missing=1; }
[ -n "$QEMU_PYTHON" ] && [ -x "$(command -v "$QEMU_PYTHON" || true)" ] \
  || { echo "  MISSING python3 (>= 3.10 with ensurepip; see README.md, QEMU_PYTHON)"; missing=1; }
[ "$missing" = 0 ] || die "install the missing dependencies listed above, then re-run"
echo "  cc=$CC_BIN cxx=$CXX_BIN python=$QEMU_PYTHON jobs=$JOBS"

# --- phase 1: repositories --------------------------------------------------
ensure_repo() {  # ensure_repo <dir> <owner/repo> <rev> [branch]
  local dir="$1" slug="$2" rev="$3" branch="${4:-}"
  if [ ! -d "$dir/.git" ]; then
    log "clone $slug -> $dir"
    if [ -n "$branch" ]; then
      git clone --branch "$branch" "$(git_url "$slug")" "$dir"
    else
      git clone "$(git_url "$slug")" "$dir"
    fi
  fi
  git -C "$dir" rev-parse --verify --quiet "$rev^{commit}" >/dev/null \
    || git -C "$dir" fetch origin
  git -C "$dir" checkout --quiet "$rev"
  local head; head="$(git -C "$dir" rev-parse HEAD)"
  [ "$head" = "$rev" ] || die "$dir at $head, expected $rev"
  echo "  $slug @ $head"
}

if [ "$RECLONE" = 1 ]; then
  log "RECLONE=1: removing $SRC and $KMOD_DIR"
  rm -rf "$SRC" "$KMOD_DIR"
fi
mkdir -p "$SRC" "$LOG_DIR"

log "repositories (pinned)"
ensure_repo "$SRC/metal2vulkan" "imbushuo/metal2vulkan" "$METAL2VULKAN_REV" "binwang/macos15-vm-paired-changes"
ensure_repo "$SRC/reims-vgpu"   "imbushuo/reims-vgpu"   "$REIMS_REV"        "binwang/macos15guest-vulkan-ri"
# kmod/ was vendored in older bundles; replace a non-git copy with the clone.
if [ -d "$KMOD_DIR" ] && [ ! -d "$KMOD_DIR/.git" ]; then
  log "replacing vendored $KMOD_DIR with a clone of DenrianWeiss/accelerated-macos-for-w515y"
  rm -rf "$KMOD_DIR"
fi
ensure_repo "$KMOD_DIR"         "DenrianWeiss/accelerated-macos-for-w515y" "$KMOD_REV"
if [ "$CLONE_STANDALONE_QEMU" = 1 ]; then
  ensure_repo "$SRC/qemu"       "imbushuo/qemu"         "$QEMU_REV"         "$QEMU_BRANCH"
fi

# reims-vgpu's .gitmodules names an unreachable host for vendor/qemu, but the
# recorded gitlink is the same commit as the standalone checkout, so
# materialise it from the mirror and a plain `git status` in reims-vgpu stays
# clean.
if [ ! -d "$QEMU_SRC/.git" ] || [ "$(git -C "$QEMU_SRC" rev-parse HEAD 2>/dev/null)" != "$QEMU_REV" ]; then
  log "populate reims-vgpu/vendor/qemu @ $QEMU_REV"
  rm -rf "$QEMU_SRC"
  git clone --branch "$QEMU_BRANCH" "$(git_url imbushuo/qemu)" "$QEMU_SRC"
  git -C "$QEMU_SRC" checkout --quiet "$QEMU_REV"
fi
[ "$(git -C "$QEMU_SRC" rev-parse HEAD)" = "$QEMU_REV" ] || die "vendor/qemu is not at $QEMU_REV"

# --- phase 2: patches -------------------------------------------------------
# Is the whole series already in the tree? Patches in a series may overlap
# (patches/qemu/0005 rewrites regions 0004 introduced in hw/vmapple/aes.c), so a
# single patch cannot always be reversed on its own even though the series as a
# whole is applied. Reversing the series in reverse order, on a throwaway copy of
# the files it touches, answers the question without touching the tree.
series_already_applied() {  # series_already_applied <tree> <patchdir>
  local tree="$1" dir="$2" tmp f p rc=0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/patchstate.XXXXXX")"
  for f in $(sed -n 's|^+++ b/||p' "$dir"/*.patch | sort -u); do
    [ -f "$tree/$f" ] || { rc=1; break; }
    mkdir -p "$tmp/$(dirname "$f")"
    cp -p "$tree/$f" "$tmp/$f"
  done
  if [ "$rc" = 0 ]; then
    for p in $(ls -r "$dir"/*.patch 2>/dev/null); do
      patch -p1 -R -s --batch -f -d "$tmp" < "$p" >/dev/null 2>&1 || { rc=1; break; }
    done
  fi
  rm -rf "$tmp"
  return $rc
}

apply_patch_dir() {  # apply_patch_dir <tree> <patchdir>
  local tree="$1" dir="$2" p
  [ -d "$dir" ] || return 0
  if series_already_applied "$tree" "$dir"; then
    echo "  already applied: every patch in $(basename "$dir")/"
    return 0
  fi
  for p in "$dir"/*.patch; do
    [ -e "$p" ] || continue
    if patch -p1 --dry-run -s -f -d "$tree" < "$p" >/dev/null 2>&1; then
      echo "  apply: $(basename "$p")"
      patch -p1 --batch --no-backup-if-mismatch -s -d "$tree" < "$p" \
        || die "could not apply $(basename "$p") to $tree"
    elif patch -p1 -R --dry-run -s -f -d "$tree" < "$p" >/dev/null 2>&1; then
      echo "  already applied: $(basename "$p")"
    else
      die "$(basename "$p") neither applies nor looks applied to $tree: the tree may be patched differently or half-patched (RECLONE=1 clones again from scratch)"
    fi
  done
}

if [ "$APPLY_PATCHES" = 1 ]; then
  log "patches: reims-vgpu"
  apply_patch_dir "$SRC/reims-vgpu" "$PATCHES_DIR/reims-vgpu"
  log "patches: qemu"
  apply_patch_dir "$QEMU_SRC" "$PATCHES_DIR/qemu"
  if [ "$KMOD_PATCH" = 1 ]; then
    log "patches: kernel modules (adds kmod/hcr_probe/)"
    apply_patch_dir "$HERE" "$PATCHES_DIR/kmod"
  fi
else
  log "APPLY_PATCHES=0: building the unpatched upstream trees"
fi

# --- phase 3: configure -----------------------------------------------------
export CC="$CC_BIN" CXX="$CXX_BIN"
export PKG_CONFIG_PATH="$GLIB_PC_DIR:$NETTLE_PC_DIR${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

STAMP="vmapple:aarch64-softmmu:kvm:vulkan:nettle:$REIMS_REV"
if [ ! -f "$QEMU_SRC/build/build.ninja" ] || [ "$(cat "$QEMU_SRC/build/.build-stamp" 2>/dev/null || true)" != "$STAMP" ]; then
  log "configure (stamp changed or fresh tree)"
  rm -rf "$QEMU_SRC/build"
  ( cd "$QEMU_SRC" && ./configure \
      --python="$QEMU_PYTHON" \
      --target-list=aarch64-softmmu \
      --enable-kvm \
      --enable-gtk \
      --enable-nettle \
      --disable-gnutls \
      --disable-docs \
      --disable-tools \
      --disable-bsd-user \
      --disable-linux-user \
      -Dreims_vgpu_backend=vulkan ) > "$LOG_DIR/configure.log" 2>&1 \
    || { tail -40 "$LOG_DIR/configure.log" >&2; die "configure failed (full log: $LOG_DIR/configure.log)"; }
  printf '%s\n' "$STAMP" > "$QEMU_SRC/build/.build-stamp"
else
  log "already configured for $STAMP; skipping configure"
fi

# --- phase 4: build ---------------------------------------------------------
log "ninja -C build qemu-system-aarch64 (links reims-vgpu/metal2vulkan, JOBS=$JOBS)"
ninja -C "$QEMU_SRC/build" -j "$JOBS" qemu-system-aarch64 2>&1 | tee "$LOG_DIR/ninja.log"
[ -x "$QEMU_BIN" ] || die "build produced no $QEMU_BIN"

# --- phase 5: verify --------------------------------------------------------
log "verify"
"$QEMU_BIN" --version | head -1
"$QEMU_BIN" -M help 2>/dev/null | grep -i vmapple || die "vmapple machine missing"
"$QEMU_BIN" -device reims-vgpu-mmio,help >/dev/null 2>&1 \
  && echo "reims-vgpu-mmio: registered" || die "reims-vgpu-mmio not registered"
"$QEMU_BIN" -accel help 2>/dev/null | grep -qi kvm && echo "kvm: available" || echo "kvm: NOT listed"
# qcrypto must not be the stub: the vmapple AES device (AppleVPKeyStore / xART)
# hard-depends on it, and the stub fails every cipher op, hanging the guest
# mid-boot.
if ldd "$QEMU_BIN" | grep -qE 'libnettle|libgcrypt|libgnutls'; then
  echo "qcrypto: real cipher backend linked"
else
  die "qemu-system-aarch64 has no crypto backend linked (cipher stub); check nettle"
fi

# --- phase 6: kernel modules (optional compile check) -----------------------
if [ "$KMOD_CHECK" = 1 ]; then
  KBUILD="/lib/modules/$(uname -r)/build"
  log "compile-check the kernel modules against $KBUILD"
  [ -d "$KBUILD" ] || die "kernel headers not found: $KBUILD (install linux-headers-$(uname -r))"
  for sub in extra kvm_isar1_fix hcr_probe; do
    [ -d "$KMOD_DIR/$sub" ] || { echo "  skip $sub (not present)"; continue; }
    make -C "$KBUILD" M="$KMOD_DIR/$sub" modules > "$LOG_DIR/kmod-$sub.log" 2>&1 \
      || { tail -20 "$LOG_DIR/kmod-$sub.log" >&2; die "kmod $sub failed to compile"; }
    echo "  $sub: OK"
  done
else
  echo "note: kernel modules not compile-checked (set KMOD_CHECK=1 to do so)"
fi

cat <<EOF

QEMU built:  $QEMU_BIN
Kernel modules: build them before booting (see README.md):
  make -C $KMOD_DIR            KDIR=/lib/modules/\$(uname -r)/build
  make -C $KMOD_DIR/hcr_probe  KDIR=/lib/modules/\$(uname -r)/build
Boot:  $HERE/launch/launch-macos-gui.sh   (BOOTER/AUX/DISK point at your images)
EOF
