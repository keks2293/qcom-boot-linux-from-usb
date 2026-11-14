#!/usr/bin/env python3
"""Build the lever-C v5 image (dbgC5) over dbgB2.

Base: diag/KERNEL.ci-a699dd6-dbgB2 (CI kernel a699dd6 + CI ramdisk + the
      lever-B ULog hook v2 with the EAGAIN-suppressed read).  The base's
      90-armada-ulog-b.sh is asserted byte-identical to diag/armada-ulog-b2.sh
      (provenance: this is really dbgB2, not the old dbgB).  Same base as
      dbgC2/dbgC3/dbgC4.
Adds ONE dracut hook file to the main (zstd) cpio:
      var/lib/dracut/hooks/initqueue/91-armada-usb-fix-c.sh
      (same in-image name as dbgC2/C3/C4; the image FILENAME is distinct so
      the file on the stick self-identifies -- the run-5 stick held dbgC4,
      md5 5704495b..., and must never be overwritten/renamed on disk).

WHY dbgC5 (run 5 = dbgC4, 2026-11-13): the v4 full-chain escalation NEVER
RAN.  Run 5 aborted on its first step:
      line 299: /sys/bus/auxiliary/drivers/pmic_glink_ucsi/unbind:
                No such file or directory
  -> the HARD-CODED UCSI driver path does not exist in the running kernel
     (ucsi_glink is built-in, CONFIG_UCSI_PMIC_GLINK=y; the built-kernel
     sysfs layout differs from the source .name).  The UAF abort-guard
     worked correctly (dwc3 was NOT touched), but beta-1/beta-2 remain
     UNTESTED -- the full chain has never executed.

Run 5 also measured two more facts: (1) orientation=[normal] (the reverse-
plug hypothesis is CLOSED); (2) the port0-partner gate is PRE-VBUS in
reality (partner @3.88 s while "otg enable: 1" @5.436 s) -- the v4
assumption "partner ~5.4 s = post-VBUS marker" was wrong.

The hook (diag/armada-usb-fix-c5.sh) is lever C v5: v4 logic + (a) EARLY
full-chain escalation (a 3 s bounded window after the partner gate, then
escalate NOW -- the v4 3-try xhci rebind loop is DELETED, run 4 proved it
useless: scan-events=0 x3); (b) the UCSI device AND its driver are
RESOLVED AT RUNTIME: the device by glob (pmic_glink.ucsi.* on the
auxiliary bus, fallback *ucsi* on ALL buses) and the driver from the
device's own `driver` symlink (cd -P / pwd -P -- never the hard-coded
sysfs path); (c) an ESCDIAG dump (aux devices/drivers, every *ucsi*
candidate with its resolved driver or UNBOUND) printed right before the
unbind so the next photo shows the real layout; (d) abort branches rc=127
(device absent) / rc=128 (device present, unbound) => ESC-ABORT, dwc3 NOT
touched (the full chain cannot complete without a bindable UCSI); (e) the
partner gate is relabeled ("the PPM sees the stick", NOT a VBUS marker)
and the VBUS state is printed via _ac_vbus (the ULog "otg enable: 1"
line).  Verdicts (unchanged matrix): ENUMERATION OK (first post-PDR scan)
/ ENUMERATION OK (full-chain) (beta-1) / FAIL-NO-SCAN-FULL (beta-2) /
FAIL: Host halt -110 / FAIL-ESCALATE / NO-XHCI-ESC.

Everything else (kernel, cmdline, lever-B hook, all initramfs content) is
preserved. Boot-image invariants as always: magic ANDROID!, hdr[20:576]
byte-identical to base, sha1_id recomputed at 576 (dbg43 lesson: never
zero the header).
"""
import hashlib
import struct
import sys
from pathlib import Path

import cpio
import zstandard as zstd

HERE = Path(__file__).resolve().parent
BASE = HERE / "KERNEL.ci-a699dd6-dbgB2"
OUT = HERE / "KERNEL.ci-a699dd6-dbgC5"
HOOK_SRC = HERE / "armada-usb-fix-c5.sh"
B_HOOK_SRC = HERE / "armada-ulog-b2.sh"
HOOK_NAME = b"var/lib/dracut/hooks/initqueue/91-armada-usb-fix-c.sh"
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
    assert len(hook) > 3000, f"hook too small: {len(hook)} B"
    assert b"/dev/kmsg" in hook and b"ARMADA-C:" in hook
    # v2/v3 markers (logic must still be there).  Note: the v2 [source]+
    # [host] role gate was superseded by the v4/v5 port0-partner gate, so
    # the surviving v2 markers are FAIL-NO-DEV (xhci never appeared) and the
    # -110 hard stop (a new "Host halt failed, -110" aborts immediately).
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
    # driver path must be GONE (run 5: the hard-coded path does not exist
    # in the running kernel; the 3-try loop was proven useless)
    assert b"rebind retry" not in hook, "v4 3-try loop still present"
    assert b"no disk after try" not in hook, "v4 3-try loop still present"
    assert b"_ac_xbind" not in hook, "v4 rebind helper still present"
    assert b"_ac_udrv" not in hook, "hard-coded UCSI driver var still present"

    b_hook = B_HOOK_SRC.read_bytes()
    assert b_hook.startswith(b"#!/bin/sh"), "B hook must be /bin/sh"

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
    by_name = {e["name"]: e["data"] for e in entries}
    assert by_name[B_HOOK] == b_hook, \
        "base lever-B hook != armada-ulog-b2.sh (base is not dbgB2)"
    assert HOOK_NAME not in names, f"hook already present: {HOOK_NAME}"
    assert names[-1] == b"TRAILER!!!", f"last entry not TRAILER: {names[-1]}"

    trailer = entries[-1]
    body = entries[:-1]
    ino_max = max(e["ino"] for e in entries) if entries else 0
    body.append(cpio.make_entry(HOOK_NAME, hook, mode=0o100755,
                                ino=ino_max + 1, mtime=0, nlink=1))
    body.append(trailer)
    new_main = cpio.build(body)
    print(f"hook added: {HOOK_NAME.decode()} ({len(hook)} B), main {len(new_main)} B")

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
    assert by_name_c[HOOK_NAME] == hook, "C5 hook round-trip mismatch"
    assert by_name_c[B_HOOK] == b_hook, "lever-B hook was altered"
    assert len(ents_c) == len(entries) + 1, "unexpected entry count change"
    print("round-trip: C5 hook identical, B hook untouched, +1 entry")

    open(OUT, "wb").write(out)
    print(f"OK: {OUT} ({len(out)} B), hook={HOOK_NAME.decode()}")
    print("md5: " + hashlib.md5(out).hexdigest())
    print("sha256: " + hashlib.sha256(out).hexdigest())
    return 0


if __name__ == "__main__":
    sys.exit(main())
