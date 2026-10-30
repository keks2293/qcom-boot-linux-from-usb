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

Remaining focus is **early port classification by PPM/BC1.2 on the ADSP side**
(`icm_ncp_stby` until charger type updated). The firmware RE removed the
"runtime flag" hypothesis and named both ends of the AP↔PPM link: the AP
actor is the **in-kernel UCSI core** (`ucsi.c` + `ucsi_glink.c`, no userspace
daemon), which fires the four PMIC-doorbell commands (0x03/0x09/0x0b/0x10)
itself. That actor does **not** discriminate the environments: in the *active*
initramfs runs it fires those commands and the wedge persists, while in the
*working* full system the core is deferred (no doorbell commands) and
enumeration still works. The **pre-plug** case sharpens the open question:
with the drive connected before power-on there is **no fresh CC edge after the
PPM starts** (~3.4 s) in *either* environment, yet the full system enumerates
the drive and the initramfs does not — so the fresh-CC-edge mechanism that
explains the cold-plug/replug cases **cannot** explain the working pre-plug
case. Whatever makes the full system re-classify a pre-plugged port is still
unidentified, and that run has **no logs** — the measurement gap to close.

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

**Next step (no new image needed):** capture the missing measurement — a
full-system **pre-plug** boot (drive connected before power-on) with logging
([docs/FULL_SYSTEM_COLDPLUG_TEST.md](docs/FULL_SYSTEM_COLDPLUG_TEST.md),
`scripts/full-system-coldplug-test.sh`): when the drive enumerates (T)
relative to PPM start (~3.4 s) and switch-root, the `usb_type` (SDP/DCP/PD vs
`Unknown`), the PM state of the `a600000.usb` / `xhci` chain, and the AP-side
glink/UCSI/battmgr activity in the window before enumeration. That identifies
the re-classification trigger to replicate in the initramfs.

## Documentation

- [docs/INVESTIGATION.md](docs/INVESTIGATION.md) — idea, hypotheses, attempts, replug window, key code facts
- [docs/ADSP_RE.md](docs/ADSP_RE.md) — PPM/ADSP firmware reverse engineering (wedge state, trigger map, glink RX, the "flag wall" refutation, the final charger-type/property model)
- [docs/ADSP_CONFIG.md](docs/ADSP_CONFIG.md) — `adsp_dtb.mbn` container layout, PPM config values, the 1-byte `apsd-rerun-cfg` patch recipe
- [docs/TEST_METHOD.md](docs/TEST_METHOD.md) — how tests were performed
- [docs/RESULTS.md](docs/RESULTS.md) — results from dbg50/dbg51
- [docs/FULL_SYSTEM_COLDPLUG_TEST.md](docs/FULL_SYSTEM_COLDPLUG_TEST.md) — full-system test (remaining measurement)
- [diagrams/architecture.md](diagrams/architecture.md) — system architecture: what is where (AP/ADSP/hardware layers, the data path and where it is gated, what is identical vs different between the working and failing environments, the lever map)
- [diagrams/icm-state-machine.md](diagrams/icm-state-machine.md) — ICM charger state machine inside the PPM firmware: states, the `ncp_stby` wedge, exit conditions, where the exit inputs come from, the ULog fingerprint
- [diagrams/charger-type-chain.md](diagrams/charger-type-chain.md) — charger type chain: PM8550B CC/APSD hardware → IRQ dispatcher → charger detection → ICM inputs; levers on the chain; object and function maps (vaddrs)
- [diagrams/ppm-ucsi-command-flow.md](diagrams/ppm-ucsi-command-flow.md) — UCSI/PPM command flow: the AP↔PPM protocol (plain UCSI, no renumbering), the in-kernel UCSI core as the only AP actor (active vs deferred), the 4 PMIC-doorbell commands, the full PPM dispatch table, why the AP-side experiments stayed no-op
- [diagrams/pm-chain.md](diagrams/pm-chain.md) — PM chain and RPM blockers

## Scripts

- [scripts/full-system-coldplug-test.sh](scripts/full-system-coldplug-test.sh) — run on full system after boot
- [scripts/adsp-re/](scripts/adsp-re/) — firmware RE toolchain (disassembly dump, function extractor, vaddr→string resolver, ELF map)
- [scripts/README.md](scripts/README.md) — usage

## Logs

- [`logs/`](logs/) — raw/near-raw evidence from initramfs diagnostic runs
- [`logs/adsp-re/`](logs/adsp-re/) — disassembly excerpts and xref evidence for every RE claim

## Author

keks2293 (<rusik2293@gmail.com>)
