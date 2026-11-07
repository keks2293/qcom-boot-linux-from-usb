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
- The run is **inconclusive, not a clean negative**: the CI image is `quiet`
  and carries no diagnostic block, so it is not known whether the demotion
  fired at runtime, whether the role flipped to HOST after the PDR, when the
  xHCI controller probed, and what the ICM state was.
- Next steps: (1) a **full-boot re-check** with the same CI build (the
  control — it must still show the known-good ROLE-FLIP + FIRST SCAN behavior
  and confirm the patch is a no-op in a normal boot); (2) `dbg1400` — a
  dracut `initqueue/timeout` hook image on top of the CI kernel that dumps
  the runtime `[DT] dr_mode`/`usb-role-switch`, `usb_role` state, xHCI/PDR
  timestamps, and the ICM/`usb_type` fingerprint — to localize where the
  `linux usb` chain breaks.

## What the current branch contains (PR #704, `initramfs-adsp`, HEAD `a699dd6`)

| commit | change | why |
|---|---|---|
| `68f68ad` | dracut drop-in `system_files/etc/dracut.conf.d/91-armada-adsp.conf`: `add_drivers += qcom_q6v5_pas` (resolves its 4 deps through `modules.dep`) + `install_items +=` the board ADSP firmware images | ADSP/PPM must be up **early** (initramfs): dracut's aarch64 whitelist ships neither the `remoteproc` driver nor the firmware (its name comes from the board DT, not `MODULE_FIRMWARE`), so without it the `charger_pd` PDR — which the fix depends on — never comes up in the initramfs |
| `a699dd6` | kernel patch `1400-dwc3-ignore-dr-mode-host-with-role-switch.patch` (+ `series` + `PATCHES.md`): in `dwc3_get_dr_mode()` (`drivers/usb/dwc3/core.c:53`), when `dwc->dr_mode == HOST` and the device declares `usb-role-switch`, demote to OTG with a `dev_warn` marker | the ABL overlay `dr_mode=host` (applied unconditionally in `linux usb` mode) forces the early host scan **before** the `charger_pd` PDR; that scan is absorbed by the ICM (`icm_ncp_stby`) and the pre-plugged drive is never enumerated — the unifying root cause. The demotion makes `linux usb` follow the full-system (known-good) OTG + role-flip sequence |

Expected behavior with both in place, in `linux usb` mode:

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
