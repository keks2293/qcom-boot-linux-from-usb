#!/usr/bin/env python3
"""Build a debug-injected boot image over the original CI a699dd6 KERNEL.

Base: diag/KERNEL.ci-a699dd6-original-extracted (CI kernel with patch 1400 +
      original CI ramdisk/cmdline). Adds a dracut initqueue-timeout hook that
      dumps 1400-diagnosis state to console (KERN_EMERG/kmsg + tty0), visible
      despite quiet/loglevel=3. Kernel, cmdline, and all existing initramfs
      content are preserved; only one hook file is added to the main (zstd)
      cpio.

Repetition fix (self-contamination): the hook's own lines are written to
/dev/kmsg, so a naive `dmesg | grep` on the next iteration re-captures the
hook's own output (header lines contain PDR/xhci/dwc3/ucsi keywords) and the
tail-80 section fills with repeated DBG1400 lines, evicting the real kernel
timeline. Fixes: (1) `grep -v 'DBG1400'` in both dmesg greps; (2) kmsg gets
the full snapshot only when the body changed since the previous iteration
(else a one-line heartbeat), so the dmesg ring is not flooded with repeated
full dumps (CI cmdline has no log_buf_len -> default ring).
"""
import hashlib
import struct
import sys
from pathlib import Path

import cpio
import zstandard as zstd

HERE = Path(__file__).resolve().parent
BASE = HERE / "KERNEL.ci-a699dd6-original-extracted"
OUT = HERE / "KERNEL.ci-a699dd6-dbg1400"
HOOK_NAME = b"var/lib/dracut/hooks/initqueue/timeout/99-armada-dbg1400.sh"

HOOK = r'''#!/bin/sh
# ARMADA dbg1400: 1400 pre-plug diagnosis (runs on dracut initqueue timeout)
# Repetition fix: (1) `grep -v 'DBG1400'` excludes the hook's own kmsg lines
#   from the dmesg greps (no self-re-capture / repeated DBG1400 lines);
#   (2) full snapshot to /dev/kmsg only when the body changed, else a
#   one-line heartbeat (no repeated full dumps in the dmesg ring).
(
  _i=0
  _prevbody=""
  while [ "${_i}" -lt 90 ]; do
    _up=$(cut -d" " -f1 /proc/uptime 2>/dev/null)
    {
      echo "-- cmdline:"; cat /proc/cmdline 2>/dev/null
      echo "-- [DT] usb@a600000 runtime props:"
      for b in /proc/device-tree/soc@0/usb@a600000 /sys/firmware/devicetree/base/soc@0/usb@a600000; do
        [ -e "$b" ] || continue
        echo "  base=$b"
        for p in dr_mode usb-role-switch role-switch-default-mode; do
          if [ -e "$b/$p" ]; then printf "  %s=" "$p"; tr '\000' ' ' < "$b/$p" 2>/dev/null; echo; else echo "  $p=ABSENT"; fi
        done
      done
      echo "-- usb_role class:"; ls /sys/class/usb_role 2>&1; for r in /sys/class/usb_role/*; do [ -e "$r/role" ] || continue; echo "  ${r##*/} role=$(cat "$r/role" 2>/dev/null)"; done
      echo "-- typec:"; ls /sys/class/typec 2>&1
      for p in /sys/class/typec/port0; do
        [ -e "$p" ] || continue
        for a in data_role power_role power_operation_mode vconn_source; do [ -e "$p/$a" ] && echo "  port0/$a=$(cat "$p/$a" 2>/dev/null)"; done
        [ -d "$p-partner" ] && echo "  partner=PRESENT" || echo "  partner=ABSENT"
      done
      [ -d /sys/kernel/debug/usb/ucsi ] && echo "-- ucsi debugfs: PRESENT" || echo "-- ucsi debugfs: ABSENT"
      echo "-- power_supply qcom-battmgr-usb:"; for a in usb_type voltage_now online status; do [ -e /sys/class/power_supply/qcom-battmgr-usb/$a ] && echo "  $a=$(cat /sys/class/power_supply/qcom-battmgr-usb/$a 2>/dev/null)"; done
      echo "-- usb devices:"; ls /sys/bus/usb/devices 2>&1
      echo "-- by-uuid:"; ls /dev/disk/by-uuid 2>&1
      echo "-- block:"; ls /sys/block 2>&1
      echo "-- remoteproc:"; for _r in /sys/class/remoteproc/*; do [ -e "$_r/name" ] || continue; echo "  ${_r##*/} name=$(cat "$_r/name" 2>/dev/null) state=$(cat "$_r/state" 2>/dev/null)"; done
      echo "-- dmesg 1400-marker:"; dmesg 2>/dev/null | grep -v 'DBG1400' | grep -E 'dr_mode=host ignored|usb-role-switch present, using OTG' | tail -5
      echo "-- dmesg PDR/ADSP/xhci/dwc3/role/ucsi/icm (tail 80):"
      dmesg 2>/dev/null | grep -v 'DBG1400' | grep -E 'remoteproc.*adsp|PDR|pd-mapper|xhci-hcd|dwc3|dwc3-qcom|usb_role|role.switch|ucsi|pmic_glink|icm_ncp|charger|usb 1-1|New USB device|reset high-speed' | tail -80
    } > /tmp/dbg1400.body 2>&1
    {
      echo "===== ARMADA DBG1400 (iter ${_i}) up=${_up}s ====="
      cat /tmp/dbg1400.body
      echo "===== END DBG1400 (iter ${_i}) refresh 8s ====="
    } > /tmp/dbg1400.txt 2>&1
    printf '\033[2J\033[H' > /dev/tty0 2>/dev/null
    printf '\033[2J\033[H' > /dev/console 2>/dev/null
    _curbody=$(cat /tmp/dbg1400.body 2>/dev/null)
    if [ -n "$_prevbody" ] && [ "$_curbody" = "$_prevbody" ]; then
      echo "<0>DBG1400: (iter ${_i} up=${_up}s: no change)" > /dev/kmsg 2>/dev/null
    else
      while IFS= read -r _l; do echo "<0>DBG1400: ${_l}" > /dev/kmsg 2>/dev/null; done < /tmp/dbg1400.txt
    fi
    _prevbody="$_curbody"
    _i=$((_i+1))
    sleep 8
  done
) >/dev/null 2>&1 &
'''


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
    # keep TRAILER last
    assert names[-1] == b"TRAILER!!!", f"last entry not TRAILER: {names[-1]}"
    trailer = entries[-1]
    body = entries[:-1]
    ino_max = max(e["ino"] for e in entries) if entries else 0
    body.append(cpio.make_entry(HOOK_NAME, HOOK.encode(), mode=0o100755, ino=ino_max + 1, mtime=0, nlink=1))
    body.append(trailer)
    new_main = cpio.build(body)
    print(f"hook added: {HOOK_NAME.decode()} ({len(HOOK)} B), main now {len(new_main)} B")

    new_main_z = zstd.ZstdCompressor(level=15).compress(new_main)
    new_ram = early + new_main_z
    print(f"ramdisk: old {len(ram)} -> new {len(new_ram)} (delta {len(new_ram)-len(ram)})")

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

    open(OUT, "wb").write(out)
    print(f"OK: {OUT} ({len(out)} B), hook={HOOK_NAME.decode()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
