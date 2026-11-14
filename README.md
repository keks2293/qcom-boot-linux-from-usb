# qcom-boot-linux-from-usb

Why a USB flash drive that is **connected before power-on** fails to
enumerate in ABL `linux usb` mode on the **Retroid Pocket 6**
(QCS8550 / SM8550) running **Armada OS**, and what fixes it.

## Problem

In `linux usb` mode the bootloader reads `\KERNEL` from the drive, the kernel
starts, the dracut initramfs looks for its root **on that drive** — and the
drive is not on the bus. The boot dies in the root-wait timeout. The same
drive, pre-plugged in the same way, enumerates fine when the device boots
the full system from internal storage, and a **replug after boot** makes it
work in `linux usb` too. A replug is not an acceptable fix: in the real
world the drive is already in the port at power-on.

## State (2026-11-14)

The AP-side software stack is **not** the problem. The full chain
(UCSI → xHCI → dwc3 unbind/rebind, i.e. a complete re-probe of the
controller, both PHYs and the eUSB2 repeater) runs on hardware, early
(post-VBUS, inside the ~30 s window) and cleanly (all `rc=0`, no `-110`) —
and the port still sees no connect event (`scan-events=0`, EXP-034). The
residual blocker is **below dwc3**: the PMIC-side eUSB2 repeater, the eUSB2
link state, or the PPM's routing.

The decisive measurement is now in. The eUSB2 repeater's `0xfd00–0xfd5b`
window was read in the broken mode (EXP-037): the repeater is **enabled and
reporting OK**, the board tuning is written as the device tree asks, and the
eight registers the kernel never touches hold **non-zero** values —
`50=00 52=01 55=03 56=00 58=02 59=03 5a=01 5b=02`. That refutes the
"the bootloader zeroed the tuning" form of the upstream `31bc94de`
regression, which was the leading hypothesis.

**Open:** the same dump in a normal (working) boot (EXP-038). Identical
values ⇒ the register file is not the discriminator and the blocker is the
eUSB2 link state / PPM side; different values ⇒ the working-mode blob is the
recipe and the fix is a kernel patch that writes it.

### Closed along the way

| question | answer |
|---|---|
| Is it the bootloader handing over a dirty controller? | no — a normal boot fails the same way in the initramfs (EXP-006) |
| Is it runtime PM / L2? | no — the chain never suspends, and the wedge is identical in every PM state (EXP-009) |
| Is it the charger classification (`usb_type`)? | no — the working control enumerates with the failing-side fingerprint (EXP-027) |
| Is it scan ordering? | necessary but not sufficient — post-PDR, post-VBUS scans are still empty (EXP-031, EXP-034) |
| Is it dwc3/UCSI/PHY state? | no — a full re-probe does not help (EXP-034) |
| Is it the missing `qcom_battmgr` module? | no — it is in the initramfs and auto-loads |
| Is the bootloader's `dr_mode=host` overlay the trigger? | yes — kernel patch 1400 demotes it, which is necessary but not sufficient (EXP-023) |

## Repository map

| path | what is there |
|---|---|
| [`docs/`](docs/) | the investigation. Start with [`docs/README.md`](docs/README.md) (index + status), then [`docs/EXPERIMENTS.md`](docs/EXPERIMENTS.md) (every boot, stable `EXP-NNN` IDs) and [`docs/TIMELINE.md`](docs/TIMELINE.md) (chronology). The current front is [`docs/LEVER_C_IMPLEMENTATION.md`](docs/LEVER_C_IMPLEMENTATION.md) |
| [`diagrams/`](diagrams/) | architecture, ICM state machine, charger-type chain, `usb_type`, UCSI command flow, PM chain |
| [`scripts/`](scripts/) | capture scripts and the firmware RE toolchain; [`scripts/lever-c/`](scripts/lever-c/) has the complete, reproducible lever-C toolchain (hooks v2–v8, builders, fake-sysfs harness) |
| [`logs/`](logs/) | raw and transcribed evidence; [`logs/lever-c/`](logs/lever-c/) holds the EXP-037 console transcript |

## Reproducing a run

The unit of work is a **boot image**: the CI kernel plus a diagnostic hook
inside the dracut initramfs (`var/lib/dracut/hooks/initqueue/91-armada-usb-fix-c.sh`).
Each image is built from the previous one by a Python script that replaces
exactly one initramfs entry and asserts the boot-image invariants
(`ANDROID!` magic, header `[20:576]` byte-identical, kernel byte-identical,
SHA1 id recomputed, cpio round-trip).

1. Build (or take) an image — [`scripts/lever-c/README.md`](scripts/lever-c/README.md).
2. Flash it as `KERNEL` on a FAT32 stick, **verify the md5 on both sides**,
   remove AppleDouble `._*` files, update `KERNEL.md5`, eject.
3. Boot the RP6 with the stick **pre-plugged in the normal orientation**,
   ABL → `linux usb`, **zero user actions**.
4. Read the console: the `ARMADA-C:` lines (`<0>` priority, visible on the
   quiet console). The verdict is `ENUMERATION OK` / `FAIL-NO-SCAN` /
   `FAIL-NO-SCAN-FULL`, and the dump lines are `RPT-*`.
5. Record the result as a new `EXP-NNN` row in
   [`docs/EXPERIMENTS.md`](docs/EXPERIMENTS.md) — including invalid runs, with
   the reason.

Protocol details and the process rules learned from invalid runs:
[`docs/TEST_METHOD.md`](docs/TEST_METHOD.md),
[`docs/EXPERIMENTS.md`](docs/EXPERIMENTS.md) §1.5.

## Background reading

- The bootloader overlay and why the early host scan is the trigger:
  [`docs/ABL_DR_MODE_HOST.md`](docs/ABL_DR_MODE_HOST.md)
- The working environment, measured:
  [`docs/FULL_SYSTEM_PREPLUG_SOURCE_ROLE.md`](docs/FULL_SYSTEM_PREPLUG_SOURCE_ROLE.md)
- The PPM/ADSP firmware: [`docs/ADSP_RE.md`](docs/ADSP_RE.md), [`docs/ADSP_CONFIG.md`](docs/ADSP_CONFIG.md), [`docs/ADSP_ULOG.md`](docs/ADSP_ULOG.md)

## Author

keks2293 (<rusik2293@gmail.com>)
