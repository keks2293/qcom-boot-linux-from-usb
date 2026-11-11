# qcom-boot-linux-from-usb

Investigation into why USB flash drives fail to enumerate in `linux usb` mode on the **Retroid Pocket 6 (QCS8550 / SM8550)** with **Armada OS** — the target case being a drive connected **before power-on (pre-plug)**, which is how USB boot is actually used.

## Problem statement

When booting from USB (ABL `linux usb`), a USB flash drive that is **connected before power-on (pre-plug)** is not enumerated on the USB bus during the initramfs (dracut) stage, so the boot cannot find its root on the drive. The same drive, in the same pre-plugged state, enumerates fine when the device boots the full system from internal storage (measured on the device). Cold-plug (plugging after boot) also fails in the initramfs, but **pre-plug is the case that must work** — in the real world the drive is already in the port at power-on, and asking the user to replug it is not an acceptable workaround.

## Approach

Instead of guessing kernel fixes, custom `KERNEL` images with in-block diagnostics were injected into `dracut-initqueue`. Each iteration collected:

- PM state of the USB chain: `power/control`, `power/runtime_status`, `power/autosuspend_delay_ms`
- Runtime PM traces from `events/rpm/*` (`rpm_idle/suspend/resume/usage/return_int/status`)
- ADSP/ULOG fingerprints
- USB enumeration timeline (`PORTSC`, `New USB device`, partner state)
- Link topology and devicetree facts

All images were verified byte-for-byte against a known base (Android boot image header invariants, initramfs cpio diff limited to `dracut-initqueue`, sha1 id recalculated).

In parallel, the PPM/ADSP firmware (`adsp.mbn` + `adsp_dtb.mbn`) was reverse
engineered: full Hexagon disassembly, string→code xrefs, function extraction,
and a byte-verified catalog of the PPM device-tree configuration
([docs/ADSP_RE.md](docs/ADSP_RE.md), [docs/ADSP_CONFIG.md](docs/ADSP_CONFIG.md)).
Key outcome: the firmware's charger-detection and glink-intent processing is
**not** gated by any AP-ready runtime flag (the suspected "flag wall" turned
out to be ULog logging controls), and the PPM config ships with
`apsd-rerun-cfg = 0` while the firmware contains the full APSD re-run
mechanism — a 1-byte config patch candidate.

## Key result (dbg51)

The **L2/runtime-PM class of the `a600000.usb` glue + `xhci-hcd.0.auto` chain is closed**. The wedge (`CCS=0`, no `new high-speed/super-speed`) is observed across all tested PM states.

Root cause of the PM blockage by construction:

- `usbcore.autosuspend=-1` in cmdline => root hubs `usb1/usb2` get `autosuspend_delay_ms = -1000` => never go to runtime suspend
- `usb1/usb2` are root hubs (created via `usb_alloc_dev(parent==NULL)`, named `usb%d`, parent = HCD controller), not HCDs
- With root hubs always active, `child_count` on `xhci-hcd.0.auto` and `a600000.usb` never drops to 0
- `rpm_check_suspend_allowed` returns `-EBUSY` (children present) / `-EAGAIN` (usage refs), so the chain cannot enter runtime suspend
- `a600000.usb` has a second child: `a600000.usb-role-switch` (registered by DWC3 in role-switch mode)

Also refuted along the way:

- **Missing `qcom_battmgr` module** — the module is already in the CI initramfs (dracut `--no-hostonly`) and is auto-loaded by udev; battery psys are alive in every initramfs run
- **VBUS regulator cycle as a fresh-edge generator** — no VBUS regulator node exists in the RP6 device tree (the driver matches only `qcom,pm8150b-vbus-reg`, an RP5-family node); the 5 V output is generated on the ADSP/PMIC side, so no AP-side lever exists

UCSI 2.0 spec cross-check: PPM is the spec term "Platform Policy Manager"; the spec requires a `CONNECTOR_RESET` hard reset to "go through a disconnect-connect sequence", but on this device the plain reset is a no-op — the PPM firmware deviates from the spec (after the role-swap `-ECOMM` and the `SET_*` `-EOPNOTSUPP` set; the second dbg32 reset variant re-decodes to an *invalid port 0*, so the observed hang is a confounded experiment — see [docs/RESULTS.md](docs/RESULTS.md#dbg31dbg32--ucsi-command-re-decode-word-layout)).

## Current status (2026-11-09)

The mechanism is identified and the first fix is **in the branch and verified
to fire on device — but it does not enumerate the drive yet**:

- **Unifying root cause**: in `linux usb` mode ABL unconditionally adds
  `dr_mode=host` to the runtime device tree, forcing the early host scan
  *before* the `charger_pd` PDR; that scan is absorbed by the ICM
  (`icm_ncp_stby`) and the pre-plugged drive is never enumerated. In a normal
  boot there is no overlay: the controller stays OTG, the Type-C role flips
  to HOST only **after** the PDR, and the **first scan after the PDR**
  enumerates the drive
  ([docs/ABL_DR_MODE_HOST.md](docs/ABL_DR_MODE_HOST.md)).
- **Fix (Armada PR #704)**: dracut ships ADSP + firmware into the initramfs
  (the PDR precondition) and kernel patch **1400** demotes the bootloader's
  `dr_mode=host` to OTG when `usb-role-switch` is present, so `linux usb`
  follows the full-system (known-good) role-flip sequence.
- **2026-11-07 device tests**: the CI image built from the branch was
  flashed; the patch is present in the kernel (marker string verified in the
  flashed vmlinux), but `linux usb` pre-plug still ends in the dracut
  root-wait timeout. The follow-up `dbg1400` diagnostic run (same kernel,
  dracut timeout-hook dumping the runtime state) shows the **kernel-side
  chain of the fix works end-to-end** (the demotion fired, the role flipped
  to HOST after the PDR, ADSP is up), while the **port power path stays
  dead** (`usb_type=[Unknown]`, `online=0`, ICM `icm_ncp_stby`: no VBUS is
  driven onto the port, the pre-plugged drive never enumerates). The
  root-wait timeout is now trivially explained: the root filesystem lives on
  the drive itself (the CI disk image *is* the drive — layout, boot marker
  and root UUID all match). Leading hypothesis: in `linux usb` mode the
  ABL/XBL runs its own closed USB host stack on this very port (it reads
  `\KERNEL` from the drive), and the PPM/ICM port state left by that ABL
  session is not re-classified at kernel handoff (pre-plug ⇒ no fresh CC
  edge; the ICM in `ncp_stby` does not rescan). That hypothesis must be
  reconciled with the measured replug window (a fresh edge works at ≤ ~24.7 s
  and fails at ≥ ~38 s — so a missing edge alone cannot be the story); the
  combined model and the two remaining edge-free levers (`apsd-rerun-cfg`
  0→1, still untested; a ≤30 s role/`unbind`-`bind` cycle, still unrun) are
  in [docs/KERNEL_PATCH_1400.md](docs/KERNEL_PATCH_1400.md). Next: a re-run
  with the **fixed** `dbg1400` build (the run used the pre-dedup build — its
  own dump lines contaminated its dmesg tail) and a **full-boot re-check on
  the same CI build** (control) — [docs/KERNEL_PATCH_1400.md](docs/KERNEL_PATCH_1400.md).
- **2026-11-08: the classification trigger is measured.** A 50 ms poller on a
  normal pre-plug boot shows `usb_type = SDP` **at the `charger_pd` PDR +
  55 ms**, produced inside the PPM with no AP actor — so the working
  environment uses *initial detection at PPM boot*, and the initramfs fails
  that same step (same PDR, `usb_type` never leaves `[Unknown]`). The
  consequence for the fix is collected in
  [docs/INITRAMFS_CHANGES.md](docs/INITRAMFS_CHANGES.md): nothing an init
  script can *command* is left, so the remaining init-side options are
  staging the ADSP start, shipping the poller + ADSP ULog for diagnosis, and a
  post-PDR nudge inside the ≤30 s window — otherwise the gate is the
  `apsd-rerun-cfg` firmware byte. Measurement:
  [docs/USB_TYPE_TIMING.md](docs/USB_TYPE_TIMING.md).
- **2026-11-08: the PPM's own log is readable from the AP.** The stock
  `pmic_pdcharger_ulog.ko` (never loaded in any environment) reads the PPM
  charger ULog over the `PMIC_LOGS_ADSP_APPS` rpmsg channel. The boot-1
  control capture (full system, pre-plug) shows initial detection ran at ADSP
  boot — `PartnerType=2, 5 V / 900 mA` in the PDR + 22 ms drain — the charger
  SM reaches state 4, and there are **zero** `ncp_stby` lines: the exact
  opposite of dbg49's stuck-at-state-2 + `ncp_stby` fingerprint. The module is
  already in the stock initramfs, so the failing-side capture (boot 2, lever B)
  is a `modprobe` away: [docs/ADSP_ULOG.md](docs/ADSP_ULOG.md).
- **2026-11-09: the next boot is the enum-only test.** The plan in
  [docs/INITRAMFS_CHANGES.md](docs/INITRAMFS_CHANGES.md) is now concrete: a
  `linux usb` boot of the built fixed initramfs (A staged ADSP start + B the
  poller / PPM-ULog capture + C-lite, unprivileged build in
  `agent-work/usb-fix/`, no kernel rebuild) on a minimal **enum-only** drive
  (p1 vfat + boot image, **no OS clone**). The milestone is *does the
  pre-plugged stick enumerate as `/dev/sdX`?*; the debug PID-1 reports
  `ENUMERATION OK: /dev/sdX` on screen and ships the init logs (incl. the PPM
  ULog) to the stick for the diff against the success-side fingerprint. A cheap
  control (full-system pre-plug with a **direct stick**, to rule out the
  partner-type confound of the dock-based success measurement) runs alongside.
  Verdict → next boot mapping:
  [docs/INITRAMFS_CHANGES.md#next-step-the-enum-only-test](docs/INITRAMFS_CHANGES.md).
- **2026-11-11: the control boot succeeded — `usb_type` is not the blocker and
  the fix is a post-PDR rescan.** A full-system boot with the stick
  **pre-plugged**, **directly attached**, in the **source** role and **normal**
  orientation enumerated the drive at 13.05 s (`sdg` at 14.21 s), with PDR
  12.454 s and the first xHCI port scan **post-PDR** (12.787 s). The PPM
  fingerprint was the **failing side** — `usb_type=[Unknown]`,
  `skip checking usb charging type while usb is sourcing`, ICM `ncp_stby` — so
  classification is **irrelevant** to enumeration and the classification-first
  levers (the `apsd-rerun-cfg` byte) are not needed. The initramfs (dbgB) fails
  because its port scan is **pre-PDR** (2.7 s vs PDR 3.5 s); the fix is **lever
  C** — a single post-PDR unbind/rebind of `dwc3-qcom`/xHCI inside the
  initramfs. Also measured: **normal orientation is required** (reverse stayed
  unrouted for 464 s), and a **separate** kernel bug kills xHCI on any runtime
  source-role re-probe (`Host halt failed, -110`, hot-plug/re-plug only).
  Evidence: [docs/FULL_SYSTEM_PREPLUG_SOURCE_ROLE.md](docs/FULL_SYSTEM_PREPLUG_SOURCE_ROLE.md),
  [logs/preplug-source/](logs/preplug-source/).

Background: the firmware RE removed the "runtime flag" hypothesis and named
both ends of the AP↔PPM link (the in-kernel UCSI core fires the four
PMIC-doorbell commands itself; there is no userspace daemon). The pre-plug
case sharpens the open question: with the drive connected before power-on
there is no fresh CC edge after the PPM starts (~3.4 s) in *either*
environment, yet the full system enumerates the drive and the initramfs does
not — so the fresh-CC-edge mechanism that explains the cold-plug/replug cases
cannot explain the working pre-plug case. The full-system pre-plug boot is
now captured: the xHCI host comes up **after** the ADSP `charger_pd` PDR
(10.41 s → 14.81 s) and the drive enumerates at 16.99 s, while in the
initramfs the USB events (2.716/3.182 s) precede the PDR (3.498 s) and
nothing re-arms the port afterwards.

## Goals

1. **Make USB boot work with the drive pre-plugged** (connected before
   power-on): the drive must enumerate during the initramfs so the boot can
   find its root on it. A replug / fresh-edge workaround is **not** acceptable
   — the drive is already in the port at power-on.
2. **Identify what the full system does** to enumerate a pre-plugged drive
   (it works there, but was never logged). That behavior is the target to
   replicate — or replace with the `apsd-rerun-cfg` 0→1 config patch (1 byte +
   hash slot, recipe in [docs/ADSP_CONFIG.md](docs/ADSP_CONFIG.md)) — in the
   initramfs.

The replug-timing correlation (≤ ~30 s after power-on works, ≥ ~38 s fails) is
kept as supporting evidence of a PPM/BC1.2 classification window, not as the
fix.

**Captured 2026-11-05 (full-system pre-plug):** the missing measurement now
exists — `usb_type` is **SDP** (not `Unknown`), the port is PD-negotiated
(`data_role=host`, `power_role=sink`), and the xHCI host comes up **after** the
ADSP `charger_pd` PDR (14.81 s vs 10.41 s), unlike the initramfs where the host
events happen before the PDR (3.50 s). See
[docs/FULL_SYSTEM_PREPLUG_RESULT.md](docs/FULL_SYSTEM_PREPLUG_RESULT.md) for
the timeline, the contradicted predictions (`qcom_battmgr` is loaded; UCSI is
active in the full system) and the next falsifiable test (re-probe the host
inside the ≤30 s window).

## Documentation

- [docs/INVESTIGATION.md](docs/INVESTIGATION.md) — idea, hypotheses, attempts, replug window, key code facts
- [docs/ADSP_RE.md](docs/ADSP_RE.md) — PPM/ADSP firmware reverse engineering (wedge state, trigger map, glink RX, the "flag wall" refutation, the final charger-type/property model)
- [docs/ADSP_CONFIG.md](docs/ADSP_CONFIG.md) — `adsp_dtb.mbn` container layout, PPM config values, the 1-byte `apsd-rerun-cfg` patch recipe
- [docs/TEST_METHOD.md](docs/TEST_METHOD.md) — how tests were performed
- [docs/RESULTS.md](docs/RESULTS.md) — results tracker: `usb_type` timing (2026-11-08), the `dbg1400` run, the CI/kernel-patch tests, dbg50/dbg51
- [docs/USB_TYPE_TIMING.md](docs/USB_TYPE_TIMING.md) — **when the port gets classified** (2026-11-08, new poller instrument): `usb_type = SDP` at `charger_pd` PDR + 55 ms, produced inside the PPM with no AP actor; the VBUS-bounce power sequence; the PPM-state discriminator vs the initramfs
- [docs/ADSP_ULOG.md](docs/ADSP_ULOG.md) — **the PPM's own charger log, read from the AP** (2026-11-08): the stock `pmic_pdcharger_ulog.ko` instrument (never loaded before; already in the initramfs), the boot-1 success-side fingerprint (initial detection in the PDR + 22 ms drain, charger SM state 4, zero `ncp_stby`), and the diff vs dbg49's failing fingerprint
- [docs/INITRAMFS_CHANGES.md](docs/INITRAMFS_CHANGES.md) — what a `linux usb` initramfs would have to contain: what PR #704 already added and verified, why no AP-side command can set `usb_type`, and the ranked remaining options (stage the ADSP start / poller + ADSP ULog in init / a ≤30 s post-PDR nudge / the `apsd-rerun-cfg` firmware byte)
- [docs/FULL_SYSTEM_PREPLUG_SOURCE_ROLE.md](docs/FULL_SYSTEM_PREPLUG_SOURCE_ROLE.md) — **the control boot (2026-11-11)**: full-system source-role pre-plug enumerates with the failing-side PPM fingerprint (`usb_type=Unknown` + skip gate + `ncp_stby`), so `usb_type` is irrelevant; the initramfs failure is the pre-PDR scan and the fix is a post-PDR rescan (lever C); orientation and the `-110` role-switch bug
- [docs/FULL_SYSTEM_COLDPLUG_TEST.md](docs/FULL_SYSTEM_COLDPLUG_TEST.md) — full-system test procedure
- [docs/FULL_SYSTEM_PREPLUG_RESULT.md](docs/FULL_SYSTEM_PREPLUG_RESULT.md) — measured full-system pre-plug result (2026-11-05)
- [docs/FULL_SYSTEM_MECHANISM_CAPTURE.md](docs/FULL_SYSTEM_MECHANISM_CAPTURE.md) — Q1–Q5 mechanism capture (2026-11-06): the attach is the first scan, not a fresh CC edge; **Q1 answered** — nothing holds the xHCI probe, the host controller is *created* only when the Type-C role flips to HOST (gadget→host, 2.7–4.4 s after the `charger_pd` PDR)
- [docs/KERNEL_PATCH_1400.md](docs/KERNEL_PATCH_1400.md) — the current patch version (PR #704: dracut ADSP drop-in + kernel patch 1400), the 2026-11-07 CI test result (patch in the kernel, `linux usb` pre-plug still times out — inconclusive), the `dbg1400` diagnostic, and the full-boot re-check protocol
- [diagrams/architecture.md](diagrams/architecture.md) — system architecture: what is where (AP/ADSP/hardware layers, the data path and where it is gated, what is identical vs different between the working and failing environments, the lever map)
- [diagrams/icm-state-machine.md](diagrams/icm-state-machine.md) — ICM charger state machine inside the PPM firmware: states, the `ncp_stby` wedge, exit conditions, where the exit inputs come from, the ULog fingerprint
- [diagrams/charger-type-chain.md](diagrams/charger-type-chain.md) — charger type chain: PM8550B CC/APSD hardware → IRQ dispatcher → charger detection → ICM inputs; levers on the chain; object and function maps (vaddrs)
- [diagrams/usb-type.md](diagrams/usb-type.md) — **what `usb_type` is and what makes USB work in the full system**: the PPM→AP data path (read-only mirror via `BATTMGR_USB_PROPERTY_GET`/`USB_ADAP_TYPE`, no AP write path), the three PPM trigger paths, and the two orderings (PPM boots late+clean; first host scan after the PDR) that the full system has and `linux usb` breaks
- [diagrams/ppm-ucsi-command-flow.md](diagrams/ppm-ucsi-command-flow.md) — UCSI/PPM command flow: the AP↔PPM protocol (plain UCSI, no renumbering), the in-kernel UCSI core as the only AP actor (active vs deferred), the 4 PMIC-doorbell commands, the full PPM dispatch table, why the AP-side experiments stayed no-op
- [diagrams/pm-chain.md](diagrams/pm-chain.md) — PM chain and RPM blockers

## Scripts

- [scripts/full-system-coldplug-test.sh](scripts/full-system-coldplug-test.sh) — run on full system after boot
- [scripts/adsp-ulog-capture.sh](scripts/adsp-ulog-capture.sh) + `.service` — PPM charger ULog from the AP at boot (stock `pmic_pdcharger_ulog.ko`, tracepoint drain, 40 s in the background)
- [scripts/adsp-re/](scripts/adsp-re/) — firmware RE toolchain (disassembly dump, function extractor, vaddr→string resolver, ELF map)
- [scripts/README.md](scripts/README.md) — usage

## Logs

- [`logs/`](logs/) — raw/near-raw evidence from initramfs diagnostic runs
- [`logs/full-system/`](logs/full-system/) — full-system instrument captures (usb-type poller, mechanism capture, ADSP ULog)
- [`logs/adsp-re/`](logs/adsp-re/) — disassembly excerpts and xref evidence for every RE claim

## Author

keks2293 (<rusik2293@gmail.com>)
