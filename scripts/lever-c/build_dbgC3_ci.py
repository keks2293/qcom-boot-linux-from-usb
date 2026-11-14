#!/usr/bin/env python3
"""Build the lever-C v3 image (dbgC3: v2 logic + device-tree snapshot) over dbgB2.

Base: diag/KERNEL.ci-a699dd6-dbgB2 (CI kernel a699dd6 + CI ramdisk + the
      lever-B ULog hook v2 with the EAGAIN-suppressed read).  The base's
      90-armada-ulog-b.sh is asserted byte-identical to diag/armada-ulog-b2.sh
      (provenance: this is really dbgB2, not the old dbgB).
Adds ONE dracut hook file to the main (zstd) cpio:
      var/lib/dracut/hooks/initqueue/91-armada-usb-fix-c.sh

WHY A NEW IMAGE NAME (dbgC3, not a rebuilt dbgC2): the 2nd hardware run
(2026-11-12) turned out to be ANOTHER v1 image -- the stick's KERNEL
(md5 506cb36f9eadd0459d064ac2f4883927) was byte-identical to
KERNEL.ci-a699dd6-dbgC, and the v2 image (md5 ab8621850dabacb25e851f8b19f8f7ac)
was never on the stick.  Both v1 runs died at the same FAIL-NO-DEV @3.1 s
before the lever-C test could run, and the quiet console + dead hook make it
impossible to tell "xhci created, scan ran, found nothing" from "xhci never
created".  dbgC2 (v2 hook) was never run on hardware either, so its md5 in
the notes is provenance-only; this run uses a distinct filename so the file
on the stick self-identifies.

The hook (diag/armada-usb-fix-c3.sh) is lever C v3: ALL v2 logic unchanged
(1) xhci absent at start is NOT an error -- wait for it (<=10 s); if present
(forced-host kernel) it is still unbound to discard the pre-PDR scan;
(2) the rebind is deferred until the charger_pd PDR (<=30 s) AND typec port0
power_role=[source] data_role=[host] -- the proxy for PPM having enabled the
OTG VBUS (<=15 s) -- AND xhci has appeared; (3) a disk from the first
post-flip scan is accepted without a rebind; then unbind/bind <=3 tries with
a hard stop on a new "Host halt failed, -110" (known qmp-combo defect, no
retry).  NEW in v3: a one-shot device-tree snapshot (_ac_tree) printed once
at up=10 s (tag t10) and on every timeout/failure path (WARN-nopdr,
WARN-norole, NO-DEV, halt-110, NO-SCAN) and after success (OK): children of
a600000.usb, /sys/class/usb_role/*/role, /sys/block, and the usb bus
(lsusb if present, else /sys/bus/usb/devices -- lsusb is NOT in the initramfs,
verified against the CI cpio).
dwc3-qcom/PHYs are NOT touched: UCSI holds a reference to the dwc3
usb-role-switch device; unbinding dwc3 would be a use-after-free.

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
OUT = HERE / "KERNEL.ci-a699dd6-dbgC3"
HOOK_SRC = HERE / "armada-usb-fix-c3.sh"
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
    assert len(hook) > 2000, f"hook too small: {len(hook)} B"
    assert b"/dev/kmsg" in hook and b"ARMADA-C:" in hook
    # v2 markers: the role wait and the xhci-absent-is-not-an-error path
    assert b"[source]" in hook and b"FAIL-NO-DEV" in hook, "v2 logic markers missing"
    # v3 markers: the device-tree snapshot and its fallbacks
    assert b"TREE[" in hook and b"usb_role" in hook, "v3 tree dump markers missing"
    assert b"command -v lsusb" in hook and b"/sys/bus/usb/devices/" in hook, \
        "v3 lsusb/sysfs fallback missing"
    assert b"_ac_maybedump" in hook and b"t10" in hook, "v3 once-at-10s dump missing"

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
    assert out[576:596] == sha1_id(out[pg:pg + ks_c], out[ram_off_c:ram_off_c + rs_c])

    # round-trip: extract both hooks from the built image, byte-compare
    _, main_c = unpack_ram(out[ram_off_c:ram_off_c + rs_c])
    ents_c, _, _ = cpio.parse(main_c)
    by_name_c = {e["name"]: e["data"] for e in ents_c}
    assert by_name_c[HOOK_NAME] == hook, "C3 hook round-trip mismatch"
    assert by_name_c[B_HOOK] == b_hook, "lever-B hook was altered"
    assert len(ents_c) == len(entries) + 1, "unexpected entry count change"
    print("round-trip: C3 hook identical, B hook untouched, +1 entry")

    open(OUT, "wb").write(out)
    print(f"OK: {OUT} ({len(out)} B), hook={HOOK_NAME.decode()}")
    print("md5: " + hashlib.md5(out).hexdigest())
    print("sha256: " + hashlib.sha256(out).hexdigest())
    return 0


if __name__ == "__main__":
    sys.exit(main())
