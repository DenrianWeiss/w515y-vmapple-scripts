python
import gdb
import json
import os
import socket
import struct
import sys
import tempfile


HANDOFF_PC = 0xACA00000
COMMAND_LINE_OFFSET = 108
COMMAND_LINE_SIZE = 608
DEVICE_TREE_POINTER_OFFSET = 96
VIRTUAL_BASE_OFFSET = 8
PHYSICAL_BASE_OFFSET = 16
KVM_MMIO_SIGNATURE = struct.pack(
    "<IIII", 0x12AFC009, 0xB8080D09, 0x52A10009, 0xB9008109
)
KVM_MMIO_FIRST = struct.pack("<I", 0xB9008109)
KVM_MMIO_SECOND = struct.pack("<I", 0xB9010109)


def required(name):
    value = os.environ.get(name)
    if not value:
        raise gdb.GdbError(f"set {name}")
    return value


port = required("QEMU_27ON86_GDB_PORT")
command_line = required("QEMU_27ON86_XNU_BOOT_ARGS").encode()
qmp_socket = required("QEMU_27ON86_QMP_SOCKET")
if b"\0" in command_line or len(command_line) >= COMMAND_LINE_SIZE:
    raise gdb.GdbError("invalid XNU command line")

gdb.execute("set architecture aarch64", to_string=True)
gdb.execute(f"target remote :{port}", to_string=True)
# gdb 9.2 exposes no hardware-breakpoint constant and its gdb.breakpoints()
# does not list CLI-created breakpoints, so drive it entirely through the CLI.
gdb.execute(f"hbreak *{HANDOFF_PC:#x}", to_string=True)
gdb.execute("ignore 1 1", to_string=True)
gdb.execute("continue", to_string=True)
if int(gdb.parse_and_eval("$pc")) != HANDOFF_PC:
    raise gdb.GdbError("unexpected XNU handoff address")

boot_args = int(gdb.parse_and_eval("$x1"))
inferior = gdb.selected_inferior()
revision, version = struct.unpack("<HH", bytes(inferior.read_memory(boot_args, 4)))
if (revision, version) != (2, 2):
    raise gdb.GdbError(f"unexpected boot_args revision/version {revision}/{version}")
payload = (command_line + b"\0").ljust(COMMAND_LINE_SIZE, b"\0")
inferior.write_memory(boot_args + COMMAND_LINE_OFFSET, payload)
print(f"injected XNU boot arguments: {command_line.decode(errors='replace')}")

virtual_base, physical_base = struct.unpack(
    "<QQ", bytes(inferior.read_memory(boot_args + VIRTUAL_BASE_OFFSET, 16))
)

device_tree_virtual, device_tree_length = struct.unpack(
    "<QI", bytes(inferior.read_memory(boot_args + DEVICE_TREE_POINTER_OFFSET, 12))
)
device_tree = device_tree_virtual - virtual_base + physical_base
flattened = bytearray(inferior.read_memory(device_tree, device_tree_length))
sys.path.insert(0, required("VMAPPLE_INJECT_SCRIPT_DIR"))
import apple_device_tree
root = apple_device_tree.parse(flattened)
tree_dirty = False

# The host generic timer runs at 1 GHz (CNTFRQ_EL0), but the iBoot-built DT
# still claims 24 MHz and this kernel cannot virtualize the counter, so guest
# time would run ~41.7x fast. Rewrite the cpu frequency properties in place.
timebase_freq = int(os.environ.get("QEMU_27ON86_TIMEBASE_FREQ", "1000000000"))
patched = 0
if timebase_freq:
    cpus = apple_device_tree.child_named(flattened, root, "cpus")
    for cpu in cpus["children"]:
        if "state" in cpu["properties"]:
            state = apple_device_tree.property_value(flattened, cpu, "state")
            if state != b"running\0":
                continue
        for name in ("timebase-frequency", "clock-frequency", "bus-frequency",
                     "memory-frequency", "peripheral-frequency", "fixed-frequency"):
            if name not in cpu["properties"]:
                continue
            _, value_offset, length = cpu["properties"][name]
            if length == 8:
                struct.pack_into("<Q", flattened, value_offset, timebase_freq)
            elif length == 4:
                struct.pack_into("<I", flattened, value_offset, timebase_freq)
            else:
                continue
            patched += 1
if patched:
    tree_dirty = True
    print(f"patched {patched} cpu frequency properties to {timebase_freq} Hz")

csr_text = os.environ.get("QEMU_27ON86_CSR_CONFIG")
if csr_text:
    csr_config = int(csr_text, 0)
    chosen = apple_device_tree.child_named(flattened, root, "chosen")
    asmb = apple_device_tree.child_named(flattened, chosen, "asmb")
    old_name = "lp-sip0" if "lp-sip0" in asmb["properties"] else "lp-stng"
    apple_device_tree.replace_property(
        flattened, asmb, old_name, "lp-sip0", struct.pack("<Q", csr_config)
    )
    tree_dirty = True
    print(f"injected XNU CSR configuration: {csr_config:#x}")

if tree_dirty:
    inferior.write_memory(device_tree, flattened)

qmp = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
qmp.settimeout(30)
qmp.connect(qmp_socket)
qmp_file = qmp.makefile("rwb", buffering=0)


def qmp_call(command, arguments=None):
    request = {"execute": command}
    if arguments is not None:
        request["arguments"] = arguments
    qmp_file.write(json.dumps(request).encode() + b"\n")
    while True:
        response = json.loads(qmp_file.readline())
        if "return" in response:
            return response["return"]
        if "error" in response:
            raise gdb.GdbError(f"QMP {command} failed: {response['error']}")


json.loads(qmp_file.readline())
qmp_call("qmp_capabilities")
print(f"boot_args va={virtual_base:#x} pa={physical_base:#x}")
dump = tempfile.NamedTemporaryFile(prefix="vmapple-xnu-", suffix=".bin", delete=False)
dump.close()
try:
    qmp_call("pmemsave", {
        "val": physical_base,
        "size": 128 * 1024 * 1024,
        "filename": dump.name,
    })
    with open(dump.name, "rb") as dumped:
        window = dumped.read()
    # Keep the dump when asked: the loaded kernelcache is the only copy of the
    # guest kernel available on this host, so it is the reference for locating
    # XNU functions (e.g. handle_pac_fail) by string cross-reference.
    keep = os.environ.get("QEMU_27ON86_KERNEL_DUMP")
    if keep:
        with open(keep, "wb") as out:
            out.write(window)
        with open(keep + ".info", "w") as out:
            out.write(f"virtual_base={virtual_base:#x}\n")
            out.write(f"physical_base={physical_base:#x}\n")
            out.write(f"size={len(window)}\n")
        print(f"saved {len(window)} bytes of guest RAM to {keep}")
finally:
    os.unlink(dump.name)
    qmp_file.close()
    qmp.close()

matches = []
start = 0
while True:
    found = window.find(KVM_MMIO_SIGNATURE, start)
    if found < 0:
        break
    matches.append(physical_base + found)
    start = found + 1
if len(matches) != 1:
    raise gdb.GdbError(
        f"expected one XNU GIC MMIO instruction sequence, found {len(matches)}"
    )
patch_address = matches[0] + 4
inferior.write_memory(patch_address, KVM_MMIO_FIRST)
inferior.write_memory(patch_address + 8, KVM_MMIO_SECOND)
print("patched XNU pre-indexed GIC MMIO store for KVM emulation")

# Optional experimental patch: change the instruction through which XNU
# publishes ID_AA64ISAR1_EL1 to EL0 features. Setting the immediate to 0
# advertises no pointer authentication, which makes the guest's PAC/AUT
# instructions execute as NOPs (the lenient TCG "accept and strip" contract).
isar1_imm = os.environ.get("QEMU_27ON86_ISAR1_PATCH")
if isar1_imm:
    # Mind the encoding: mrs x12, ID_AA64ISAR1_EL1 = 0xD538062C.
    # 0xD538060C is ID_AA64ISAR0_EL1 (CRm=6, op2=0); an earlier revision used
    # it by mistake and patched ISAR0 instead of ISAR1 (checked with
    # aarch64-linux-gnu-as).
    MRS_X12_ISAR1 = struct.pack("<I", 0xD538062C)  # mrs x12, ID_AA64ISAR1_EL1
    hits = []
    start = 0
    while True:
        found = window.find(MRS_X12_ISAR1, start)
        if found < 0:
            break
        hits.append(found)
        start = found + 1
    if len(hits) != 1:
        print(f"ISAR1 patch: expected 1 'mrs x12' site, found {len(hits)}; skipped")
    else:
        imm = int(isar1_imm, 0) & 0xFFFF
        movz = 0xD2800000 | (imm << 5) | 12  # movz x12, #imm
        inferior.write_memory(physical_base + hits[0], struct.pack("<I", movz))
        print(f"patched XNU ID_AA64ISAR1_EL1 publication -> mov x12, #{imm:#x}")

# Optional diagnostic: catch the guest's first EL0 PAC-authentication
# failures.  XNU's handle_pac_fail() raises
# EXC_BAD_ACCESS|EXC_PTRAUTH_BIT with code EXC_ARM_PAC_FAIL for user faults,
# which bsd/uxkern/ux_exception.c turns into SIGBUS; that is the "subcode 0xa"
# that kills launchd.  The function is located by its exact 24-byte prologue
# inside the RAM window instead of a fixed image offset: the prologue address
# is booter-layout dependent (the kernel image is not based at boot_args'
# physical_base).  On a hit x0 = arm_saved_state_t *, x1 = ESR_EL1, and the
# faulting user state is read out of the saved-state object.
pac_trace = os.environ.get("QEMU_27ON86_PAC_TRACE")
pac_fix = os.environ.get("QEMU_27ON86_PAC_FIX")
# One-shot in-guest trampoline (prebuilt blob passed via
# QEMU_27ON86_PAC_TRAMPOLINE): replaces handle_pac_fail
# wholesale with a "strip PAC and continue" stub; same semantics as
# QEMU_27ON86_PAC_FIX but without stopping gdb on every fault.
pac_tramp = os.environ.get("QEMU_27ON86_PAC_TRAMPOLINE")
if pac_fix and not pac_trace:
    pac_trace = "0"          # run the handle_pac_fail locator only
if pac_tramp and not pac_trace:
    pac_trace = "0"          # run the handle_pac_fail locator only
# The default-keys seed (below) also needs the locator; run it by default so a
# plain ./boot-macos.sh gets the fix out of the box.
if os.environ.get("QEMU_27ON86_PAC_DEFAULTS", "1") != "0" and not pac_trace:
    pac_trace = "0"
if pac_trace:
    HPF_SIG = bytes.fromhex("7f2303d5ff4302d1f44f07a9fd7b08a9fd030291f40301aa")
    hits = []
    start = 0
    while True:
        found = window.find(HPF_SIG, start)
        if found < 0:
            break
        hits.append(found)
        start = found + 1

    # The prologue alone is not unique (four functions share it).  The real
    # handle_pac_fail() is the one whose body loads the address of its own
    # "PAC failure (ESR 0x%x) from 32-bit state" format string, so pick the
    # prologue whose first instructions contain an adrp/add pair targeting
    # that string.
    def sx21(v):
        v &= 0x1fffff
        return v - (1 << 21) if v & (1 << 20) else v

    def u32(off):
        return struct.unpack_from("<I", window, off)[0]

    marker = window.find(b"PAC failure (ESR")
    str_va = virtual_base + marker if marker >= 0 else None
    picked = None
    if str_va is not None:
        for off in hits:
            for i in range(off, min(off + 0x200, len(window) - 16), 4):
                w = u32(i)
                if (w & 0x9f000000) != 0x90000000:
                    continue
                rd = w & 0x1f
                page = ((virtual_base + i) & ~0xfff) + (
                    sx21(((w >> 5) & 0x7ffff) << 2 | ((w >> 29) & 3)) << 12)
                for j in (1, 2, 3):
                    w2 = u32(i + 4 * j)
                    if (w2 & 0xff800000) == 0x91000000 and ((w2 >> 5) & 0x1f) == rd:
                        val = page + (((w2 >> 10) & 0xfff) << 12
                                      if (w2 >> 22) & 1 else ((w2 >> 10) & 0xfff))
                        if val == str_va:
                            picked = off
                            break
                if picked is not None:
                    break
            if picked is not None:
                break
    if picked is None:
        print(f"PAC trace: could not identify handle_pac_fail "
              f"({len(hits)} prologue hits, string at {str_va and hex(str_va)})")
    else:
        hpf = virtual_base + picked
        print(f"PAC trace: handle_pac_fail at {hpf:#x} (window off {picked:#x}, "
              f"{len(hits)} prologue hits)")

        # ------------------------------------------------------------------
        # Pre-seed the vmapple PAC default keys.
        #
        # XNU's vmapple_pac_get_default_keys() (machine_routines_apple.c) asks
        # the hypervisor via HVC 0xC1000001 and stores x2 -> vmapple_default_rop_pid
        # and x3 -> vmapple_default_jop_pid.  On this host (Kylin 5.10 KVM) the
        # HVC reply written into the vcpu context by our kprobe never reaches the
        # guest (verified: the statics stay 0 while the kprobe logs a successful
        # "delivered" write), so ml_default_jop_pid() returns 0 and XNU skips
        # signing the dyld shared-cache authenticated pointers
        # (vm_shared_region.c:3239 requires jop_key != 0) -> raw pointers ->
        # EL0 braa -> FPAC -> launchd SIGBUS.  Seed the statics and mark the
        # one-shot guard `initialized` so the guest skips the HVC entirely.
        #
        # Image-relative offset from handle_pac_fail, from
        # REPORT-jop-signskip.md sec 2.5: rop @ +0x22C4E60, jop @ +8, init @ +0x10.
        if os.environ.get("QEMU_27ON86_PAC_DEFAULTS", "1") != "0":
            soff = picked + 0x22C4E60
            try:
                cur = struct.unpack("<QQB", window[soff:soff + 17])
                if cur[0] == 0 and cur[1] == 0 and cur[2] == 0:
                    inferior.write_memory(physical_base + soff, struct.pack(
                        "<QQB", 0xfeedfacefeedfacf, 0xfeedfacefeedfad3, 1))
                    chk = bytes(inferior.read_memory(physical_base + soff, 17))
                    print(f"PAC defaults: seeded vmapple_default_rop/jop_pid at "
                          f"{virtual_base + soff:#x} -> {chk.hex()}")
                else:
                    print(f"PAC defaults: statics not zero "
                          f"(rop={cur[0]:#x} jop={cur[1]:#x} init={cur[2]}); skipped")
            except Exception as exc:
                print(f"PAC defaults: seed failed: {exc}")

        gdb.execute(f"hbreak *{hpf:#x}", to_string=True)
        for n in range(int(pac_trace)):
            try:
                gdb.execute("continue", to_string=True)
            except gdb.error as exc:
                print(f"PAC trace: continue ended: {exc}")
                break
            try:
                def ureg(name):
                    return int(gdb.parse_and_eval(name)) & 0xFFFFFFFFFFFFFFFF
                state = ureg("$x0")
                esr = ureg("$x1")
                pc = struct.unpack("<Q", bytes(inferior.read_memory(state + 264, 8)))[0]
                cpsr = struct.unpack("<I", bytes(inferior.read_memory(state + 272, 4)))[0]
                fp = struct.unpack("<Q", bytes(inferior.read_memory(state + 240, 8)))[0]
                lr = struct.unpack("<Q", bytes(inferior.read_memory(state + 248, 8)))[0]
                sp = struct.unpack("<Q", bytes(inferior.read_memory(state + 256, 8)))[0]
                regs = struct.unpack("<29Q", bytes(inferior.read_memory(state + 8, 232)))
                instr = struct.unpack("<I", bytes(inferior.read_memory(pc & ~3, 4)))[0]
            except gdb.error as exc:
                print(f"PAC trace: read failed: {exc}")
                break
            print(f"PAC#{n + 1} state={state:#x} esr={esr:#x} EC={(esr >> 26) & 0x3f:#x} "
                  f"key={esr & 3} pc={pc:#x} cpsr={cpsr:#x} instr={instr:#010x}")
            print(f"    lr={lr:#x} sp={sp:#x} fp={fp:#x}")
            for base in range(0, 29, 8):
                print("    " + " ".join(f"x{i}={regs[i]:#x}" for i in range(base, min(base + 8, 29))))
            if n == 0:
                # vmapple_default_rop_pid/jop_pid are at a fixed image offset from
                # handle_pac_fail (REPORT-jop-signskip.md sec 2.5): delta = 0x22C4E60.
                try:
                    soff = picked + 0x22C4E60
                    rop = struct.unpack_from("<Q", window, soff)[0]
                    jop = struct.unpack_from("<Q", window, soff + 8)[0]
                    print(f"    vmapple_default_rop_pid={rop:#018x} "
                          f"vmapple_default_jop_pid={jop:#018x}")
                except Exception as exc:
                    print(f"    vmapple_default_* read failed: {exc}")
            if n == 0:
                # Diagnostic: disassemble the code around the faulting EL0 PC so we
                # can see whether the faulting register was ever signed.
                for back in (0x80, 0x40, 0x20):
                    try:
                        dis = gdb.execute(f"x/{(back // 4) + 6}i {pc - back:#x}",
                                          to_string=True)
                        print(f"--- code @ pc-{back:#x} ---")
                        print(dis)
                        break
                    except gdb.error as exc:
                        print(f"PAC trace: disasm pc-{back:#x} failed: {exc}")
                # The faulting insn is `braa x16, x17`: x17 is the pointer to the
                # stub slot and x16 is the (unsigned) value loaded from it.  Dump
                # the slot table and the target code to check for signatures.
                try:
                    slot = regs[17]
                    tbl = struct.unpack("<16Q", bytes(inferior.read_memory(slot - 0x20, 128)))
                    print(f"--- stub slots @ {slot - 0x20:#x} ---")
                    for i, v in enumerate(tbl):
                        tag = "SIGNED" if (v >> 48) else "raw"
                        print(f"    [{slot - 0x20 + 8*i:#x}] = {v:#018x}  {tag}")
                    tgt = regs[16]
                    dis2 = gdb.execute(f"x/12i {tgt:#x}", to_string=True)
                    print(f"--- target code @ x16={tgt:#x} ---")
                    print(dis2)
                    # Which image owns pc?  Dump the Mach-O header candidates.
                    for cand in (pc & ~0xFFFFFFFFFFFFF if False else None,):
                        pass
                except gdb.error as exc:
                    print(f"PAC trace: slot dump failed: {exc}")
            gdb.flush()
        gdb.execute("delete breakpoints", to_string=True)

# ---------------------------------------------------------------------------
# PAC fault forensics: on the first KERNEL PAC-authentication failure, dump
# the fault context for offline analysis (root-causing the recurring
# "PAC failure from kernel with DA key" panics: corrupt/NULL vtable words in
# kernel object lists).  Nothing is patched; after the dump the guest simply
# continues into XNU's normal panic path.
#   QEMU_27ON86_PAC_FORENSICS=<logfile>   append the dump here (and stdout)
# The breakpoint uses the same dynamically-located handle_pac_fail as above,
# so per-boot slide needs no manual handling.  EL0 faults are logged and
# skipped; the dump fires on the first kernel-mode hit.
# ---------------------------------------------------------------------------
pac_forensics = os.environ.get("QEMU_27ON86_PAC_FORENSICS")
if pac_forensics and globals().get("picked") is not None:
    import datetime

    _sx21 = lambda v: (lambda m: m - (1 << 21) if m & (1 << 20) else m)(v & 0x1fffff)

    def _canon(v):
        # Strip a 16-bit PAC field and sign-extend a 48-bit kernel VA.
        v &= 0x0000FFFFFFFFFFFF
        return v | 0xFFFF000000000000 if v & (1 << 47) else v

    def _rd(a, n):
        return bytes(inferior.read_memory(a, n))

    def _rd64(a):
        return struct.unpack("<Q", _rd(a, 8))[0]

    def _rd32(a):
        return struct.unpack("<I", _rd(a, 4))[0]

    def _cstr(a):
        try:
            raw = _rd(_canon(a), 64)
            return raw.split(b"\0")[0].decode("ascii", "replace")
        except Exception:
            return None

    def _meta_from_obj(obj):
        # vtable word (signed, strip PAC) -> slot 7 = getMetaClass thunk
        # (adrp x0, page; add x0, x0, #lo; ret) -> OSMetaClass instance.
        try:
            vt = _canon(_rd64(obj))
            fn = _rd64(vt + 0x38)
            w0, w1, w2 = struct.unpack("<III", _rd(fn, 12))
            if ((w0 & 0x9F000000) != 0x90000000 or (w1 & 0xFF800000) != 0x91000000
                    or w2 != 0xD65F03C0):
                return None, None
            if (w0 & 0x1F) != 0 or ((w1 >> 5) & 0x1F) != 0:
                return None, None
            page = (fn & ~0xFFF) + (_sx21(((w0 >> 5) & 0x7FFFF) << 2 | ((w0 >> 29) & 3)) << 12)
            return vt, page + ((w1 >> 10) & 0xFFF)
        except Exception:
            return None, None

    def _class_name(obj):
        try:
            vt, meta = _meta_from_obj(obj)
            if meta is None:
                return None, None
            # OSMetaClass: className (OSSymbol*) @ +0x18;
            # OSSymbol/OSString: char *string @ +0x10 (itself PAC-signed).
            sym = _canon(_rd64(meta + 0x18))
            name = _cstr(_rd64(sym + 0x10))
            return name, meta
        except Exception:
            return None, None

    flog = open(pac_forensics, "a", buffering=1)

    def pline(s=""):
        print(s)
        print(s, file=flog)

    def _dump_obj(tag, obj):
        try:
            words = struct.unpack("<16Q", _rd(obj, 128))
            pline(f"--- {tag} @ {obj:#x} ---")
            for i in range(0, 16, 2):
                pline(f"    +{0x8 * i:#04x}: {words[i]:#018x} {words[i + 1]:#018x}")
            name, meta = _class_name(obj)
            pline(f"    vtable/meta -> class: {name if name else '<unresolved>'}"
                  f"{f' meta={meta:#x}' if meta else ''}")
        except gdb.error as exc:
            pline(f"--- {tag} @ {obj:#x} unreadable: {exc} ---")

    pline(f"PAC forensics: handle_pac_fail={hpf:#x} log={pac_forensics}")
    pline(f"PAC forensics: armed {datetime.datetime.now().isoformat()}")
    gdb.execute(f"hbreak *{hpf:#x}", to_string=True)
    _hits = 0
    while _hits < 64:
        _hits += 1
        try:
            gdb.execute("continue", to_string=True)
        except gdb.error as exc:
            pline(f"PAC forensics: continue ended: {exc}")
            break
        try:
            state = int(gdb.parse_and_eval("$x0")) & 0xFFFFFFFFFFFFFFFF
            esr = int(gdb.parse_and_eval("$x1")) & 0xFFFFFFFFFFFFFFFF
            pc = struct.unpack("<Q", _rd(state + 264, 8))[0]
            cpsr = struct.unpack("<I", _rd(state + 272, 4))[0]
        except gdb.error as exc:
            pline(f"PAC forensics: read failed: {exc}")
            break
        if (cpsr & 0xF) == 0:
            pline(f"PAC forensics: EL0 fault #{_hits} pc={pc:#x} esr={esr:#x}; skipped")
            continue
        regs = struct.unpack("<29Q", _rd(state + 8, 232))
        fp = _rd64(state + 240)
        lr = _rd64(state + 248)
        sp = _rd64(state + 256)
        try:
            instr = _rd32(pc & ~3)
        except gdb.error:
            instr = 0
        pline("")
        pline(f"===== KERNEL PAC FAULT (hit #{_hits}) =====")
        pline(f"time={datetime.datetime.now().isoformat()} state={state:#x} "
              f"esr={esr:#x} EC={(esr >> 26) & 0x3f:#x} key={esr & 3}")
        pline(f"pc={pc:#x} instr={instr:#010x} cpsr={cpsr:#x}")
        pline(f"lr={lr:#x} sp={sp:#x} fp={fp:#x}")
        for base in range(0, 29, 4):
            pline("    " + " ".join(f"x{i}={regs[i]:#x}"
                                    for i in range(base, min(base + 4, 29))))
        badobj = regs[0]
        setp = regs[21]
        idx = regs[24] & 0xFFFFFFFF
        pline(f"analysis: badobj=x0={badobj:#x} set=x21={setp:#x} "
              f"idx=x24={idx:#d} casttarget=x28={regs[28]:#x}")
        _dump_obj("bad object", badobj)
        try:
            sh = struct.unpack("<16Q", _rd(setp, 128))
            pline(f"--- set header @ {setp:#x} ---")
            for i in range(0, 16, 2):
                pline(f"    +{0x8 * i:#04x}: {sh[i]:#018x} {sh[i + 1]:#018x}")
            arr = _canon(sh[3])            # +0x18: struct _Element *array
            cnt = _rd32(setp + 0x30)       # count
            cap = _rd32(setp + 0x34)       # capacity
            pline(f"parsed: array={arr:#x} count={cnt} capacity={cap}")
            lo = max(0, idx - 3)
            pline(f"--- array[{lo} .. {idx + 3}] ({8} bytes/element) ---")
            for k in range(lo, idx + 4):
                el = _rd64(arr + 8 * k)
                mark = "  <== getObject(idx) returned this" if k == idx else ""
                pline(f"    [{k}] = {el:#018x}{mark}")
                if k != idx and 0xFFFFFE0000000000 <= _canon(el) < 0xFFFFFF0000000000 \
                        and abs(k - idx) <= 2:
                    name, meta = _class_name(_canon(el))
                    extra = f" meta={meta:#x}" if meta else ""
                    pline(f"          -> {_canon(el):#x} class={name}{extra}")
        except gdb.error as exc:
            pline(f"set/array dump failed: {exc}")
        pline("===== end of PAC forensics dump =====")
        flog.flush()
        break
    try:
        flog.close()
    except Exception:
        pass

# Optional compatibility fix ("option 2"): emulate the lenient TCG contract
# (accept-and-strip) for the guest.  On every handle_pac_fail() entry the
# faulting instruction is decoded, the saved destination/target register is
# stripped of its PAC, and the kernel PC is redirected to the caller's common
# switch exit so the repaired saved state returns to EL0 normally instead of
# exception_triage() -> SIGBUS.  The guest disk is never touched; in guest RAM
# only the saved-state object, the live kernel PC, and one 4-byte NOP that
# disables ml_check_signed_state()'s mismatch branch are changed.
if (pac_fix or pac_tramp) and picked is not None:
    # Common switch exit of the function calling handle_pac_fail().  In this
    # kernelcache it sits a fixed distance before handle_pac_fail() and is the
    # target of 14 `b` sites (the handled cases' `break`).
    exit_va = hpf - 0xBCC
    # Read the check word from the handoff RAM window (the runtime VA is not
    # translatable until XNU installs its page tables).
    exit_word = struct.unpack_from("<I", window, picked - 0xBCC)[0]
    if exit_word != 0xB945A348:              # ldr w8, [x26, #1440]
        print(f"PAC fix: unexpected common-exit word {exit_word:#x} at "
              f"{exit_va:#x}; disabled")
        pac_fix = None

    # XNU validates the saved PC/CPSR/LR against a PACGA hash in
    # ml_check_signed_state(); our repaired saved state no longer matches it,
    # so the next exception return panics with "JOP Hash Mismatch Detected".
    # NOP only the final mismatch branch (cmp x1,x6; b.ne <panic>) so the
    # check always falls through, exactly as the reference project did.
    if pac_fix is not None or pac_tramp:
        JOP_OFF = 0xB7BFC0                   # image offset of the b.ne
        jop_woff = (picked - 0xCEB508) + JOP_OFF
        jop_word = struct.unpack_from("<I", window, jop_woff)[0]
        if jop_word != 0x54000041:           # b.ne 0x7b7ffc8
            print(f"PAC fix: unexpected JOP branch word {jop_word:#x}; "
                  f"JOP patch skipped")
        else:
            inferior.write_memory(physical_base + jop_woff,
                                  struct.pack("<I", 0xD503201F))  # nop
            print(f"PAC fix: NOP'd JOP hash mismatch branch at "
                  f"pa={physical_base + jop_woff:#x}")

# ---------------------------------------------------------------------------
# One-shot in-guest trampoline: overwrite XNU's handle_pac_fail() itself with a
# stub that decodes the faulting PAC instruction, strips the PAC bits from the
# destination register and continues (i.e. "authentication always succeeds").
# This is the same semantics as QEMU_27ON86_PAC_FIX, but costs ~nothing per
# fault instead of one gdb hardware-breakpoint round trip, so it can keep up
# with the thousands of failures macOS arm64e userspace produces here.
# ---------------------------------------------------------------------------
if pac_tramp and picked is not None:
    blob = bytearray(open(pac_tramp, "rb").read())
    exit_va = hpf - 0xBCC
    magic = struct.pack("<I", 0xDEADBEEF)
    b_off = blob.find(magic)
    delta = exit_va - (hpf + b_off)
    if b_off < 0 or delta % 4 or not (-(1 << 27) <= delta < (1 << 27)):
        print(f"PAC trampoline: bad placeholder (off={b_off}) or delta "
              f"{delta:#x}; skipped")
    else:
        word = 0x14000000 | ((delta >> 2) & 0x03FFFFFF)
        blob[b_off:b_off + 4] = struct.pack("<I", word)
        pa = physical_base + picked
        inferior.write_memory(pa, bytes(blob))
        print(f"PAC trampoline: {len(blob)} bytes over handle_pac_fail "
              f"va={hpf:#x} pa={pa:#x}; b@{b_off} -> {exit_va:#x}")

# ---------------------------------------------------------------------------
# Dynamic debugging: after the trampoline is installed, set a hardware
# breakpoint at `hpf` (the trampoline entry) and print the fault context
# (EL0 pc / esr / instruction / registers) on each hit.
#   QEMU_27ON86_PAC_TRACE_AFTER=N   print N times
#   QEMU_27ON86_PAC_SKIP=M          pass through the first M faults (skip early noise)
# Each fault stops gdb once, which is slow, so keep N small.
# ---------------------------------------------------------------------------
pac_after = os.environ.get("QEMU_27ON86_PAC_TRACE_AFTER")
if pac_tramp and pac_after and picked is not None:
    pac_skip = int(os.environ.get("QEMU_27ON86_PAC_SKIP", "0"))
    limit = int(pac_after)
    gdb.execute(f"hbreak *{hpf:#x}", to_string=True)
    if pac_skip:
        gdb.execute(f"ignore 1 {pac_skip}", to_string=True)
    print(f"PAC after-trace: hbreak @ {hpf:#x} skip={pac_skip} limit={limit}")
    for n in range(limit):
        try:
            gdb.execute("continue", to_string=True)
        except gdb.error as exc:
            print(f"PAC after-trace: continue ended: {exc}")
            break
        try:
            state = int(gdb.parse_and_eval("$x0")) & 0xFFFFFFFFFFFFFFFF
            esr = int(gdb.parse_and_eval("$x1")) & 0xFFFFFFFFFFFFFFFF
            pc = struct.unpack("<Q", bytes(inferior.read_memory(state + 264, 8)))[0]
            cpsr = struct.unpack("<I", bytes(inferior.read_memory(state + 272, 4)))[0]
            lr = struct.unpack("<Q", bytes(inferior.read_memory(state + 248, 8)))[0]
            instr = struct.unpack("<I", bytes(inferior.read_memory(pc & ~3, 4)))[0]
            regs = struct.unpack("<29Q", bytes(inferior.read_memory(state + 8, 232)))
        except gdb.error as exc:
            print(f"PAC after-trace: read failed: {exc}")
            break
        print(f"AFTER#{pac_skip + n + 1} esr={esr:#x} EC={(esr >> 26) & 0x3f:#x} "
              f"key={esr & 3} cpsr={cpsr:#x} pc={pc:#x} instr={instr:#010x} lr={lr:#x}")
        print("    " + " ".join(f"x{i}={regs[i]:#x}" for i in range(0, 22)))
        gdb.flush()
    print("PAC after-trace: done")
    gdb.execute("delete breakpoints", to_string=True)

if pac_fix and picked is not None:
    def rd64(a):
        return struct.unpack("<Q", bytes(inferior.read_memory(a, 8)))[0]

    def rd32(a):
        return struct.unpack("<I", bytes(inferior.read_memory(a, 4)))[0]

    def wr64(a, v):
        inferior.write_memory(a, struct.pack("<Q", v & 0xFFFFFFFFFFFFFFFF))

    def roff(i):
        return 240 if i == 29 else (248 if i == 30 else 8 + 8 * i)

    def strip(v):
        return v & 0x0000FFFFFFFFFFFF

    def decode_pac(insn):
        """Return (kind, reg) for an instruction that can raise FPAC."""
        if (insn & 0xFFFFE000) == 0xDAC10000:          # AUTIA/IB/DA/DB Xd,Xn
            if ((insn >> 10) & 7) >= 4:
                return ("strip", insn & 0x1F)
            return None
        if insn in (0xD503219F, 0xD50321DF):           # AUTIA1716/AUTIB1716
            return ("strip", 17)
        if insn in (0xD503239F, 0xD50323DF,
                    0xD50323BF, 0xD50323FF):           # AUTIAZ/BZ/ASP/BSP
            return ("strip", 30)
        if (insn & 0xFFFFF800) in (0xD61F0800, 0xD71F0800):
            return ("b", (insn >> 5) & 0x1F)      # BRAA/BRAB/BRAAZ/BRABZ
        if (insn & 0xFFFFF800) in (0xD63F0800, 0xD73F0800):
            return ("bl", (insn >> 5) & 0x1F)     # BLRAA/BLRAB/BLRAAZ/BLRABZ
        if insn in (0xD65F0BFF, 0xD65F0FFF):           # RETAA/RETAB
            return ("ret", 30)
        return None

    limit = int(pac_fix)
    fixed = unknown = skipped = 0
    print(f"PAC fix: handle_pac_fail={hpf:#x} common-exit={exit_va:#x} limit={limit}")
    gdb.execute(f"hbreak *{hpf:#x}", to_string=True)
    while fixed < limit:
        try:
            gdb.execute("continue", to_string=True)
        except gdb.error as exc:
            print(f"PAC fix: continue ended: {exc}")
            break
        try:
            state = int(gdb.parse_and_eval("$x0")) & 0xFFFFFFFFFFFFFFFF
            esr = int(gdb.parse_and_eval("$x1")) & 0xFFFFFFFFFFFFFFFF
            pc = rd64(state + 264)
            cpsr = rd32(state + 272)
            insn = rd32(pc & ~3)
        except gdb.error as exc:
            print(f"PAC fix: read failed: {exc}")
            break
        dec = decode_pac(insn)
        if dec is None:
            unknown += 1
            if unknown <= 5:
                print(f"PAC fix: unknown insn {insn:#010x} pc={pc:#x} "
                      f"esr={esr:#x} cpsr={cpsr:#x} (left to XNU)")
            continue
        kind, reg = dec
        if kind == "strip":
            wr64(state + roff(reg), strip(rd64(state + roff(reg))))
            wr64(state + 264, pc + 4)
        elif kind in ("b", "bl"):
            tgt = strip(rd64(state + roff(reg)))
            if kind == "bl":
                wr64(state + 248, pc + 4)
            wr64(state + 264, tgt)
        else:
            wr64(state + 264, strip(rd64(state + 248)))
        fixed += 1
        if fixed <= 25:
            print(f"PAC fix#{fixed}: {kind} x{reg} @pc={pc:#x} -> "
                  f"{rd64(state + 264):#x} esr={esr:#x}")
        gdb.execute(f"set $pc = {exit_va:#x}", to_string=True)
        gdb.flush()
    print(f"PAC fix: done, fixed={fixed} unknown={unknown}")
    gdb.execute("delete breakpoints", to_string=True)

gdb.execute("delete breakpoints", to_string=True)
gdb.execute("detach", to_string=True)
end
