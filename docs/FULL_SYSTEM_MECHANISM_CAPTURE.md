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

## Q1 (answered): nothing *holds* the xHCI probe — the host controller does not exist until the role flips to HOST

**Correction to the first version of this document.** The two boots available
then gave Δ(PDR → xHCI) = 4.403966 s / 4.406008 s (≈1 ms apart, absolute boot
times 2.9 s apart) and it was written up as "a deterministic wait anchored on
the charger service". It is **not** deterministic: two further pre-plug boots
with the boot sampler give 3.155016 s and 2.754997 s. It is a **service round
trip** (UCSI ↔ ADSP), not a fixed timer.

### The measured chain

Two pre-plug boots with `boot-deferred-sampler` running from ~9 s, kernel-relative
seconds (the second boot is the 11:57:18 one, where dynamic debug was on):

| event | 10:57 boot | 11:57 boot |
|---|---:|---:|
| `remote processor adsp is now up` | 10.236830 | 14.512993 |
| `PDR: … msm/adsp/charger_pd` | **10.310955** | **14.560018** |
| `qcom_pmic_glink_rpmsg` bound (ADSP channel) | 10.321570 (+10.6 ms) | 14.580344 (+20.3 ms) |
| `ucsi-source-psy-pmic_glink.ucsi.01` added | 10.556061 | 14.604060 |
| `typec port0` devlink (`…--typec:port0`) | 10.560994 | 14.604638 |
| **`device: 'a600000.usb': device_unregister`** | **13.461045** | **17.304077** |
| **`device: 'xhci-hcd.2.auto': device_add`** | **13.461492** (+0.4 ms) | **17.308142** (+4.1 ms) |
| `xhci-hcd.2.auto: xHCI Host Controller` | 13.465971 | 17.315015 |
| `usb 1-1: new high-speed` (first scan) | 13.728065 | 17.650248 |
| `sd 1:0:0:0: [sdg] Attached` | 15.610103 | 20.030283 |
| Δ(PDR → role flip) | 3.150090 | 2.744059 |
| Δ(PDR → xHCI probe) | 3.155016 | 2.754997 |
| Δ(typec port0 → role flip) | 2.900051 | 2.699439 |

Earlier boots (11-05, 11-06 10:15): Δ(PDR → xHCI) = 4.403966 / 4.406008 s —
same shape, longer UCSI round trip.

### What this means

1. **No supplier holds the controller.** `a600000.usb` **never** appears in
   `/sys/kernel/debug/devices_deferred` on either boot (sampled every 50 ms for
   45 s as root; grep count 0), and there is no `EPROBE_DEFER` /
   `Retrying from deferred list` line for it anywhere in the boot log. The
   deferred list only ever contains soundwire/codec/pinctrl nodes. Q1's original
   framing — *which supplier waits* — has the answer: **none**.
2. **The glue is already bound long before the host controller exists.**
   `dwc3_bound=1` at the sampler's first sample (9.48 s / 8.99 s, i.e. the glue
   probe finished before 9 s) while `xhci_present` only becomes 1 at 13.51 s /
   17.33 s. The xHCI device is **created** ~4–8 s later, not blocked.
3. **Why it is created that late.** The DT node `usb@a600000` has **no
   `dr_mode`** and does have `usb-role-switch`, so `dwc3-qcom` comes up in
   **gadget mode**: a UDC named `a600000.usb` exists first (`/sys/class/udc/` is
   empty *now*), the kernel exports `dwc3_drd_init`/`dwc3_drd_notifier`, and
   `usb_role/…-role-switch/role` is `host`. When the Type-C stack flips the role
   to HOST, the UDC is torn down (`device_unregister 'a600000.usb'`) and
   `dwc3_host_init()` adds `xhci-hcd.2.auto` **0.4–4 ms later**. The host side
   therefore only exists after that flip — which is why nothing could be found in
   `devices_deferred`.
4. **The flip needs the ADSP charger path.** PDR → (+10–20 ms) pmic-glink rpmsg
   → (+44–234 ms) UCSI power supply + `typec:port0` → (**2.7–4.4 s** contract
   round trip) → role = HOST → xHCI → first scan finds the pre-plugged dock.
   The full system enumerates **on the first scan** (Q3), so the only thing the
   initramfs lacks is reaching this state before it scans.

### Still ruled out (from the first version, unchanged)

- **No devlink supplier is left pending.** `a600000.usb` has 8 suppliers
  (`15000000.iommu`, `1600000.interconnect`, `24100000.interconnect`,
  `1fc0000.clock-controller`, `b220000.interrupt-controller`, `interconnect-1`,
  `phy-88e3000`, `phy-88e8000`); at steady state the six platform ones are
  `status = active` and the two PHY links are `status = not tracked` (they do
  not gate the consumer).
- **The type-C port is not a *supplier* gate.** The link
  `platform:a600000.usb--typec:port0` is `supplier = a600000.usb`,
  `consumer = typec:port0`, `sync_state_only = 1` — the UCSI/Type-C port
  registers *after* the controller. It is not what blocks the probe; it is what
  *releases* the host mode (see above).
- `/sys/kernel/devlink` does not exist on kernel 7.2.6, so
  `/sys/kernel/debug/devices_deferred` (root, `0700`) was the only candidate —
  and it is empty of USB entries on every sampled boot.

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
- `/sys/kernel/devlink` does not exist on kernel 7.2.6; naming a *holder* from
  `/sys/kernel/debug/devices_deferred` (root, `0700`) turned out to be moot —
  with root sampling during boot the file simply has no USB entry (see point 1
  above).

Q1 is closed: there is no holder to name. The wait is on the ADSP/UCSI side,
before the host-side device exists at all.

## Q2: the PDR → xHCI window (2.7–4.4 s) is silent on the AP

Unfiltered `dmesg` between `13.35` and `17.75` (2026-11-06 10:15 boot) contains
only ADSP/FASTRPC follow-up (`compute-cb@5..7` iommu groups, `apr/gprsvc`), one
`Handover signaled` line, then input devices (`InputPlumber`, `Steam
Controller` at 14.68/15.53 s) — **no USB, no typec, no UCSI, no battmgr, no PM
activity**. The window is a pure wait, not a burst of work.

With dynamic debug on (10:57 boot) the same window shows the AP side is busy but
**only with audio deferral churn** (`6ac0000.codec`, `6ad0000.soundwire`,
`6e80000.pinctrl` … `Added to deferred list`) — nothing USB-related. Those nodes
are the only residents of `devices_deferred` on any boot; the audio drivers are
not shipped in the initramfs at all (the dbg logs contain no `deferred` line and
no `6ac0000` reference), which is why this file could never name a USB holder.

The waiting party is on the **ADSP side**: the role flip happens 2.7–4.4 s after
the `typec:port0` registration with no AP-side activity in between, i.e. a
UCSI ↔ ADSP contract round trip.

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

Q1 is closed (no supplier holds the controller; the host side is *created* on
the role flip), so the old plan — "hold the first scan until after the PDR" — is
**not** the fix: the initramfs already scans repeatedly and the dock never
presents a device. The remaining question is why the initramfs never reaches the
state the full system reaches:

- initramfs: `dat=[host]` and `xhci-hcd.0.auto` up from ~0.5 s (the role never
  has to flip), `pw=[source]`, v = 5.06 V, hub `CCS=0`,
  `port-change=2 new-dev=0` for 58 s, and ADSP
  `icm_ncp_stby … untill charger_type updated` still at 33 s **and** 52 s
  ([dbg49](../logs/dbg49-adsp-icm-ncp-stby.txt)).
- full system: gadget first → role flip 2.7–4.4 s after the PDR → dock present
  at the **first** scan; steady state `power_role=sink`, `usb_type=SDP`.

⇒ **Why does the ADSP never get `charger_type` in the initramfs** (and does the
`power_role` difference — `source` vs `sink` — mean the CC/PD contract never
completes, so the dock never turns on its upstream device)? Once that is known,
the fix is to make the initramfs reach that contract state, not to move the scan.

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

### Sampler results — two pre-plug boots (2026-11-06 10:57 and 11:57)

Log: [`logs/full-system/boot-deferred.log`](../logs/full-system/boot-deferred.log)
(both runs, appended by the unit).

| | 10:57 boot | 11:57 boot |
|---|---:|---:|
| `first_dwc3_bound` | 9.48 (glue already bound at first sample) | 8.99 (same) |
| `first_typec_port0` | 10.59 | 14.67 |
| `first_xhci_present` | 13.51 | 17.33 |
| xHCI probe (`xHCI Host Controller`) | 13.466 | 17.315 |
| `last_nonempty_deferred` | 14.62 (audio nodes only) | 17.84 (audio nodes only) |
| `a600000.usb` in `devices_deferred` | **never** | **never** |

The glue (`dwc3-qcom`) is bound before the sampler's first sample on both boots
while the `xhci-hcd.*.auto` child appears 4.0 / 8.3 s later — i.e. the host
controller is *created* late, not deferred. The `deferred=[…]` payload contains
only `6ac0000.codec` / `6ad0000.soundwire` / `6d30000.soundwire` /
`6e80000.pinctrl` / `6d44000.codec` / `6aa0000.codec` / `sound`.

**Side effect to fix before the next run:** `module xhci_hcd +p` floods the
ring buffer — on the 10:57 boot `dmesg` line 1 was already `[13.470754]`, so the
whole early boot (including the adsp/PDR lines) had been evicted. Everything was
recovered from `journalctl -b -k -o short-monotonic`, which journald had already
consumed. Narrow the switch to `dd.c`/`core.c` (drop `dwc3`/`xhci_hcd`) so
`dmesg` stays usable.
