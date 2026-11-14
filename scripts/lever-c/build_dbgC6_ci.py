#!/usr/bin/env python3
"""Build the lever-C v6 image (dbgC6) over dbgC5.

Base: diag/KERNEL.ci-a699dd6-dbgC5 (CI kernel a699dd6 + CI ramdisk + the
      lever-B ULog hook v2 + the lever-C v5 hook with the early
      full-chain escalation and the runtime UCSI resolution).  The base's
      90-armada-ulog-b.sh is asserted byte-identical to
      diag/armada-ulog-b2.sh and its 91-armada-usb-fix-c.sh to
      diag/armada-usb-fix-c5.sh (provenance: this is really dbgC5).
REPLACES the lever-C hook file in the main (zstd) cpio (the base is
      dbgC5, which already carries it under this name):
      var/lib/dracut/hooks/initqueue/91-armada-usb-fix-c.sh
      (same in-image name as dbgC2..C5; the image FILENAME is distinct so
      the file on the stick self-identifies -- the run-5/6/7 stick held
      dbgC5, md5 c08490f9..., and must never be overwritten/renamed on
      disk).

WHY dbgC6 (2026-11-13): run 7 (dbgC5) established the CLEAN BETA-2: the
full chain ran correctly, early and post-VBUS, and did not help -- the
residual blocker is below dwc3 (the eUSB2 repeater / PPM / physical).
The user answered the two cheap discriminators: the stick LED is ON
(power path excluded) and a MANUAL REPLUG WORKS (the CC-edge model is
confirmed: a fresh CC attach opens the port; no AP-side lever can create
one).  Web research found the concrete regression candidate: upstream
31bc94de (2025-06) removed the zero-out of the un-touched repeater
tuning registers that the vendor kernel used to perform -- the
zeroing-era kernel overwrote the ABL session residue at every init
(self-healing), the new kernel trusts it.  The decisive experiment is
now a register dump: the pm8550b eUSB2 repeater block 0xfd00-0xfd5b in
'linux usb' (broken, after the full chain) vs the full system
(working) -- the 8 never-kernel-written registers (0x50/0x52/0x55/0x56/
0x58/0x59-0x5b) hold either the hardware reset values or the ABL
residue (candidate: 0x00, the old vendor behavior); the known-good
values are non-public (no DTS anywhere sets them) so the dump is the
only source of the recipe.

The hook (diag/armada-usb-fix-c6.sh) is lever C v6 = v5 + ONE addition:
_ac_repdump, run after the v5 sequence in both modes:
  * 'linux usb': dump AFTER the full chain (the state the chain left);
  * normal boot: wait for the stick to enumerate (<=45 s -- the
    repeater is initialized by then; the boot is NOT blocked, the
    subshell is backgrounded) and dump the known-good state.
The dump reads the PMIC regmap debugfs 'registers' file (already built
into the CI kernel: regmap-debugfs.o builds under CONFIG_DEBUG_FS,
drivers/base/regmap/Makefile:7; there is NO CONFIG_REGMAP_DEBUGFS
option in 7.2.6; the WRITE path is the separate 1401 kernel patch, not
in this image).  Mechanics (7.2.6, code-verified): 9 B/line
("XXXX: XX\\n": reg_len 4 for max_register 0xffff, val_len 2 for
val_bits 8, regmap-debugfs.c:182-192); the reader walks to the ppos in
SOFTWARE before any HW read (regmap_debugfs_get_dump_start,
regmap-debugfs.c:96-180) -> the 92-line block is read with
`tail -c +582913 | sed -n 1,92p` (offset = 0xfd00 x 9, 1-based; no
dd/head in the initramfs, GNU tail on the Fedora image).  The PMIC
regmap directory is RESOLVED AT RUNTIME (never hard-coded -- the UCSI
lesson): the repeater platform device (glob *eusb2*; an of_platform
child of the PMIC spmi device, devm_of_platform_populate
qcom-spmi-pmic.c:284) -> parent dir name = the spmi dev_name
(spmi.c:67, "%d-%02x") = the regmap debugfs dir
(regmap-debugfs.c:574-587,603).  Output: RPT-DUMP (mode/resolution) +
RPT-B (92 regs, 8 per line) + RPT-KEY (the 8 residue candidates) +
RPT-WRN (kernel-written/RO with expectations) + RPT-DONE/RPT-ABSENT/
RPT-FAIL.

Everything else (kernel, cmdline, lever-B hook, all initramfs content)
is preserved. Boot-image invariants as always: magic ANDROID!,
hdr[20:576] byte-identical to base, sha1_id recomputed at 576 (dbg43
lesson: never zero the header).
"""
import hashlib
import struct
import sys
from pathlib import Path

import cpio
import zstandard as zstd

HERE = Path(__file__).resolve().parent
BASE = HERE / "KERNEL.ci-a699dd6-dbgC5"
OUT = HERE / "KERNEL.ci-a699dd6-dbgC6"
HOOK_SRC = HERE / "armada-usb-fix-c6.sh"
C_HOOK_SRC = HERE / "armada-usb-fix-c5.sh"
B_HOOK_SRC = HERE / "armada-ulog-b2.sh"
HOOK_NAME = b"var/lib/dracut/hooks/initqueue/91-armada-usb-fix-c.sh"
C_HOOK = b"var/lib/dracut/hooks/initqueue/91-armada-usb-fix-c.sh"
B_HOOK = b"var/lib/dracut/hooks/initqueue/90-armada-ulog-b.sh"


def rup(x, a):
    return (x + a - 1) // a * a


def sha1_id(kernel, ramdisk):
    h = hashlib.sha1()
    h.update(kernel)
    h.update(struct.pack("<I", len(kernel)))
    h.update(ramdisk)
    h.update(struct.pack("<I", len(ramdisk)))
    h.update(struct.pack("<I", 0))
    return h.digest()


def unpack_ram(ram):
    z = ram.find(b"\x28\xb5\x2f\xfd")
    assert z > 0, f"zstd magic not found: {z}"
    main = zstd.ZstdDecompressor().decompress(ram[z:], max_output_size=1 << 31)
    return ram[:z], main


def main():
    hook = HOOK_SRC.read_bytes()
    assert hook.startswith(b"#!/bin/sh"), "hook must be /bin/sh"
    assert len(hook) > 5000, f"hook too small: {len(hook)} B"
    assert b"/dev/kmsg" in hook and b"ARMADA-C:" in hook
    # v2/v3 markers (logic must still be there).
    assert b"FAIL-NO-DEV" in hook, "v2 FAIL-NO-DEV marker missing"
    assert b"Host halt failed, -110" in hook, "v2 -110 hard stop missing"
    assert b"TREE[" in hook and b"usb_role" in hook, "v3 tree dump markers missing"
    assert b"command -v lsusb" in hook and b"/sys/bus/usb/devices/" in hook, \
        "v3 lsusb/sysfs fallback missing"
    assert b"_ac_maybedump" in hook and b"t10" in hook, "v3 once-at-10s dump missing"
    # v4 markers: the partner gate, the dump additions, the full-chain
    assert b"port0-partner" in hook and b"WARN-nopartner" in hook, \
        "v4 partner gate missing"
    assert b"orientation" in hook, "v4 orientation dump missing"
    assert b"/sys/bus/platform/drivers/dwc3-qcom" in hook, \
        "v4 dwc3-qcom driver path missing"
    assert b"_ac_escalate" in hook and b"ESCALATE" in hook, "v4 escalation missing"
    assert b"ENUMERATION OK (full-chain)" in hook and b"FAIL-NO-SCAN-FULL" in hook, \
        "v4 full-chain verdicts missing"
    assert b"ESCALATE: unbind order ucsi -> xhci -> dwc3" in hook, \
        "v4 unbind order marker missing"
    assert b"rebind order dwc3 -> ucsi" in hook, "v4 rebind order marker missing"
    # the xhci-only verdicts must still exist (primary verdict untouched)
    assert b"ENUMERATION OK (first post-PDR scan)" in hook
    # v5 markers: EARLY escalation + RUNTIME UCSI resolution + ESCDIAG +
    # the true VBUS proxy ("otg enable: 1")
    assert b"no USB disk after the first post-flip scan" in hook, \
        "v5 early-escalation verdict missing"
    assert b"_ac_ucsi_resolve" in hook, "v5 runtime UCSI resolve missing"
    assert b'cd -P "$_p/driver"' in hook, \
        "v5 driver-symlink resolution missing"
    assert b"ESCDIAG" in hook, "v5 ESCDIAG dump missing"
    assert b"_ac_vbus" in hook and b"otg enable: 1" in hook, \
        "v5 VBUS proxy missing"
    # NEGATIVE asserts: the v4 3-try rebind loop and the hard-coded UCSI
    # driver path must be GONE
    assert b"rebind retry" not in hook, "v4 3-try loop still present"
    assert b"no disk after try" not in hook, "v4 3-try loop still present"
    assert b"_ac_xbind" not in hook, "v4 rebind helper still present"
    assert b"_ac_udrv" not in hook, "hard-coded UCSI driver var still present"
    # v6 markers: the repeater dump + the runtime regmap resolution
    assert b"_ac_repdump" in hook, "v6 repeater dump missing"
    assert b"tail -c +582913" in hook, "v6 dump read offset missing"
    assert b"sed -n '1,92p'" in hook, "v6 dump line bound missing"
    assert b"RPT-KEY" in hook and b"RPT-WRN" in hook and b"RPT-DUMP" in hook, \
        "v6 dump markers missing"
    assert b"*eusb2*" in hook, "v6 repeater glob missing"
    assert b"/sys/kernel/debug/regmap/" in hook, "v6 regmap dir missing"
    assert b"RPT-ABSENT" in hook and b"RPT-FAIL" in hook, \
        "v6 dump abort markers missing"
    assert b"grep -qs \" debugfs \" /proc/mounts" in hook, \
        "v6 debugfs mount-on-demand missing"
    # the WRITE path must NOT be in this image (that is the 1401 kernel
    # patch + a later hook iteration; this image reads only)
    assert b"echo fd" not in hook.replace(b"echo \"fd", b"echo fd"), \
        "v6 must not write registers (read-only dump image)"
    assert b"RPT-WRITE" not in hook, "v6 must not write registers"

    b_hook = B_HOOK_SRC.read_bytes()
    assert b_hook.startswith(b"#!/bin/sh"), "B hook must be /bin/sh"
    c_hook_base = C_HOOK_SRC.read_bytes()
    assert c_hook_base.startswith(b"#!/bin/sh"), "C5 hook must be /bin/sh"

    d = open(BASE, "rb").read()
    assert d[:8] == b"ANDROID!", "not boot image"
    ks, = struct.unpack_from("<I", d, 8)
    rs, = struct.unpack_from("<I", d, 16)
    pg, = struct.unpack_from("<I", d, 36)
    kernel = d[pg:pg + ks]
    ram_off = pg + rup(ks, pg)
    ram = d[ram_off:ram_off + rs]
    rest = d[ram_off + rs:]
    print(f"base: ks={ks} rs={rs} pg={pg} rest={len(rest)}")

    early, main_cpio = unpack_ram(ram)
    entries, _, _ = cpio.parse(main_cpio)
    names = [e["name"] for e in entries]
    print(f"main cpio entries={len(entries)} early={len(early)}")
    assert B_HOOK in names, "lever-B hook missing from the base image"
    assert C_HOOK in names, "lever-C hook missing from the base image"
    by_name = {e["name"]: e["data"] for e in entries}
    assert by_name[B_HOOK] == b_hook, \
        "base lever-B hook != armada-ulog-b2.sh (base is not dbgC5)"
    assert by_name[C_HOOK] == c_hook_base, \
        "base lever-C hook != armada-usb-fix-c5.sh (base is not dbgC5)"
    assert names[-1] == b"TRAILER!!!", f"last entry not TRAILER: {names[-1]}"

    # the C hook EXISTS in the base (same in-image name as dbgC5) --
    # REPLACE it, never leave a duplicate entry
    trailer = entries[-1]
    n_old = sum(1 for e in entries if e["name"] == HOOK_NAME)
    assert n_old == 1, f"expected exactly one C hook in the base, got {n_old}"
    body = [e for e in entries[:-1] if e["name"] != HOOK_NAME]
    ino_max = max(e["ino"] for e in entries) if entries else 0
    body.append(cpio.make_entry(HOOK_NAME, hook, mode=0o100755,
                                 ino=ino_max + 1, mtime=0, nlink=1))
    body.append(trailer)
    new_main = cpio.build(body)
    print(f"hook replaced: {HOOK_NAME.decode()} ({len(hook)} B), main {len(new_main)} B")

    new_ram = early + zstd.ZstdCompressor(level=15).compress(new_main)
    print(f"ramdisk: {len(ram)} -> {len(new_ram)} (delta {len(new_ram) - len(ram)})")

    ks_new, rs_new = len(kernel), len(new_ram)
    hdr = bytearray(d[:pg])
    struct.pack_into("<I", hdr, 8, ks_new)
    struct.pack_into("<I", hdr, 16, rs_new)
    assert bytes(hdr[0:8]) == b"ANDROID!"
    assert bytes(hdr[20:576]) == d[20:576], "hdr[20:576] changed"
    out = bytearray(bytes(hdr) + kernel.ljust(rup(ks_new, pg), b"\x00") + new_ram + rest)
    ram_off_n = pg + rup(ks_new, pg)
    out[576:596] = sha1_id(bytes(out[pg:pg + ks_new]),
                           bytes(out[ram_off_n:ram_off_n + rs_new]))
    out = bytes(out)

    # verify image invariants
    assert out[:8] == b"ANDROID!"
    assert out[20:576] == d[20:576]
    assert out[pg:pg + ks_new] == kernel, "kernel changed"
    ks_c, = struct.unpack_from("<I", out, 8)
    rs_c, = struct.unpack_from("<I", out, 16)
    assert (ks_c, rs_c) == (ks_new, rs_new)
    ram_off_c = pg + rup(ks_c, pg)
    assert out[ram_off_c:ram_off_c + rs_c] == new_ram
    assert out[ram_off_c + rs_c:] == rest, "trailer changed"
    assert out[576:596] == sha1_id(out[pg:pg + ks_c],
                                   out[ram_off_c:ram_off_c + rs_c])

    # round-trip: extract both hooks from the built image, byte-compare
    _, main_c = unpack_ram(out[ram_off_c:ram_off_c + rs_c])
    ents_c, _, _ = cpio.parse(main_c)
    by_name_c = {e["name"]: e["data"] for e in ents_c}
    assert by_name_c[HOOK_NAME] == hook, "C6 hook round-trip mismatch"
    assert by_name_c[B_HOOK] == b_hook, "lever-B hook was altered"
    assert len(ents_c) == len(entries), "unexpected entry count change"
    print("round-trip: C6 hook identical, B hook untouched, same entry count")

    open(OUT, "wb").write(out)
    print(f"OK: {OUT} ({len(out)} B), hook={HOOK_NAME.decode()}")
    print("md5: " + hashlib.md5(out).hexdigest())
    print("sha256: " + hashlib.sha256(out).hexdigest())
    return 0


if __name__ == "__main__":
    sys.exit(main())
