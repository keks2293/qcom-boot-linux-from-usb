#!/usr/bin/env python3
"""Build the lever-C v4 image (dbgC4) over dbgB2.

Base: diag/KERNEL.ci-a699dd6-dbgB2 (CI kernel a699dd6 + CI ramdisk + the
      lever-B ULog hook v2 with the EAGAIN-suppressed read).  The base's
      90-armada-ulog-b.sh is asserted byte-identical to diag/armada-ulog-b2.sh
      (provenance: this is really dbgB2, not the old dbgB).  Same base as
      dbgC2/dbgC3.
Adds ONE dracut hook file to the main (zstd) cpio:
      var/lib/dracut/hooks/initqueue/91-armada-usb-fix-c.sh
      (same in-image name as dbgC2/dbgC3; the image FILENAME is distinct so
      the file on the stick self-identifies -- runs 2-3 booted the v1 image
      because the stick was never md5-checked).

WHY dbgC4 (run 4, 2026-11-12, the first genuine dbgC3 run): FAIL-NO-SCAN
with a LIVE controller -- scan-events=0 in all three rebinds, two of them
post-VBUS (otg enable:1 at 5.44 s); "scan ordering is the whole bug"
refuted in the strong form.  Run 4 also disproved the v2/v3 gate: the typec
roles (3.66 s) are set by UCSI at port registration, ~1.8 s BEFORE the PPM
enabled the OTG VBUS -- the bare roles are not a post-VBUS proxy.

The hook (diag/armada-usb-fix-c4.sh) is lever C v4: v3 logic + (1) the
first rebind is gated on port0-partner (<=20 s, the real post-VBUS marker;
bounded WARN on forced-host kernels where UCSI never registers a port);
(2) the tree dump adds port0/orientation (reverse => flip the plug and
re-run the same image), partner yes/no, and the xhci -> usbN root-hub
mapping; (3) wait_disk is sped up (UFS-LUN cache, sleep 0.5, -110 check
every 2nd iteration); (4) the FULL-CHAIN ESCALATION on the FAIL-NO-SCAN /
FAIL-NO-DEV branches (the emergency shell takes no input, so the manual
full-chain test is impossible and the auto-escalation is the only beta-1/
beta-2 discriminator): unbind UCSI (AUXILIARY bus:
/sys/bus/auxiliary/drivers/pmic_glink_ucsi, device pmic_glink.ucsi.0 -- it
holds the dwc3 role-switch reference, ucsi.c:1837, so it must go first; on
failed UCSI unbind the escalation ABORTS and dwc3 is not touched) -> xhci
-> dwc3-qcom; rebind dwc3 first (re-registers the role switch; the UCSI
probe hard-fails without it, ucsi.c:1838-1840) -> UCSI, which then
completes the chain by itself (GET_CONNECTOR_STATUS -> partner UFP ->
set_role(HOST) -> xhci recreated -> fresh root-hub -> fresh scan).  The
recreated xhci may carry a new auto ID, so it is looked up by glob, never
hard-coded.  Verdicts: ENUMERATION OK (full-chain) (beta-1) /
FAIL-NO-SCAN-FULL (beta-2: blocker below dwc3) / FAIL-ESCALATE /
FAIL: Host halt -110 after full-chain reset.  The escalation lives only on
the failure branches -- the primary xhci-only verdict is untouched.

Everything else (kernel, cmdline, lever-B hook, all initramfs content) is
preserved. Boot-image invariants as always: magic ANDROID!, hdr[20:576]
byte-identical to base, sha1_id recomputed at 576 (dbg43 lesson: never zero
the header).
"""
import hashlib
import struct
import sys
from pathlib import Path

import cpio
import zstandard as zstd

HERE = Path(__file__).resolve().parent
BASE = HERE / "KERNEL.ci-a699dd6-dbgB2"
OUT = HERE / "KERNEL.ci-a699dd6-dbgC4"
HOOK_SRC = HERE / "armada-usb-fix-c4.sh"
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
    # v2/v3 markers (logic must still be there)
    assert b"[source]" in hook and b"FAIL-NO-DEV" in hook, "v2 logic markers missing"
    assert b"TREE[" in hook and b"usb_role" in hook, "v3 tree dump markers missing"
    assert b"command -v lsusb" in hook and b"/sys/bus/usb/devices/" in hook, \
        "v3 lsusb/sysfs fallback missing"
    assert b"_ac_maybedump" in hook and b"t10" in hook, "v3 once-at-10s dump missing"
    # v4 markers: the partner gate, the dump additions, the full-chain
    assert b"port0-partner" in hook and b"WARN-nopartner" in hook, \
        "v4 partner gate missing"
    assert b"orientation" in hook, "v4 orientation dump missing"
    assert b"/sys/bus/auxiliary/drivers/pmic_glink_ucsi" in hook, \
        "v4 UCSI aux-bus path missing"
    assert b"/sys/bus/platform/drivers/dwc3-qcom" in hook, \
        "v4 dwc3-qcom driver path missing"
    assert b"_ac_escalate" in hook and b"ESCALATE" in hook, "v4 escalation missing"
    assert b"ENUMERATION OK (full-chain)" in hook and b"FAIL-NO-SCAN-FULL" in hook, \
        "v4 full-chain verdicts missing"
    assert b"ESCALATE: unbind order ucsi -> xhci -> dwc3" in hook, \
        "v4 unbind order marker missing"
    assert b"rebind order dwc3 -> ucsi" in hook, "v4 rebind order marker missing"
    # the xhci-only verdicts must still exist (primary verdict untouched)
    assert b"FAIL-NO-SCAN: no USB disk after" in hook
    assert b"ENUMERATION OK (first post-PDR scan)" in hook

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
    assert by_name_c[HOOK_NAME] == hook, "C4 hook round-trip mismatch"
    assert by_name_c[B_HOOK] == b_hook, "lever-B hook was altered"
    assert len(ents_c) == len(entries) + 1, "unexpected entry count change"
    print("round-trip: C4 hook identical, B hook untouched, +1 entry")

    open(OUT, "wb").write(out)
    print(f"OK: {OUT} ({len(out)} B), hook={HOOK_NAME.decode()}")
    print("md5: " + hashlib.md5(out).hexdigest())
    print("sha256: " + hashlib.sha256(out).hexdigest())
    return 0


if __name__ == "__main__":
    sys.exit(main())
