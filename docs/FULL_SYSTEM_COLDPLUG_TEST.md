# Cell II — Full System Test

Run this on a **full system boot** (boot from internal storage, normal boot). Do **not** use the initramfs debug images for this test. There are two variants; **pre-plug is the primary one** — it is the target case (the drive connected before power-on) that already works on the device and must be captured:

- **Pre-plug (primary):** the flash drive is connected **before power-on**; the system boots normally with it in the port.
- **Post-plug / cold-plug (secondary):** boot **without** the drive, then plug it in after boot.

## Purpose

Identify what the full system does to enumerate a **pre-plugged** drive — the behavior the initramfs is missing. Specifically:
- Does the full system report `usb_type` as `SDP/DCP/PD` instead of `Unknown`?
- When does the pre-plugged drive enumerate (T) relative to PPM start (~3.4 s) and switch-root?
- What happens in the dmesg window before/around enumeration (`[T-2s, T]`)?
- What are the PM states of `a600000.usb` and `xhci-hcd.0.auto`?

## Procedure (pre-plug, primary)

1. Connect the flash drive **before power-on**.
2. Boot to the full system (it should enumerate the drive — that is the known-good case).
3. Open a terminal with access to sysfs.
4. Run the script below and capture full output (the boot-time enumeration is already in `dmesg`).

## Script

Use [`scripts/full-system-coldplug-test.sh`](../scripts/full-system-coldplug-test.sh).

```bash
chmod +x scripts/full-system-coldplug-test.sh
./scripts/full-system-coldplug-test.sh > full-system-coldplug-test-$(date +%Y%m%d-%H%M%S).log 2>&1
```

## What to look for

| Check | Expected/notes |
|---|---|
| `usb_type` | `Unknown` (matches initramfs) or `SDP/DCP/PD` (full system classifies) |
| PM of glue/xhci | Predicted: `glue=auto/active/5000`, `xhci=on/active/0` (cycle unlikely in full system) |
| dmesg window `[T-2s,T]` | Look for `new high-speed`, `new SuperSpeed`, `ccs`, `ucsi`, `typec`, `rpm_suspend`, `rpm_idle` |
| `typec/usb_role` | Check if `typec`, `usb_role`, `typec_mux` exist |
| `lsmod` | `qcom_battmgr`, `ucsi`, `tcpm`, `q6v5_pas` etc |
| rpm trace count | `grep -c rpm_suspend /sys/kernel/tracing/trace` if tracing available |

## Fork variant (pre-plug vs post-plug)

Run the full system boot **twice**:

1. **Pre-plug:** flash drive inserted **before power-on**, boot to full system, then capture.
2. **Post-plug:** boot **without** the drive, then cold-plug after the system is up and capture.

Compare: does the drive enumerate in each variant, what does `usb_type` report, and what happens in the dmesg window around the attach.

Interpretation matrix:

| Pre-plug | Post-plug | Conclusion |
|---|---|---|
| enumerates | does not | mechanism = fresh CC-edge processed by the PPM (within the ~30 s window); fix direction = ADSP side (P-06) / early nudge |
| does not | enumerates | a rootfs participant (udev/daemon) opens the path; bisect rootfs participants |
| enumerates | enumerates | initramfs-specific; contradicts dbg runs V–dbg51, re-examine |
| does not | does not | mechanism is outside "moment/environment"; re-examine P-01/P-06 |

## Interpretation

- If `usb_type` becomes `SDP/DCP/PD` in full system but stays `Unknown` in initramfs -> **early BC1.2 classification / PPM nudge in initramfs** is a plausible fix direction
- If `usb_type` stays `Unknown` and flash is visible in full system -> classification not the gate, look for transaction in `[T-2s,T]` window
- If glue/xhci go to suspend in full system and port stays alive -> PM class already closed there (consistent with dbg51)
