#!/usr/bin/env python3
"""Build the lever-B v2 debug image over the original CI a699dd6 KERNEL.

Base: diag/KERNEL.ci-a699dd6-original-extracted (CI kernel a699dd6 + CI
      ramdisk/cmdline). Adds ONE dracut hook file to the main (zstd) cpio:
      var/lib/dracut/hooks/initqueue/90-armada-ulog-b.sh

The hook (diag/armada-ulog-b2.sh) is lever B with the console-noise fix
from the dbgC run (2026-11-12): the line-82 `IFS= read -r _ab_v < "$1"`
emitted
  90-armada-ulog-b.sh: line 82: read: 0: read error: Resource temporarily
  unavailable
because qcom_battmgr's qcom_battmgr_usb_get_property() returns -EAGAIN
while !service_up (drivers/power/supply/qcom_battmgr.c:1006-1007; the
service comes up with the ADSP, ~PDR @3.5 s, and this hook starts polling
qcom-battmgr-usb/* at initqueue ~2.7-4 s).  The read's stderr is now
suppressed (the value already fell back to '?'); nothing else changed.

Everything else (kernel, cmdline, all initramfs content) is preserved.
Boot-image invariants as always: magic ANDROID!, hdr[20:576] byte-identical
to base, sha1_id recomputed at 576 (dbg43 lesson: never zero the header).
"""
import hashlib
import struct
import sys
from pathlib import Path

import cpio
import zstandard as zstd

HERE = Path(__file__).resolve().parent
BASE = HERE / "KERNEL.ci-a699dd6-original-extracted"
OUT = HERE / "KERNEL.ci-a699dd6-dbgB2"
HOOK_SRC = HERE / "armada-ulog-b2.sh"
HOOK_NAME = b"var/lib/dracut/hooks/initqueue/90-armada-ulog-b.sh"


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


def main():
    hook = HOOK_SRC.read_bytes()
    assert hook.startswith(b"#!/bin/sh"), "hook must be /bin/sh"
    assert len(hook) > 1000, f"hook too small: {len(hook)} B"
    # v2 marker: the EAGAIN-suppressed read
    assert b"2>/dev/null || _ab_v='?'" in hook, "v2 fix marker missing"

    d = open(BASE, "rb").read()
    assert d[:8] == b"ANDROID!", "not boot image"
    ks, = struct.unpack_from("<I", d, 8)
    rs, = struct.unpack_from("<I", d, 16)
    pg, = struct.unpack_from("<I", d, 36)
    kernel = d[pg : pg + ks]
    ram_off = pg + rup(ks, pg)
    ram = d[ram_off : ram_off + rs]
    rest = d[ram_off + rs :]
    print(f"base: ks={ks} rs={rs} pg={pg} rest={len(rest)}")

    z = ram.find(b"\x28\xb5\x2f\xfd")
    assert z > 0, f"zstd magic not found: {z}"
    early = ram[:z]
    main_cpio = zstd.ZstdDecompressor().decompress(ram[z:], max_output_size=1 << 31)
    entries, _, _ = cpio.parse(main_cpio)
    names = [e["name"] for e in entries]
    print(f"main cpio entries={len(entries)} early={len(early)} z@{z}")
    assert HOOK_NAME not in names, f"hook already present: {HOOK_NAME}"
    assert names[-1] == b"TRAILER!!!", f"last entry not TRAILER: {names[-1]}"
    trailer = entries[-1]
    body = entries[:-1]
    ino_max = max(e["ino"] for e in entries) if entries else 0
    body.append(cpio.make_entry(HOOK_NAME, hook, mode=0o100755, ino=ino_max + 1, mtime=0, nlink=1))
    body.append(trailer)
    new_main = cpio.build(body)
    print(f"hook added: {HOOK_NAME.decode()} ({len(hook)} B), main now {len(new_main)} B")

    new_main_z = zstd.ZstdCompressor(level=15).compress(new_main)
    new_ram = early + new_main_z
    print(f"ramdisk: old {len(ram)} -> new {len(new_ram)} (delta {len(new_ram) - len(ram)})")

    # rebuild boot image (kernel unchanged)
    ks_new = len(kernel)
    rs_new = len(new_ram)
    kern_padded = kernel.ljust(rup(ks_new, pg), b"\x00")
    hdr = bytearray(d[:pg])
    struct.pack_into("<I", hdr, 8, ks_new)
    struct.pack_into("<I", hdr, 16, rs_new)
    assert bytes(hdr[0:8]) == b"ANDROID!"
    assert bytes(hdr[20:576]) == d[20:576], "hdr[20:576] changed"
    out = bytes(hdr) + kern_padded + new_ram + rest
    out = bytearray(out)
    out[576:596] = sha1_id(out[pg : pg + ks_new], out[pg + rup(ks_new, pg) : pg + rup(ks_new, pg) + rs_new])
    out = bytes(out)

    # verify
    assert out[:8] == b"ANDROID!"
    assert out[20:576] == d[20:576]
    ks_c, = struct.unpack_from("<I", out, 8)
    rs_c, = struct.unpack_from("<I", out, 16)
    ram_off_n = pg + rup(ks_c, pg)
    assert out[ram_off_n : ram_off_n + rs_c] == new_ram
    assert out[ram_off_n + rs_c :] == rest
    assert out[576:596] == sha1_id(out[pg : pg + ks_c], out[ram_off_n : ram_off_n + rs_c])

    # re-extract the hook from the built image and compare byte-for-byte
    ram_c = out[ram_off_n : ram_off_n + rs_c]
    z_c = ram_c.find(b"\x28\xb5\x2f\xfd")
    main_c = zstd.ZstdDecompressor().decompress(ram_c[z_c:], max_output_size=1 << 31)
    ents_c, _, _ = cpio.parse(main_c)
    hook_c = next(e["data"] for e in ents_c if e["name"] == HOOK_NAME)
    assert hook_c == hook, "hook round-trip mismatch"
    print("hook round-trip: identical")

    open(OUT, "wb").write(out)
    print(f"OK: {OUT} ({len(out)} B), hook={HOOK_NAME.decode()}")
    print("md5: " + hashlib.md5(out).hexdigest())
    print("sha256: " + hashlib.sha256(out).hexdigest())
    return 0


if __name__ == "__main__":
    sys.exit(main())
