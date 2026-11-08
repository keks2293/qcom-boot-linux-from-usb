# Current patch version: the CI test (2026-11-07) and the full-boot re-check

This records the state of the fix branch (Armada `initramfs-adsp`, PR #704)
after the mechanism was identified
([ABL_DR_MODE_HOST.md](ABL_DR_MODE_HOST.md),
[FULL_SYSTEM_MECHANISM_CAPTURE.md](FULL_SYSTEM_MECHANISM_CAPTURE.md)):
what the branch contains, the result of the first device test of the patched
kernel (2026-11-07), the next `linux usb` diagnostic image (`dbg1400`), and
the protocol for the **full-boot re-check** (the control experiment).

## TL;DR

- The branch now carries two changes: the dracut ADSP drop-in (ADSP driver +
  firmware in the initramfs) and **kernel patch 1400** (demote the
  bootloader's static `dr_mode=host` to OTG when `usb-role-switch` is
  present).
- 2026-11-07: a CI image built from the branch was flashed and booted in
  `linux usb` mode with the drive pre-plugged. The patch marker string is
  present in the flashed kernel, but the boot **still ends in the dracut
  root-wait timeout** — no enumeration.
- The follow-up `dbg1400` run (same kernel + CI initramfs + a dracut
  timeout-hook image) closed that observability gap: the **kernel-side chain
  of the fix works end-to-end** — the demotion fired, the role flipped to
  HOST after the PDR, ADSP is up, xHCI was created — while the **port power
  path stays dead** (`usb_type=[Unknown]`, `online=0`, ICM `icm_ncp_stby`:
  no VBUS, the pre-plugged drive never enumerates). The root-wait timeout is
  now trivially explained: the root filesystem lives on the drive itself (the
  CI disk image *is* the drive).
- Next steps: (1) a re-run with the **fixed** `dbg1400` build — the run used
  the pre-dedup build, whose own dump lines contaminated its dmesg tail — for
  a clean PDR→xHCI/ICM timeline; (2) a **full-boot re-check** with the same
  CI build (the control — it must still show the known-good ROLE-FLIP +
  FIRST SCAN behavior and confirm the patch is a no-op in a normal boot).

## What the current branch contains (PR #704, `initramfs-adsp`, HEAD `a699dd6`)

| commit | change | why |
|---|---|---|
| `68f68ad` | dracut drop-in `system_files/etc/dracut.conf.d/91-armada-adsp.conf`: `add_drivers += qcom_q6v5_pas` (resolves its 4 deps through `modules.dep`) + `install_items +=` the board ADSP firmware images | ADSP/PPM must be up **early** (initramfs): dracut's aarch64 whitelist ships neither the `remoteproc` driver nor the firmware (its name comes from the board DT, not `MODULE_FIRMWARE`), so without it the `charger_pd` PDR — which the fix depends on — never comes up in the initramfs |
| `a699dd6` | kernel patch `1400-dwc3-ignore-dr-mode-host-with-role-switch.patch` (+ `series` + `PATCHES.md`): in `dwc3_get_dr_mode()` (`drivers/usb/dwc3/core.c:53`), when `dwc->dr_mode == HOST` and the device declares `usb-role-switch`, demote to OTG with a `dev_warn` marker | the ABL overlay `dr_mode=host` (applied unconditionally in `linux usb` mode) forces the early host scan **before** the `charger_pd` PDR; that scan is absorbed by the ICM (`icm_ncp_stby`) and the pre-plugged drive is never enumerated — the unifying root cause. The demotion makes `linux usb` follow the full-system (known-good) OTG + role-flip sequence |

### Expected behavior with both in place, in `linux usb` mode — **partly refuted on device**

> **Prediction vs measurement (2026-11-07, `dbg1400`):** the first three lines
> held (OTG path taken, role-switch registered, role flipped to HOST after the
> PDR, xHCI created) — the fourth, *the first scan after the PDR enumerates the
> pre-plugged drive*, is **refuted**: the port never gets classified
> (`usb_type=[Unknown]`, `online=0`), so nothing enumerates. The prediction is
> kept below as originally written because it documents what the fix was
> expected to deliver.

- `dwc3` takes the OTG path → the `a600000.usb-role-switch` device is
  registered → the controller starts in the **DEVICE** role (no xHCI, no
  scan before the flip)
- after the `charger_pd` PDR (~3.5 s) the UCSI partner event flips the role
  to HOST → `xhci-hcd.N.auto` is created → **the first scan lands after the
  PDR** → the pre-plugged drive enumerates
- side effect: the UCSI `-EPROBE_DEFER` (waiting for a role-switch that never
  appeared in forced-HOST mode) disappears as well, because the role-switch
  device now exists

In a **normal boot** there is no `dr_mode` property, `dwc->dr_mode` is
already OTG, and the patch is a **no-op** — this is exactly what the
full-boot re-check confirms on the device.

## 2026-11-07: CI image test — patch present, still no enumeration

- Artifact: `armada-disk-pr704` (CI run 42324657729), built from `a699dd6`;
  the `KERNEL` was written to the flash and booted in `linux usb` mode, drive
  pre-plugged.
- **Patch presence verified in the flashed image**: the vmlinux decompressed
  from the boot image (v0 header, kernel @ `pg`) contains the marker string
  `dr_mode=host ignored: usb-role-switch present, using OTG` → 1400 is
  compiled in.
- **Result: dracut root-wait timeout** — the drive was not enumerated.
- **Observability gap**: the CI image boots `quiet` (loglevel 3), so the
  KERN_WARNING from 1400 does not reach the console, and the image carries
  no diagnostic block. Not known from this run:
  - did the demotion fire at runtime (does the runtime FDT carry both
    `dr_mode=host` and `usb-role-switch` as expected)?
  - was the role-switch device registered, and did the role flip to HOST
    after the PDR?
  - was there an xHCI probe at all, when (Δ vs the PDR), and did a first
    scan happen?
  - what is the ICM / `usb_type` state (`icm_ncp_stby` again)?
- A quick mechanical swap (CI kernel + the old dbg51 initramfs) produced no
  console output at all — an incompatible combination with the CI cmdline
  (`console=tty0 quiet …`); the original CI `KERNEL` was restored to the
  flash (the dracut-timeout output is back). The proper diagnostic is
  `dbg1400` (below), which keeps the CI ramdisk and cmdline intact.

### How to read the result

Binary-level presence of the patch plus the negative device result leaves
three candidates, which the two next tests separate:

1. **The demotion did not fire at runtime** (e.g. the runtime FDT does not
   carry both properties as expected) — `dbg1400` prints the runtime
   `[DT] dr_mode`/`usb-role-switch` directly.
2. **The demotion fired but the flip/enumeration failed** (UCSI partner
   handling, ICM state, timing) — `dbg1400` prints `usb_role`, the xHCI/PDR
   timeline, `usb_type`, and the ICM fingerprint.
3. **Enumeration happened but outside the root-wait window** — the CI image
   has no `95armada-usb-wait` module; `dbg1400` dumps the USB device list at
   the timeout moment.

The full-boot re-check is the **control**: it must still show the known-good
behavior on the *same* kernel. If it does not, the patch itself regressed the
normal path.

## 2026-11-07 (second run): `dbg1400` — the kernel-side chain works; the break is on the port power path

The `dbg1400` image was flashed and booted: `linux usb`, drive pre-plugged,
zero actions. The run used the **pre-dedup build** — the hook's own dump
lines (written to `/dev/kmsg`) re-appeared inside its own dmesg tail
(nested `DBG1400:` lines in the photos), evicting the real kernel timeline
from the tail-80 section. The fixed build (double `grep -v DBG1400` +
full-dump-on-change dedup; 202 106 472 B, md5 `91ee17b24a4a25b78ce49e74a190484e`)
is built, verified, and has been written to the drive for the re-run.

**What the photos show** (kernel-monotonic timestamps; the screen is
redrawn every 8 s, so a photo at any moment shows the current state):

| fact | value |
|---|---|
| 1400 marker in dmesg | `[164.06] dwc3 a600000.usb: dr_mode=host ignored: usb-role-switch present, using OTG` — the demotion **fired** |
| runtime `[DT]` (`/proc` + `/sys`) | `dr_mode=host` present **and** `usb-role-switch` present, `role-switch-default-mode` absent — the ABL overlay is present in the unspliced `linux usb` mode |
| `/sys/class/usb_role/a600000.usb-role-switch/role` | `host` — the role-switch device is registered (OTG path) and the role **flipped to HOST** |
| typec `port0` / `port0-partner` | `data_role={host} device`, partner **PRESENT**, `power_operation_mode=3.0A` |
| `qcom-battmgr-usb` | `usb_type=[Unknown]`, `online=0`, `voltage_now=5062000` — the `icm_ncp_stby` fingerprint |
| USB devices | only the two root hubs — the drive is **not enumerated** |
| `remoteproc0` (adsp) | `state=running` (the dracut ADSP drop-in works: driver + firmware in the initramfs) |
| `ucsi debugfs` | ABSENT — benign: debugfs is simply not mounted in the initramfs |
| duration | 6+ minutes of the identical state (hook iterations up to t≈366 s); boot ended in the dracut root-wait timeout |

**Verdict.** The kernel-side chain of the fix works end-to-end: demotion to
OTG → role-switch registered → ADSP up → `charger_pd` PDR → UCSI role flip to
HOST → xHCI created. The candidates "the flip does not happen", "xHCI is not
created" and "the snapshot precedes the chain" are all refuted by the photos.
The break is on the **power path side**: the ICM/PPM charger path never
classifies the port (`usb_type=[Unknown]`, `online=0`, `icm_ncp_stby`), so no
VBUS is driven onto the port — the pre-plugged drive is electrically dead,
never attaches, and is never enumerated (CC partner detection is alive:
`partner=PRESENT`; D+/D− are not).

**Why the root-wait timeout is trivial here.** The CI disk image *is* the
drive: identical MBR layout (525.3 MB FAT + 1 GiB + 27 GiB), the
`.armada-bootimg.id` boot marker found inside the image's p1, and the
cmdline `root=UUID=49a99c0a-…` found verbatim in the image's p3 superblock
region. The root filesystem lives on the drive — no enumeration, no root,
timeout. (Topology, for interpreting the by-uuid list: `mmcblk0` is the
eMMC — the full-boot root — and `sda–sdf` are the UFS LUNs, not USB.)

**Leading hypothesis (unproven).** In `linux usb` mode the ABL/XBL runs its
own closed USB host stack on this very port — it reads `\KERNEL` from the
drive. With the drive pre-plugged there is no fresh CC edge afterwards, and
the ICM in `ncp_stby` does not rescan: the PPM/ICM port state left by the ABL
host session is not re-classified at kernel handoff. In a normal boot the
bootloader never touches the port, PPM detects the drive fresh, and it
enumerates on the first post-PDR scan. The re-run with the fixed `dbg1400`
(clean dmesg tail) will measure the PDR→xHCI Δ, the flip timing, and the ICM
transitions; the full-boot control (same build, internal install, pre-plug)
confirms the other half.

**Reconciliation with the replug window (required — the hypothesis alone does
not fit).** The replug table in [INVESTIGATION.md](INVESTIGATION.md#the-replug-window-timing-correlation)
shows a fresh CC edge **works at ≤ ~24.7 s and fails at 38 s, 59 s and 102 s** —
in runs where the ABL host session is *identical*. If "no fresh edge" were the
whole story, a late replug would fix it too, and it does not. The two
observations are only compatible if **both** are true:

1. ABL's host session blocks the **initial** classification in `linux usb`
   (why pre-plug never classifies and why the full system — where ABL never
   touches the port — does), **and**
2. the PPM's classification window (`chg-heartbeat-timer-ms = 30000`,
   `poll-timer-ms = 40000`, see
   [ADSP_CONFIG.md](ADSP_CONFIG.md#timer--replug-correlation)) blocks **late**
   recovery, so an edge after ~38 s cannot rescue it either.

Model: the full system needs neither rescue (clean initial classification);
pre-plug in `linux usb` needs a re-classification that arrives *within* the
window. That is also why the two live levers are complementary — the
`dwc3`/scan-timing fix (1400, done) and an **edge-free re-arming** of
detection: the `apsd-rerun-cfg` 0→1 firmware patch (recipe ready, **still
untested on device**, dbg52 candidate) or a role/`unbind`-`bind` cycle run
**inside the ≤30 s window** (never run either — `dbg1400` only dumps at the
dracut timeout, ~160 s+).

**Secondary anomaly: the dwc3 probe timestamp (t≈164 s) is far later than the
full-boot xHCI probe (~14.8/17.75 s) and than the ~0.5 s `xhci-hcd` probe this
document attributes to the forced-HOST path.** Two readings, and they imply
different fixes: (a) the timestamp base in the photos is not kernel-monotonic
(hook-relative / redraw time) and the chain really ran early, leaving a pure
classification failure; or (b) the chain genuinely ran at ~164 s — far outside
the PPM's 30 s window, which by itself would explain the dead power path.
**Confirm the timestamp base first**, then measure the PDR→xHCI Δ with the
clean tail; do not treat 164 s as settled either way.

## `dbg1400` — the next `linux usb` diagnostic image

Built on top of the CI kernel (1400 compiled in) + the CI initramfs + the CI
cmdline, with a single dracut `initqueue/timeout` hook
(`var/lib/dracut/hooks/initqueue/timeout/99-armada-dbg1400.sh`, KERN_EMERG so
it prints despite `quiet`, 8 s refresh). At the root-wait timeout it dumps:

- runtime `[DT] dr_mode` / `usb-role-switch` (from `/proc/device-tree`) —
  did the demotion fire?
- `/sys/class/usb_role/*/role` — was the role-switch device registered, and
  what role is active?
- typec port/partner state, UCSI debugfs presence
- `qcom-battmgr-usb`: `usb_type`, voltage, online, status
- USB device tree / by-uuid / block devices — enumeration at the timeout
  moment?
- remoteproc state; dmesg filtered on the 1400 marker / PDR / ADSP / xhci /
  dwc3 / usb_role / ucsi / pmic_glink / icm_ncp / charger / `New USB device`

Design note (log repetitions): the hook's own lines are written to
`/dev/kmsg`, so both dmesg greps exclude the hook's own `DBG1400:` lines
(`grep -v DBG1400`) — without this, the tail-80 section re-captures the hook's
own output (its header lines contain the PDR/xhci/dwc3/ucsi keywords) and the
real kernel timeline gets evicted. The full snapshot is written to kmsg only
when the dump changed since the previous iteration (otherwise a one-line
heartbeat), so the dmesg ring is not flooded with repeated full dumps (the CI
cmdline has no `log_buf_len` → default ring size). The screen itself is
cleared and fully redrawn every 8 s, so a photo at any moment shows the
current state.

Protocol: `linux usb`, pre-plug, zero actions, photo of the final screen.

## Full-boot re-check (control experiment) — protocol

Goal: on the **same kernel** (1400 compiled in), confirm that a normal boot
still enumerates a pre-plugged drive with the known-good sequence, and that
the patch is a no-op there.

1. **Image**: the full CI disk `armada-20261106.1b80fb7.img.gz` (the same
   build, `a699dd6`) → standard Armada install to internal storage.
2. **Pre-plug** the USB drive (connected before power-on) and boot normally
   (internal boot, **not** `linux usb`).
3. After boot, as root, run the mechanism capture:
   `scripts/full-system-mechanism-capture.sh` (same as the 2026-11-06
   capture; see [FULL_SYSTEM_MECHANISM_CAPTURE.md](FULL_SYSTEM_MECHANISM_CAPTURE.md)
   and [scripts/README.md](../scripts/README.md)).
4. **Checklist**:
   - `dmesg`: **no** `dr_mode=host ignored: usb-role-switch present` line and
     **no** `Configuration mismatch. dr_mode forced` line — the patch must be
     a no-op in a normal boot (the kernel's own DTB has no `dr_mode`).
   - The `a600000.usb-role-switch` device exists
     (`/sys/class/usb_role/…/role` = host) — the OTG path is taken.
   - Timeline: `charger_pd` PDR → `xhci-hcd.N.auto` probe (Δ ≈ 2.7–4.4 s) →
     root-hub attach → the **first scan** enumerates the pre-plugged drive →
     sdX block device. Baseline (2026-11-05/06): PDR 10.41/13.35 s, xHCI
     14.81/17.75 s, attach 15.07/18.00 s, sdg ~17/20.5 s.
   - `usb_type` = SDP/DCP (not `Unknown`), UCSI port + partner present, PM
     chain as in the 2026-11-06 steady state (`glue=auto/5000`,
     `xhci=on/0`).
5. **Decision**:
   - **Matches the 2026-11-06 baseline** → the mechanism model holds on the
     patched kernel; the `linux usb` failure is localized to the
     overlay/demotion path → proceed to `dbg1400`.
   - **Enumeration is lost, or the 1400 warning appears in a normal boot** →
     the patch regresses the normal path → read the dmesg marker, fix or
     revert 1400.

## References

- Mechanism: [ABL_DR_MODE_HOST.md](ABL_DR_MODE_HOST.md),
  [FULL_SYSTEM_MECHANISM_CAPTURE.md](FULL_SYSTEM_MECHANISM_CAPTURE.md),
  [FULL_SYSTEM_PREPLUG_RESULT.md](FULL_SYSTEM_PREPLUG_RESULT.md)
- Results tracker: [RESULTS.md](RESULTS.md)
- Firmware side (ICM `ncp_stby` wedge, `apsd-rerun-cfg`):
  [ADSP_RE.md](ADSP_RE.md), [ADSP_CONFIG.md](ADSP_CONFIG.md)
