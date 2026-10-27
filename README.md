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

UCSI 2.0 spec cross-check: PPM is the spec term "Platform Policy Manager"; the spec requires a `CONNECTOR_RESET` hard reset to "go through a disconnect-connect sequence", but on this device the plain reset is a no-op — the PPM firmware deviates from the spec (fourth observed refusal, after the role-swap `-ECOMM`, the `SET_*` `-EOPNOTSUPP` set, and the Data-Reset hang).

Remaining focus is **early port classification by PPM/BC1.2 on the ADSP side** (`icm_ncp_stby` until charger type updated).

**Next step (no new image needed):** the full-system cold-plug test with a fork — boot with the flash drive pre-plugged vs cold-plugged after boot, and compare enumeration, `usb_type` (`Unknown` vs `SDP/DCP/PD`), and the dmesg window around the attach. See [docs/FULL_SYSTEM_COLDPLUG_TEST.md](docs/FULL_SYSTEM_COLDPLUG_TEST.md).

## Documentation

- [docs/INVESTIGATION.md](docs/INVESTIGATION.md) — idea, hypotheses, attempts, key code facts
- [docs/TEST_METHOD.md](docs/TEST_METHOD.md) — how tests were performed
- [docs/RESULTS.md](docs/RESULTS.md) — results from dbg50/dbg51
- [docs/FULL_SYSTEM_COLDPLUG_TEST.md](docs/FULL_SYSTEM_COLDPLUG_TEST.md) — full-system test (remaining measurement)
- [diagrams/pm-chain.md](diagrams/pm-chain.md) — PM chain and RPM blockers

## Scripts

- [scripts/full-system-coldplug-test.sh](scripts/full-system-coldplug-test.sh) — run on full system after boot
- [scripts/README.md](scripts/README.md) — usage

## Logs

Raw logs and screen captures can be placed in [`logs/`](logs/).

## Author

keks2293 (<rusik2293@gmail.com>)
