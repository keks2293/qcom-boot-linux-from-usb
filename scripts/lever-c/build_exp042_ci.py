#!/usr/bin/env python3
"""Build the EXP-042 routing-capture image over dbgC8.

Base: the dbgC8 image (CI kernel a699dd6 + CI ramdisk + the lever-B ULog
      hook v2 + the lever-C v8 hook), currently on the "ARMADA" FAT32 boot
      stick (md5 52c888a01f0470fb35f2b1a028209e9f -- asserted).  The base's
      90-armada-ulog-b.sh is asserted byte-identical to armada-ulog-b2.sh
      and its 91-armada-usb-fix-c.sh to armada-usb-fix-c8.sh (provenance:
      this is really dbgC8).

REPLACES the 91 initqueue hook:
      var/lib/dracut/hooks/initqueue/91-armada-usb-fix-c.sh
  with scripts/lever-c/armada-exp042-e.sh (EXP-042, the READ-ONLY
  data-path capture: at up=15/30/60 s in `linux usb` mode it diffs the
  full SPMI 0-07 (repeater PMIC) regmap window against the shipped
  working baseline and prints every differing register; the lever-C
  chain work is deleted so nothing perturbs the ABL handoff state).

ADDs to the initramfs:
      etc/armada/                              (directory)
      etc/armada/exp042-baseline-0-07.regmap   (0644, 65536 lines: the
      working-mode baseline captured 2026-11-14 in the full-system
      dock+PD boot -- the same topology as the EXP-042 failing run;
      logs/lever-c/exp042-baseline-0-07-working.regmap in the repo)

Everything else (kernel, cmdline, lever-B hook, all initramfs content)
is preserved.  Boot-image invariants as always: magic ANDROID!,
hdr[20:576] byte-identical to base, sha1_id recomputed at 576 (dbg43
lesson: never zero the header).

Usage: python3 build_exp042_ci.py [BASE_IMAGE]
  BASE_IMAGE defaults to /tmp/opencode/armada-stick/KERNEL (the mounted
  "ARMADA" stick).  Output: KERNEL.ci-a699dd6-exp042 next to this file.
"""
import hashlib
import struct
import sys
from pathlib import Path

import cpio

# zstd: PyPI `zstandard` if present, else the stdlib (Python >= 3.14)
try:
    import zstandard as zstd
except ImportError:  # pragma: no cover - depends on the environment
    from compression import zstd as _cz

    class _Decomp:
        def decompress(self, data, max_output_size=None):
            return _cz.decompress(data)

    class _Comp:
        def __init__(self, level=3):
            self.level = level

        def compress(self, data):
            return _cz.compress(data, level=self.level)

    class zstd:  # noqa: A001 - mirror the PyPI module surface
        ZstdDecompressor = _Decomp
        ZstdCompressor = _Comp


HERE = Path(__file__).resolve().parent
BASE_DEFAULT = Path("/tmp/opencode/armada-stick/KERNEL")
BASE_MD5 = "52c888a01f0470fb35f2b1a028209e9f"  # dbgC8 (the EXP-037 artifact)
OUT = HERE / "KERNEL.ci-a699dd6-exp042"
HOOK_SRC = HERE / "armada-exp042-e.sh"
C8_HOOK_SRC = HERE / "armada-usb-fix-c8.sh"
B_HOOK_SRC = HERE / "armada-ulog-b2.sh"
BASELINE_SRC = HERE.parent.parent / "logs" / "lever-c" / "exp042-baseline-0-07-working.regmap"
C_HOOK = b"var/lib/dracut/hooks/initqueue/91-armada-usb-fix-c.sh"
B_HOOK = b"var/lib/dracut/hooks/initqueue/90-armada-ulog-b.sh"
DIR_ARMADA = b"etc/armada"
BASELINE_NAME = b"etc/armada/exp042-baseline-0-07.regmap"


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
    base_path = Path(sys.argv[1]) if len(sys.argv) > 1 else BASE_DEFAULT
    d = open(base_path, "rb").read()
    base_md5 = hashlib.md5(d).hexdigest()
    assert base_md5 == BASE_MD5, \
        f"base md5 {base_md5} != dbgC8 {BASE_MD5} ({base_path})"

    hook = HOOK_SRC.read_bytes()
    assert hook.startswith(b"#!/bin/sh"), "hook must be /bin/sh"
    assert len(hook) > 5000, f"hook too small: {len(hook)} B"
    assert b"/dev/kmsg" in hook and b"ARMADA-E:" in hook, \
        "kmsg output markers missing"
    # the gate + the schedule + the read-only contract
    assert b"dr_mode" in hook and b"not linux-usb mode" in hook, \
        "linux-usb mode gate missing"
    assert b"otg enable: 1" in hook, "VBUS proxy (lever-B kmsg line) missing"
    # the baseline + the volatile set (the self-drifting registers)
    assert b"/etc/armada/exp042-baseline-0-07.regmap" in hook, \
        "in-image baseline path missing"
    assert b"260f 28eb 28ee 3ae2 3ae4 4f90 4fa0 4fc0" in hook, \
        "volatile-register set missing"
    # the capture output markers (OCR anchors)
    for m in (b"E042-T0", b"E042-T t=", b"E042-CTX", b"E042-ACT",
              b"E042-WRN", b"E042-KEY", b"E042-DIFF", b"E042-SUM",
              b"E042-NONVOL", b"E042-CAP-DONE", b"E042-DONE",
              b"E042-READFAIL", b"E042-NOREGMAP", b"E042-BASEBAD",
              b"E042-NEWSD", b"E042-SCAN"):
        assert m in hook, f"capture marker {m.decode()} missing"
    # the bounded reads (the hook must never hang)
    assert b"timeout 55 cat" in hook, "bounded full-window read missing"
    assert b"timeout 55 tail -c +582913" in hook, \
        "bounded candidate-window read missing"
    assert b"timeout 5 ls /sys/kernel/debug/regmap/" in hook, \
        "bounded regmap listing missing"
    assert b"timeout 5 mount -t debugfs" in hook, \
        "debugfs mount-on-demand missing"
    # the v8 scan-based regmap resolution (never a hard-coded path)
    assert b"/sys/bus/spmi/devices/" in hook, "spmi-name intersection missing"
    assert b"fd08:*" in hook and b"fd46:*" in hook and b'"80"' in hook, \
        "repeater signature match missing"
    # the console quieting around the read (v7 pattern)
    assert b"dmesg -n 1" in hook and b"/proc/sys/kernel/printk" in hook, \
        "console quieting missing"
    # the no-sysfs-resolution disk detection (the v4 2 s/LUN lesson)
    assert b"/proc/partitions" in hook, "/proc/partitions disk set missing"
    assert b"65536" in hook, "window geometry check missing"
    # NEGATIVE asserts: no lever-C chain work, no c8 residue, no writes
    assert b"ESCALATE" not in hook, "chain-work marker present (read-only image)"
    assert b"unbind" not in hook, "chain-work marker present (read-only image)"
    assert b"rebind" not in hook, "chain-work marker present (read-only image)"
    assert b"_ac_" not in hook, "c8 variable prefix present"
    assert b"ARMADA-C:" not in hook, "c8 kmsg prefix present"
    assert b"echo fd" not in hook, "hook must not write registers"

    b_hook = B_HOOK_SRC.read_bytes()
    assert b_hook.startswith(b"#!/bin/sh"), "B hook must be /bin/sh"
    c8_hook = C8_HOOK_SRC.read_bytes()
    assert c8_hook.startswith(b"#!/bin/sh"), "C8 hook must be /bin/sh"

    baseline = BASELINE_SRC.read_bytes()
    blines = baseline.split(b"\n")
    assert len(blines) == 65537 and blines[-1] == b"", \
        f"baseline geometry: {len(blines)} chunks (expected 65536 lines + trailing NL)"
    assert blines[0] == b"0000: XX", f"baseline first line: {blines[0]!r}"
    assert b"fd00: 02" in baseline, \
        "baseline is not the working-mode capture (fd00 must be 02)"
    assert len(baseline) == 589824, \
        f"baseline size {len(baseline)} (expected 589824)"

    assert d[:8] == b"ANDROID!", "not boot image"
    ks, = struct.unpack_from("<I", d, 8)
    rs, = struct.unpack_from("<I", d, 16)
    pg, = struct.unpack_from("<I", d, 36)
    kernel = d[pg:pg + ks]
    ram_off = pg + rup(ks, pg)
    ram = d[ram_off:ram_off + rs]
    rest = d[ram_off + rs:]
    print(f"base: {base_path} ks={ks} rs={rs} pg={pg} rest={len(rest)}")

    early, main_cpio = unpack_ram(ram)
    entries, _, _ = cpio.parse(main_cpio)
    names = [e["name"] for e in entries]
    print(f"main cpio entries={len(entries)} early={len(early)}")
    assert B_HOOK in names, "lever-B hook missing from the base image"
    assert C_HOOK in names, "lever-C hook missing from the base image"
    assert DIR_ARMADA not in names, "etc/armada already present (unexpected)"
    assert BASELINE_NAME not in names, "baseline already present (unexpected)"
    by_name = {e["name"]: e["data"] for e in entries}
    assert by_name[B_HOOK] == b_hook, \
        "base lever-B hook != armada-ulog-b2.sh (base is not dbgC8)"
    assert by_name[C_HOOK] == c8_hook, \
        "base 91 hook != armada-usb-fix-c8.sh (base is not dbgC8)"
    assert names[-1] == b"TRAILER!!!", f"last entry not TRAILER: {names[-1]}"

    # the 91 hook EXISTS in the base -- REPLACE it (never leave a
    # duplicate entry); ADD the etc/armada dir + the baseline file (dir
    # before file: the kernel extracts in entry order)
    trailer = entries[-1]
    n_old = sum(1 for e in entries if e["name"] == C_HOOK)
    assert n_old == 1, f"expected exactly one 91 hook in the base, got {n_old}"
    body = [e for e in entries[:-1] if e["name"] != C_HOOK]
    ino_max = max(e["ino"] for e in entries) if entries else 0
    body.append(cpio.make_entry(DIR_ARMADA, b"", mode=0o40755,
                                ino=ino_max + 1, mtime=0, nlink=1))
    body.append(cpio.make_entry(BASELINE_NAME, baseline, mode=0o100644,
                                ino=ino_max + 2, mtime=0, nlink=1))
    body.append(cpio.make_entry(C_HOOK, hook, mode=0o100755,
                                ino=ino_max + 3, mtime=0, nlink=1))
    body.append(trailer)
    new_main = cpio.build(body)
    print(f"hook replaced ({len(hook)} B) + etc/armada dir + baseline "
          f"({len(baseline)} B); main {len(new_main)} B")

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

    # round-trip: extract the hook, the baseline and the lever-B hook
    # from the built image, byte-compare
    _, main_c = unpack_ram(out[ram_off_c:ram_off_c + rs_c])
    ents_c, _, _ = cpio.parse(main_c)
    by_name_c = {e["name"]: e["data"] for e in ents_c}
    assert by_name_c[C_HOOK] == hook, "exp042 hook round-trip mismatch"
    assert by_name_c[B_HOOK] == b_hook, "lever-B hook was altered"
    assert by_name_c[BASELINE_NAME] == baseline, "baseline round-trip mismatch"
    assert len(ents_c) == len(entries) + 2, "unexpected entry count change"
    # dir-before-file order for the new entries
    idx_dir = next(i for i, e in enumerate(ents_c) if e["name"] == DIR_ARMADA)
    idx_bl = next(i for i, e in enumerate(ents_c) if e["name"] == BASELINE_NAME)
    assert idx_dir < idx_bl, "etc/armada dir must precede the baseline file"
    print("round-trip: hook identical, baseline identical, B hook "
          "untouched, entry count +2, dir before file")

    open(OUT, "wb").write(out)
    print(f"OK: {OUT} ({len(out)} B), hook={C_HOOK.decode()}")
    print("md5: " + hashlib.md5(out).hexdigest())
    print("sha256: " + hashlib.sha256(out).hexdigest())
    return 0


if __name__ == "__main__":
    sys.exit(main())
