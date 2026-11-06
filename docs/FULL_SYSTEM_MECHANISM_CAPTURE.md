# Full-system mechanism capture (Q1–Q5)

Run: **2026-11-06 10:37 (+08)**, boot **10:15:26**, Retroid Pocket 6, Armada
full system, kernel `7.2.6 #1`, **pre-plug** (dock + Netac drive connected
before power-on). Script: [`scripts/full-system-mechanism-capture.sh`](../scripts/full-system-mechanism-capture.sh)
(commit `acbacc0`, plus the three fixes listed below).

Artifacts: [`logs/full-system/mechanism-capture-20261106-103720/`](../logs/full-system/mechanism-capture-20261106-103720/)
(`timeline.txt`, `quick-windows.txt`, `full-kern-monotonic.log`,
`full-kern-iso.log`, `devlink.txt`, `steady-state.txt`, `udev-rules.txt`,
`udevd-iso.log`).

Caveat: this run was **not** root, so `/sys/kernel/debug/devices_deferred` and
the UCSI debugfs were unavailable — the script now reports `NEEDS ROOT` for both
instead of a false result. See [Next step](#next-step).

## Q3 (decisive): the attach is the FIRST SCAN, not a fresh CC edge

Kernel-relative, from `full-kern-monotonic.log`:

```
[   17.752053] xhci-hcd xhci-hcd.2.auto: xHCI Host Controller
[   17.752473] xhci-hcd xhci-hcd.2.auto: new USB bus registered, assigned bus number 1
[   17.757508] hub 1-0:1.0: USB hub found
[   17.757806] hub 1-0:1.0: 1 port detected
[   17.758336] hub 2-0:1.0: 1 port detected
[   18.004153] usb 1-1: new high-speed USB device number 2 using xhci-hcd
```

Between the root-hub registration and the attach there is **nothing**: no
`port change`, no `connect status`/CSC, no `reset`, no `hub ... state change`,
no role/typec/UCSI line. The same holds for the 2026-11-05 pre-plug boot
(`15.065 s` attach, no port event before it).

⇒ The full system enumerates a pre-plugged drive on the **first scan of the
root hub**, 246 ms after the hub comes up. There is no fresh CC edge, no
power/data-role change and no AP UCSI command before it. This is the direct
answer to the fork question in
[FULL_SYSTEM_PREPLUG_RESULT.md](FULL_SYSTEM_PREPLUG_RESULT.md): the working
environment does **not** re-classify via an edge — it simply scans the port
*after* the charger service is ready, and the initramfs scans it *before*.

Fix direction that follows: **hold the first scan** (defer the `dwc3-qcom` /
`xhci-hcd` probe until the `charger_pd` PDR), not re-probe later.

## Q1: what holds the xHCI probe — measured, not yet named

Two pre-plug boots, kernel-relative seconds:

| event | 2026-11-05 | 2026-11-06 |
|---|---:|---:|
| `remote processor adsp is now up` | 10.354916 | 13.294832 |
| `PDR: … msm/adsp/charger_pd` | **10.409606** | **13.349062** |
| `xhci-hcd.2.auto: xHCI Host Controller` | **14.813572** | **17.755070** |
| `usb 1-1: new high-speed` (dock) | 15.065426 | 18.004092 |
| `usb-storage 1-1.2` | 15.967114 | 18.958341 |
| `sd 1:0:0:0: [sdg] Attached` | 17.030435 | 20.517641 |
| **Δ(PDR → xHCI)** | **4.403966** | **4.406008** |
| Δ(adsp-up → xHCI) | 4.458656 | 4.460238 |

The PDR→xHCI hold is **4.404–4.406 s on both boots** (≈1 ms apart), while the
absolute boot times differ by 2.9 s — so it is a deterministic wait anchored on
the charger service, not a race.

What was ruled out from userspace (no root needed):

- **No deferral is printed.** The whole boot log has no `EPROBE_DEFER`, no
  `devlink` and no `waiting for` line for the USB chain (only the three
  pre-existing `qcom_pmic_glink: Failed to create device link …` lines at
  0.35/0.45/3.05 s, all `pmic-glink/connector@0` → supplier, not the controller).
- **No devlink supplier is left pending.** `a600000.usb` has 8 suppliers
  (`15000000.iommu`, `1600000.interconnect`, `24100000.interconnect`,
  `1fc0000.clock-controller`, `b220000.interrupt-controller`, `interconnect-1`,
  `phy-88e3000`, `phy-88e8000`); at steady state the six platform ones are
  `status = active` and the two PHY links are `status = not tracked` (they do
  not gate the consumer).
- **The type-C port cannot be the holder.** The link
  `platform:a600000.usb--typec:port0` is `supplier = a600000.usb`,
  `consumer = typec:port0`, `sync_state_only = 1` — i.e. the UCSI/Type-C port
  registers *after* the controller (and after `platform:88e8000.phy` and
  `platform:usb0-sbu-mux`, both also `available`/`sync_state_only`). The port is
  downstream of the delay, not its cause.
- `/sys/kernel/devlink` does not exist on kernel 7.2.6; the file that names the
  holder, `/sys/kernel/debug/devices_deferred`, is `0700` → **root only**.

So the hold is real, constant and not visible without root. Q1 is the one
question this run could not close.

## Q2: the PDR → xHCI window (4.4 s) is silent

Unfiltered `dmesg` between `13.35` and `17.75` (2026-11-06 boot) contains only
ADSP/FASTRPC follow-up (`compute-cb@5..7` iommu groups, `apr/gprsvc`), one
`Handover signaled` line, then input devices (`InputPlumber`, `Steam
Controller` at 14.68/15.53 s) — **no USB, no typec, no UCSI, no battmgr, no
PM activity**. The window is a pure wait, not a burst of work.

## Q4: who sets the glue PM policy

- `power/control = auto` on `soc@0/a600000.usb` comes from
  **`/usr/lib/udev/rules.d/60-armada-usb-autosuspend.rules`** (Armada-specific):

  ```
  ACTION=="add|bind", SUBSYSTEM=="platform", KERNEL=="*.usb", DRIVERS=="dwc3-qcom", ATTR{power/control}="auto"
  ```

  Confirmed with `udevadm test` (the only matching rule; comment in the file
  says an active DWC3 holds a 1 GB/s USB-to-DDR interconnect vote).
- `power/autosuspend_delay_ms = 5000` is **not** set by that rule, by
  `60-autosuspend.rules`, or by hwdb (`60-autosuspend.hwdb` only matches
  `usb:v…p…` device IDs) → it comes from the kernel side (driver default);
  which driver sets 5000 is unverified.
- Root hubs: `usb1 = auto/active/0`, `usb2 = auto/suspended/0`; xHCI child
  `= on/active/0`. Steady state matches the values already recorded in
  [FULL_SYSTEM_PREPLUG_RESULT.md](FULL_SYSTEM_PREPLUG_RESULT.md).
- The initramfs has none of these udev rules (dracut), but PM/L2 is already
  closed as a discriminator (dbg51), so this is context, not a candidate.

## Q5: AP activity before the attach

The only AP-side lines before `18.004 s` are the two `power_supply` synthetic
uevent failures (`qcom-battmgr-usb`, `qcom-battmgr-wls`, `-11`/EAGAIN at
≈10 s) and the `charger_pd` PDR at 13.35 s. The UCSI core prints nothing
(it is silent when it works), and there is no `typec`/`role` line at all.
⇒ Nothing on the AP side triggers the attach; the host's first scan does.

## Fixes applied to `full-system-mechanism-capture.sh` in this run

1. **Wrong timestamps.** `journalctl -o short-iso` stamps every line before the
   RTC/NTP sync (≈7 s) with the bogus RTC date — observed as
   `2026-09-14T08:00:00` for all early boot lines — so the ISO log cannot be
   used for boot timing. Added `full-kern-monotonic.log`
   (`journalctl -b -k -o short-monotonic`) and pointed all W1–W6 windows at it.
2. **False negative without root.** `ucsi debugfs ABSENT (UCSI core not
   active?)` was really "permission denied" (`/sys/kernel/debug` is `0700`).
   Now printed as `NOT READABLE AS ROOT` with the re-run instruction.
3. **Dead devlink section.** `/sys/kernel/devlink` does not exist on 7.2.6, so
   the old loop produced an empty file. It now reports that, checks
   `/sys/kernel/debug/devices_deferred` (root), dumps the **supplier links of
   the USB chain** and the **status/sync_state_only of the devlink nodes** —
   which is what closed the "typec holds the controller" question — and writes
   a new `timeline.txt` with the key events and their deltas.

## Next step

1. **Name the holder (closes Q1):** run the script as root on a pre-plug boot
   before touching any USB device —
   `sudo OUTDIR=/tmp/mech ./scripts/full-system-mechanism-capture.sh` — and/or
   install a root sampler that reads `/sys/kernel/debug/devices_deferred` at
   10 Hz for the first 30 s of a boot. That file lists `device → waiting for
   supplier`, which is exactly the missing answer.
2. **Then test the fix direction:** if the hold turns out to be
   supplier/devlink-based, replicate it in the initramfs (the full system runs
   `fw_devlink.strict=1`; the dbg images' cmdline is not recorded in this repo)
   so the first scan lands after the `charger_pd` PDR — instead of the current
   initramfs behaviour where the USB events (2.716/3.182 s) precede the PDR
   (3.498 s) and are lost.

## Root run (2026-11-06 10:48, same boot)

`sudo OUTDIR=…/mechanism-capture-20261106-104831-root ./scripts/full-system-mechanism-capture.sh`:

- **UCSI debugfs is present** (`/sys/kernel/debug/usb/ucsi/pmic_glink.ucsi.0`):
  `response = 0x0000…0000` (no pending command), `vbus_voltage = 0 mV`,
  `avg_current = 0 mA`, `peak_current = 0 mA`, `command` is write-only.
  So the UCSI glink channel exists and is idle — consistent with Q5 (no AP
  command traffic before the attach).
- **`/sys/kernel/debug/devices_deferred` is empty** — as expected, because the
  deferral is over by the time a shell exists. The file can only answer Q1
  *during* boot.

### Boot sampler installed

[`scripts/boot-deferred-sampler.sh`](../scripts/boot-deferred-sampler.sh) +
[`scripts/boot-deferred-sampler.service`](../scripts/boot-deferred-sampler.service)
are installed on the device (script in `/var/lib/boot-deferred-sampler/`, unit in
`/etc/systemd/system/`, `enabled`) because `/usr/local` is read-only on this
ostree system. It samples `devices_deferred` plus the `dwc3_bound` /
`xhci_present` / `typec_port0` / `role_switch` state every 50 ms for the first
45 s of each boot, prints **only state changes** with kernel uptime, and writes
`/var/tmp/boot-deferred.log`; it also switches on dynamic debug for
`drivers/base/dd.c` / `core.c` / `dwc3` / `xhci_hcd` so the deferral may print
itself. Read-only apart from that dynamic-debug switch (revert:
`echo 'file drivers/base/dd.c -p' > /sys/kernel/debug/dynamic_debug/control`).
