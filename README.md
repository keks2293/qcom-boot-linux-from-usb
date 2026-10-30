# qcom-boot-linux-from-usb

Investigation into why USB flash drives fail to enumerate during cold-plug boot in `linux usb` mode on the **Retroid Pocket 6 (QCS8550 / SM8550)** with **Armada OS**.

## Problem statement

When booting from USB (ABL `linux usb`) and cold-plugging a USB flash drive in the initramfs (dracut), the device is not enumerated on the USB bus. The same flash drive enumerates fine when booted from the internal storage and cold-plugged.

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
itself — and in the *active* initramfs runs it does exactly that, with the
wedge persisting anyway. The difference between the working and dead
environments is therefore the **PPM/PMIC state** (no fresh CC edge after PPM
start, port misclassified, `icm_ncp_stby` wedge), not a missing actor. Two
cheap candidates remain: the `apsd-rerun-cfg` 0→1 config patch (1 byte + hash
slot, recipe in [docs/ADSP_CONFIG.md](docs/ADSP_CONFIG.md)) and the fresh-edge
window (≤ ~30 s after power-on replug works, ≥ ~38 s fails).

**Next step (no new image needed):** the fresh-edge test — boot **without**
the flash drive, plug it in 5–10 s after boot, and observe whether it
enumerates (the full-system pre-plug vs post-plug fork
([docs/FULL_SYSTEM_COLDPLUG_TEST.md](docs/FULL_SYSTEM_COLDPLUG_TEST.md)) is no
longer runnable: a full boot on the device is not possible).

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
