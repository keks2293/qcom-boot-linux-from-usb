# Cell II — Full System Test

Run this on a **full system boot** (boot from internal storage, normal boot) with a flash drive **cold-plugged after login/boot completes**. Do **not** use the initramfs debug images for this test.

## Purpose

Determine whether PPM/BC1.2 classification differs between initramfs and full system:
- Does full system report `usb_type` as `SDP/DCP/PD` instead of `Unknown`?
- What happens around enumeration time `[T-2s, T]`?
- What are PM states of `a600000.usb` and `xhci-hcd.0.auto`?

## Procedure

1. Boot to full system
2. Open terminal as root/user with access to sysfs
3. Have a stopwatch/log ready
4. Cold-plug USB flash drive (before starting captures if desired)
5. Run the script below and capture full output

## Script

Use [`scripts/cell-ii.sh`](../scripts/cell-ii.sh).

```bash
chmod +x scripts/cell-ii.sh
./scripts/cell-ii.sh > cell-ii-$(date +%Y%m%d-%H%M%S).log 2>&1
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
