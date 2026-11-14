# Timeline

What was believed when, and what changed the belief. Newest entries last.
Experiment IDs are defined in [EXPERIMENTS.md](EXPERIMENTS.md); each entry
links to the document that holds the evidence.

## 2026-10-19 … 10-26 — the sweep: PM, UCSI, ADSP, and the first controls

The investigation ran ~40 instrumented boots (images `dbg10`…`dbg51`), each
adding one diagnostic block to the dracut initramfs. The hypothesis table
that came out of it is in [INVESTIGATION.md](INVESTIGATION.md#hypotheses-tested);
the two results that survived:

- **2026-10-23 (EXP-006, `dbg45`) — the XBL-handoff hypothesis is refuted.**
  A normal boot (root on internal storage, so XBL never touched USB) with a
  cold-plugged drive still showed no enumeration in the initramfs stage, and
  a fresh PPM init at 26.5 s with the partner attached did not open the data
  path either. The failing environment is therefore not "XBL left the
  controller dirty".
- **2026-10-26 (EXP-009, `dbg51`) — the L2/runtime-PM class is closed.**
  With `usbcore.autosuspend=-1` the root hubs never suspend, `child_count`
  never reaches 0, and `rpm_check_suspend_allowed` returns `-EBUSY`/`-EAGAIN`
  on every boot; RPM tracepoints show zero suspend transitions. The wedge is
  present in every PM state.

Also closed along the way: the missing `qcom_battmgr` module (it is in the
CI initramfs and auto-loads), and the VBUS-regulator cycle as a fresh-edge
generator (no such node exists on the RP6).

## 2026-11-05 (EXP-020) — the full-system control

Full-system pre-plug enumerates the drive. `usb_type` is **SDP**, the port
is PD-negotiated (`data_role=host`, `power_role=sink`), and the xHCI host
comes up **after** the `charger_pd` PDR (14.81 s vs 10.41 s) — the opposite
order to the initramfs (host events at 2.7/3.2 s, PDR at 3.5 s).
→ [FULL_SYSTEM_PREPLUG_RESULT.md](FULL_SYSTEM_PREPLUG_RESULT.md)

## 2026-11-06 (EXP-021) — Q1–Q5: the host is *created* on the role flip

Nothing holds the xHCI probe (`devices_deferred` is empty); the controller
does not exist until the Type-C role flips to HOST, 2.7–4.4 s after the PDR.
→ [FULL_SYSTEM_MECHANISM_CAPTURE.md](FULL_SYSTEM_MECHANISM_CAPTURE.md)

## 2026-11-07 (EXP-023) — patch 1400 works, and is not enough

ABL unconditionally adds `dr_mode=host` in `linux usb`, which forces the
early host scan. Patch 1400 demotes it to OTG when `usb-role-switch` is
present, so the role flips only after the PDR — the kernel-side chain of the
fix then works end-to-end (demotion fired, role flipped, ADSP up), but the
port power path stays dead (`usb_type=[Unknown]`, `online=0`, ICM
`icm_ncp_stby`). → [KERNEL_PATCH_1400.md](KERNEL_PATCH_1400.md),
[ABL_DR_MODE_HOST.md](ABL_DR_MODE_HOST.md)

## 2026-11-08 (EXP-024, EXP-025) — classification is a PPM-side event

A 50 ms poller shows `usb_type = SDP` at **PDR + 55 ms**, produced inside
the PPM with no AP actor; the stock `pmic_pdcharger_ulog.ko` reads the PPM's
own log from the AP and shows the success-side fingerprint (`PartnerType=2`,
5 V / 900 mA, charger SM state 4, zero `ncp_stby`).
→ [USB_TYPE_TIMING.md](USB_TYPE_TIMING.md), [ADSP_ULOG.md](ADSP_ULOG.md)

## 2026-11-09 (EXP-026) — the failing side classifies nothing

`dbgB` (lever B) captures the failing environment's PPM log: detection runs
and sees the partner (`ConnectPartnerType=2`), but the classification never
completes — `FAIL-NO-CLASSIFY`, ICM parked in `ncp_stby`.
→ [RESULTS.md](RESULTS.md#dbgb-run--failing-side-ppm-ulog-capture-2026-11-09--fail-no-classify)

## 2026-11-11 (EXP-027) — the decisive control: `usb_type` is irrelevant

A full-system pre-plug boot in the **source** role enumerates the drive at
13.05 s (`sdg` at 14.21 s) **with the failing-side fingerprint**
(`usb_type=[Unknown]`, "skip checking usb charging type while usb is
sourcing", ICM `ncp_stby`). The discriminator is the **scan order**: the
initramfs scans before the PDR, the full system after it. ⇒ the fix is a
post-PDR rescan in the initramfs (**lever C**), and the classification
levers (`apsd-rerun-cfg`) are not needed. Also measured: normal orientation
is required (reverse stayed unrouted for 464 s), and a separate kernel bug
kills xHCI on any runtime source-role re-probe (`-110`).
→ [FULL_SYSTEM_PREPLUG_SOURCE_ROLE.md](FULL_SYSTEM_PREPLUG_SOURCE_ROLE.md)

## 2026-11-12 (EXP-028…031) — lever C, first hardware day

Three boots turned out to be the **same v1 image** (the stick was never
re-flashed) and died in a hook race: the v1 hook expected `xhci-hcd` at
start, but with patch 1400 the device appears only after the post-PDR role
flip. The fourth boot (dbgC3) was genuine: `FAIL-NO-SCAN` with a **live**
controller and three fresh scans (two post-VBUS), `scan-events=0`. Two
corrections: the Type-C roles are **not** a proxy for VBUS (roles are set at
UCSI port registration, ~1.8 s before the PPM enables OTG VBUS), and the
rebind is safe (no `-110`).
→ [LEVER_C_IMPLEMENTATION.md](LEVER_C_IMPLEMENTATION.md) §3

## 2026-11-13 (EXP-032…034) — the full chain runs, beta-2 is clean

`dbgC4` aborted on a hard-coded UCSI driver path (the real name is
`ucsi_glink.pmic_glink_ucsi`); `dbgC5` ran the full chain (UCSI → xHCI →
dwc3 unbind/rebind, all rc=0, self-completing in 0.6 s) but in **reverse**
orientation; the repeat in normal orientation is the clean **beta-2**: the
full chain runs early (7 s, post-VBUS) and the scans still see nothing.
⇒ the residual blocker is **below dwc3** — the PMIC side, the eUSB2 link
state, or the PPM routing. The software stack does everything right.
→ [LEVER_C_IMPLEMENTATION.md](LEVER_C_IMPLEMENTATION.md) §11

## 2026-11-13 (EXP-035) — the register dump stalls silently

`dbgC6` adds the eUSB2 repeater dump (`0xfd00–0xfd5b` via debugfs). The
chain is beta-2 again; the dump prints its first line at 23.6 s and then
nothing for 28 s. The source analysis of `regmap-debugfs.c` predicted a
possible ~30 s read (768 SPMI reads, 676 of them on unimplemented
registers), so the stall was ambiguous.
→ [LEVER_C_IMPLEMENTATION.md](LEVER_C_IMPLEMENTATION.md) §12.1–12.2

## 2026-11-14 (EXP-036) — the stall is the platform-device symlink resolve

`dbgC7` adds step markers: `mkdir rc=0`, `mount rc=0`, then
"globbing platform devices" at 23.394 s and silence. debugfs mounts fine
and the register read never starts — the hang is the shell glob
`*eusb2*` / `[ -e ]` / `cd -P` / `pwd -P` / `stat` on the platform-device
symlink. ⇒ v8: no symlink resolution at all.
→ [LEVER_C_IMPLEMENTATION.md](LEVER_C_IMPLEMENTATION.md) §12.3–12.4

## 2026-11-14 (EXP-037) — the dump, and the first hard number

`dbgC8` (scan-based: list the debugfs regmap dirs, intersect with the spmi
bus names, identify the repeater by `0xfd08=0x80` + `0xfd46=0x80`) completes
in 2 s. Result: the repeater is **enabled and OK** in the broken state, the
DT/init tuning is written as expected, and the eight registers the kernel
never writes hold **non-zero** values
(`50=00 52=01 55=03 56=00 58=02 59=03 5a=01 5b=02`) — so the "ABL zeroed
the tuning" form of the `31bc94de` regression is **refuted for
`linux usb`**. The SPMI-timeout model of the read is refuted too (0.2–1.1 s
per map, zero timeouts). Open: the same dump in a **normal** boot (EXP-038)
decides whether the register file differs at all between the broken and the
working mode.
→ [LEVER_C_IMPLEMENTATION.md](LEVER_C_IMPLEMENTATION.md) §12.5–12.7,
[logs/lever-c/exp-037-dump.txt](../logs/lever-c/exp-037-dump.txt)
