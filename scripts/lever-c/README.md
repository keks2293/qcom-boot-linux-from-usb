# Lever C: the hook sources, the build chain, and the test harness

This directory holds the **exact** files that produced every lever-C image
from `dbgC2` to `dbgC8`, so the whole series is reproducible from the CI base
image. Experiment IDs: [../../docs/EXPERIMENTS.md](../../docs/EXPERIMENTS.md);
narrative: [../../docs/LEVER_C_IMPLEMENTATION.md](../../docs/LEVER_C_IMPLEMENTATION.md)
§3, §11, §12.

## Files

| file | what it is | image | experiment |
|---|---|---|---|
| `armada-ulog-b.sh` | lever-B v1 ULog hook (`90-armada-ulog-b.sh`) | `dbgB` | EXP-026 |
| `armada-ulog-b2.sh` | lever-B v2 ULog hook — the base prerequisite for the C series | `dbgB2` | — |
| `armada-usb-fix-c.sh` | lever-C v1 hook (the hook race; see §3 of the narrative) | `dbgC` | EXP-028…030 |
| `armada-usb-fix-c2.sh` … `-c8.sh` | lever-C hooks v2…v8 | `dbgC2`…`dbgC8` | EXP-031…037 |
| `build_dbg1400_ci.py` | builder: CI `KERNEL` → `dbg1400` (patch-1400 diagnostics) | `dbg1400` | EXP-023 |
| `build_dbgB_ci.py` | builder: CI `KERNEL` → `dbgB` | `dbgB` | EXP-026 |
| `build_dbgB2_ci.py` | builder: CI `KERNEL` → `dbgB2` (adds the ULog hook) | `dbgB2` | — |
| `build_dbgC_ci.py` | builder: `dbgB` → `dbgC` (hook v1) | `dbgC` | EXP-028…030 |
| `build_dbgC2_ci.py` … `build_dbgC8_ci.py` | builders, one per image, with the invariant asserts | `dbgC2`…`dbgC8` | EXP-031…037 |
| `cpio.py` | minimal newc cpio reader/writer used by the builders | — | — |
| `fake-test-c8.sh` | fake-sysfs harness for v8 (11 boot modes) | — | — |

## The build chain

Every builder reads a base image from **this directory** and writes the next
one here. The chain is:

```
CI KERNEL (a699dd6, PR #704 artifact)
  ├─ build_dbg1400_ci.py → dbg1400          (patch-1400 diagnostics)
  ├─ build_dbgB_ci.py    → dbgB             (+ 90-armada-ulog-b.sh, v1)
  │    └─ build_dbgC_ci.py → dbgC   (hook v1)
  └─ build_dbgB2_ci.py   → dbgB2            (+ 90-armada-ulog-b.sh, v2)
       ├─ build_dbgC2_ci.py → dbgC2  (hook v2)
       ├─ build_dbgC3_ci.py → dbgC3  (hook v3)
       ├─ build_dbgC4_ci.py → dbgC4  (hook v4)
       └─ build_dbgC5_ci.py → dbgC5  (hook v5)
            └─ build_dbgC6_ci.py → dbgC6   (hook v6: + register dump)
                 └─ build_dbgC7_ci.py → dbgC7  (hook v7: + step markers)
                      └─ build_dbgC8_ci.py → dbgC8  (hook v8: scan-based dump)
```

`dbgC2`…`dbgC5` are independent of each other (all built from `dbgB2`), so
only the path to the image you want is needed.

## Getting the CI base image

The builders do not download anything. Obtain the CI boot image once:

1. armada PR #704, CI artifact `armada-disk-pr704` (run 42324657729, kernel
   `a699dd6`) — see [../../docs/KERNEL_PATCH_1400.md](../../docs/KERNEL_PATCH_1400.md).
2. Unpack the disk image and extract the Android boot image (`KERNEL`); the
   exact offset is printed by the CI build. Save it here as
   `KERNEL.ci-a699dd6-original-extracted` (the name `build_dbgB2_ci.py`
   expects).
3. `python3 build_dbgB2_ci.py` → `KERNEL.ci-a699dd6-dbgB2`.

Each builder asserts the provenance of its base (the previous hook is
byte-identical to the previous version's source), so a wrong base fails
loudly instead of producing a silently different image.

## What the hook is

The hook is a single file inside the dracut initramfs:

```
var/lib/dracut/hooks/initqueue/91-armada-usb-fix-c.sh
```

Dracut sources the `initqueue` directory about every 0.5 s, so the hook must
be **idempotent**: it uses a done-marker, `_ac_`-prefixed variables, a
background subshell, no top-level `exit`, no `set -e`/`set -u`, and it is
inert in a normal boot (the `linux usb` gate is `dr_mode=host` in the live
FDT, which ABL adds only in that mode).

It does two independent things:

1. **Lever C proper** (v2…v8): after the `charger_pd` PDR and the Type-C role
   flip, if no USB disk has appeared, run a full-chain reset
   (unbind UCSI → xHCI → dwc3, rebind dwc3 → UCSI, let UCSI re-run
   `GET_CONNECTOR_STATUS`), then re-scan. Prints `ENUMERATION OK` /
   `FAIL-NO-SCAN` / `FAIL-NO-SCAN-FULL` plus a one-shot tree dump.
2. **The eUSB2 repeater register dump** (v6…v8): after the chain, read the
   repeater's `0xfd00–0xfd5b` window from debugfs and print it.

## The dump, v8 in one paragraph

v6/v7 resolved the repeater's platform device through
`/sys/bus/platform/devices/*eusb2*` and its symlinks; EXP-036 proved that
this resolve hangs in this environment (the console stops right after
"globbing platform devices", with debugfs already mounted). v8 therefore
does not resolve anything: it lists `/sys/bus/spmi/devices/` and
`/sys/kernel/debug/regmap/`, intersects the names, reads the window of every
candidate and identifies the repeater by its own signature
(`0xfd08 = RPTR_OK 0x80`, `0xfd46 = RPTR_EN 0x80`). Nothing is hard-coded,
and every external step is under `timeout(1)`, so the hook cannot hang.

Reading geometry: the debugfs `registers` file is one line per register,
`"XXXX: XX\n"` (9 bytes); `0xfd00` is line 582912 (0-based), so the window is
`tail -c +582913 | sed -n 1,92p`. Beware: `regmap_read_debugfs` iterates to
`max_register` (0xffff), so the read touches 768 addresses — a few hundred
milliseconds, and the output appears only when the single `read(2)`
completes.

## Prerequisites

- Kernel with `CONFIG_REGMAP_DEBUGFS=y` (the CI kernel `a699dd6` has it).
- Python 3 with `zstandard` (`pip install zstandard`) on the build host; the
  builders parse and rebuild the Android boot image and the zstd cpio in
  place.
- The CI base image (see above).

## Running the harness

```bash
cd scripts/lever-c
sh fake-test-c8.sh            # all 11 modes
sh fake-test-c8.sh norp       # one mode
```

The harness builds a fake sysfs tree under `${TMPDIR:-/tmp}/armada-c8-test`,
stubs the tools that differ on the host (`date`, `stat`, `dmesg`, `timeout`,
`mount`, `sed`, `tail`, …), sources the hook in a loop like dracut does, and
asserts on the console markers. It needs no root and no device. A full pass
takes several minutes (each mode runs the real ~0.5 s sourcing loop).

## Rebuilding an image

```bash
python3 build_dbgC8_ci.py
```

The builder asserts, before writing anything: `ANDROID!` magic, the header
`[20:576]` byte-identical to the base, the kernel byte-identical, the
recomputed SHA1 id at offset 576, and an initramfs round-trip that replaces
exactly one hook entry. Output: `KERNEL.ci-a699dd6-dbgC8`
(202 116 935 B, md5 `52c888a01f0470fb35f2b1a028209e9f`).
