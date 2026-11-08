# When does `usb_type` become `SDP`? — full-system pre-plug, 2026-11-08

**Answer: the PPM classifies the port itself, at the `charger_pd` PDR + ~55 ms,
with no AP actor involved.** There is no userspace, no UCSI command and no
`pmic_glink` message in between — the classification is simply already present
at the first moment the power-supply node becomes readable.

This closes the measurement hole left open in
[FULL_SYSTEM_PREPLUG_RESULT.md](FULL_SYSTEM_PREPLUG_RESULT.md) (next experiment
2: "log the transition") and it decides which of the three trigger paths the
working environment actually uses.

- Run: full system (internal storage), dock + drive pre-plugged, zero actions,
  boot 2026-11-08 13:09:24 (+08).
- Instrument: [`scripts/usb-type-poller.sh`](../scripts/usb-type-poller.sh) +
  [`usb-type-poller.service`](../scripts/usb-type-poller.service), enabled at
  `sysinit.target`, sampling every **50 ms**.
- Raw data: [`../logs/full-system/usb-type-poller-20261108-130924.log`](../logs/full-system/usb-type-poller-20261108-130924.log)
  (poller) and [`../logs/full-system/usb-type-timeline-20261108.txt`](../logs/full-system/usb-type-timeline-20261108.txt)
  (kernel journal excerpt). Both use **kernel uptime** (`/proc/uptime` =
  `journalctl -b -k -o short-monotonic`), so they interleave directly.

## Timeline (kernel-monotonic seconds)

| t | source | event |
|---:|---|---|
| 10.472100 | journal | `remoteproc0: powering up adsp` |
| 10.978070 | journal | `remote processor adsp is now up` |
| **11.024750** | journal | **`PDR: Indication received from msm/adsp/charger_pd`** |
| 11.032820 | journal | `qcom_pmic_glink_rpmsg … driver_bound` (+8.0 ms) |
| 11.056024 | journal | `device: 'ucsi-source-psy-pmic_glink.ucsi.01': device_add` (+31 ms) |
| 11.056532 | journal | `typec port0: Linked … consumer to a600000.usb` |
| **11.08** | **poller** | **`usb_type` current = `SDP`, `online=1`, V = 9 083 000 µV** ← **PDR + 55 ms**; `data_role` still `device`, `opmode=1.5A`, `src usb_type` current `C` |
| 11.71 | poller | **VBUS collapse**: `online=0`, **V = 6 000 µV**, `usb_type` current → `Unknown` |
| 12.52 | poller | VBUS back: `online=1`, V = 5 249 000 µV, 356 mA, `usb_type` current = `SDP` |
| 12.75 | poller | `opmode` → `usb_power_delivery` (PD negotiation), V = 5 226 000 µV |
| **15.408122** | journal | `device: 'a600000.usb': device_unregister` (gadget UDC torn down) |
| **15.412062 → 15.413854** | journal | `device: 'xhci-hcd.2.auto': device_add` → `xHCI Host Controller` — **Δ(PDR) = 4.387 s** |
| 15.43 | poller | `data_role` → `[host]`, `usb_role` → `host`, V = 8 661 000 µV, 2.253 A (9 V contract) — within one poller sample of the xHCI `device_add` |
| 15.448833 | journal | `set port power 1-1 ON` |
| 15.453678 | journal | `Port change event, 1-1` (connect) |
| **15.664363** | journal | `usb 1-1: new high-speed USB device number 2` — first scan finds the dock |
| 16.171767 / 16.648103 / 16.812086 | journal | `1-1.1` (full-speed hub port) → `1-1.2` (`usb-storage`) → `1-1.3` |
| **18.320090** | journal | `sd 1:0:0:0: [sdg] Attached SCSI disk` (500 GB) |
| 20.23 | poller | `usbs=sdg` (the block scan runs every 2 s, so this bounds the attach to 18.2–20.2 s) |
| — | system | `/dev/sdg2` → `/run/media/armada/Slim` |

Role flip → drive attach = **2.91 s**; PDR → drive attach = **7.30 s**.

## What this means

1. **Trigger path #1 (initial detection at PPM boot) is the one that fires.**
   At 11.08 s the in-kernel UCSI core had issued nothing: its power-supply node
   only *appears* at 11.056 s because the **PPM pushed state at it**, not the
   other way round. There is no fresh CC edge (pre-plug) and `SetRerunApsd`
   is config-gated off in every environment
   ([ADSP_RE.md](ADSP_RE.md#trigger-table-consolidated)) — so paths #2 and #3
   were not needed and were not used.
2. **The classification is not an event, it is the state at the PDR.** What
   follows 11.08 s is a *power-path* re-negotiation, not a classification:
   9.08 V present → VBUS collapses to 6 mV (11.71) → back at 5.25 V with
   `SDP` (12.52) → PD negotiation (12.75) → 9 V contract + data-role swap to
   host (15.4, coinciding with the gadget→xHCI flip) → first scan (15.66) →
   drive (18.32). The `Unknown` seen at 11.71 s is a 0.8 s side effect of the
   VBUS bounce, not a re-detection failure.
3. **The discriminator vs the initramfs is therefore the PPM state at the PDR,
   not an AP trigger.** The initramfs gets the same `charger_pd` PDR
   (dbg49: 3.498103 s) and brings up the same UCSI/typec nodes, yet
   `usb_type` never leaves `[Unknown]`, `online` stays 0 and V stays
   5.062 V with no PD contract — for minutes (dbg1400: unchanged to t≈366 s).
   Same trigger, same timing, different firmware-side state. That is the
   ABL-leftover-state hypothesis ([ABL_DR_MODE_HOST.md](ABL_DR_MODE_HOST.md),
   reconciliation in [KERNEL_PATCH_1400.md](KERNEL_PATCH_1400.md)) now carrying
   the only remaining explanation.
4. **New data point for the PDR → xHCI range: Δ = 4.387312 s.** The documented
   range (2.7–4.4 s, a UCSI ↔ ADSP round trip, not a fixed timer) now has
   samples 2.754997 / 3.155016 / 4.387312 / 4.403966 / 4.406008 s.
5. **`Δ(role flip → first scan) = 0.256 s`** and the poller resolves the
   `data_role` change to within one 50 ms sample of the `xhci-hcd.2.auto`
   `device_add` — independent confirmation that the role flip *is* the
   creation of the host controller (Q1 in
   [FULL_SYSTEM_MECHANISM_CAPTURE.md](FULL_SYSTEM_MECHANISM_CAPTURE.md)).

## Caveats

- The poller starts at `sysinit.target`; its first sample here is **8.66 s** and
  every field reads `?` because the power-supply nodes do not exist yet. So the
  exact first-`SDP` instant is bounded, not pinned: **≤ 11.08 s and ≥ 11.056 s**
  (the `ucsi-source-psy` `device_add`). 50 ms resolution is enough to separate
  the phases above, not to order events inside a single 50 ms slice.
- The USB block scan runs every 2 s (`usbs=` field), so `usbs=sdg` at 20.23 s
  only bounds the attach; the journal has the exact 18.320090 s.
- One boot. The phase sequence (9 V → collapse → 5 V → PD → 9 V) should be
  checked on a second boot before it is treated as the canonical order — the
  poller is installed and can be re-enabled with
  `systemctl enable --now usb-type-poller.service` (it was stopped after this
  run so the log does not grow on every boot).
- `usb_type=SDP` coexisting with `power_role=sink` (a source-type value on a
  power sink) is still unexplained — see [RESULTS.md](RESULTS.md); it does not
  affect the timing conclusions above.

## Raw poller output (CHANGE lines only)

```
[8.66]   CHANGE [?] online=? V=? uA=? | src=[?] on=? | power=? data=? opmode=? partner=no role=device, usbs=-
[11.08]  CHANGE [Unknown [SDP] …] online=1 V=9083000 uA=0 | src=[[C] PD PD_PPS] on=1 | power=source [sink] data=host [device] opmode=1.5A partner=yes role=device, usbs=-
[11.71]  CHANGE [[Unknown] SDP …] online=0 V=6000 uA=0 | src=[[C] PD PD_PPS] on=1 | power=source [sink] data=host [device] opmode=1.5A partner=yes role=device, usbs=-
[12.52]  CHANGE [Unknown [SDP] …] online=1 V=5249000 uA=356000 | src=[[C] PD PD_PPS] on=1 | power=source [sink] data=host [device] opmode=1.5A partner=yes role=device, usbs=-
[12.75]  CHANGE [Unknown [SDP] …] online=1 V=5226000 uA=212000 | src=[C [PD] PD_PPS] on=1 | power=source [sink] data=host [device] opmode=usb_power_delivery partner=yes role=device, usbs=-
[15.43]  CHANGE [Unknown [SDP] …] online=1 V=8661000 uA=2253000 | src=[C [PD] PD_PPS] on=1 | power=source [sink] data=[host] device opmode=usb_power_delivery partner=yes role=host, usbs=-
[20.23]  CHANGE [Unknown [SDP] …] online=1 V=8655000 uA=2256000 | src=[C [PD] PD_PPS] on=1 | power=source [sink] data=[host] device opmode=usb_power_delivery partner=yes role=host, usbs=sdg,
```

(then one `steady` heartbeat every 10 s, identical content.)

## Next

The same instrument belongs in the initramfs to get the failing side of the
comparison — and that is part of the initramfs plan in
[INITRAMFS_CHANGES.md](INITRAMFS_CHANGES.md).
