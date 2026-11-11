# Full-system pre-plug in the **source** role — the control boot (2026-11-11)

Status: **the control boot that [INITRAMFS_CHANGES.md](INITRAMFS_CHANGES.md)
asked for is done — and it succeeded.** The confound it was meant to rule out
("full system + directly-attached stick + source role") is ruled out *in favour
of the initramfs*: the full system enumerates a pre-plugged stick with the
**same PPM fingerprint as the failing initramfs** (`usb_type=[Unknown]` + the
skip-while-sourcing gate + ICM `ncp_stby`).

This document records the whole measurement round: the source-role pre-plug
boots (normal and reverse orientation), the source-role hot-plug / re-plug
failure, the dock reference, and the initramfs `dracut` screenshot. Raw
evidence is under [`logs/preplug-source/`](../logs/preplug-source/).

## TL;DR

- **`usb_type` / PPM classification is not the blocker.** In the full system the
  port is `usb_type=[Unknown]`, the PPM logs
  `skip checking usb charging type while usb is sourcing`, the ICM stays in
  `ncp_stby` — and the stick **enumerates anyway** (device at 13.05 s).
- **The `linux usb` initramfs failure is the early xHCI scan.** Full system:
  PDR 12.454 s → first port scan **12.787 s (post-PDR)** → device 13.05 s.
  Initramfs (dbgB): port scan **2.7 s, before the PDR at 3.5 s** → nothing.
- **⇒ the fix is a post-PDR rescan inside the initramfs** (lever **C** in
  [INITRAMFS_CHANGES.md](INITRAMFS_CHANGES.md): unbind/rebind `dwc3-qcom`/xHCI
  after the `PDR: Indication … charger_pd` line). The `usb_type`/classification
  work (lever D, firmware byte) is **not needed** for enumeration.
- **Orientation matters** on this board: reverse orientation can leave the data
  path unrouted for minutes (or forever); the USB-boot recipe must require
  **normal** orientation.
- **A separate kernel bug** kills xHCI on any *runtime* source-role re-probe
  (`Host halt failed, -110`) — hot-plug/re-plug only, not the boot scenario.

## Setup

- The RP6 has **one** USB-C port. "Source role" = the RP6 supplies VBUS and is
  the USB **host**; the partner is the stick itself (no PD contract).
- Instrument: [`preplug-capture.sh`](#instrument) (unprivileged, systemd user
  oneshot at session start) — snapshots `typec`/`power_supply`, the full boot
  journal (`journalctl -b -o short-monotonic`), and a 180 s poller.
- Test stick = the user's spare (`VendorCo ProductCode`, 58.6 GiB). The Slim
  Netac 465.8 GiB data drive was never touched.
- `sda–sdf` (`YMTC YMUS8B4TF1D1C1`) attach at ~0.82 s — **internal** RP6 disks,
  not USB; ignored throughout.

## Measurement round — A–F

All timestamps are kernel-uptime seconds (`journalctl -o short-monotonic`).

| # | scenario | role | orientation | result |
|---|---|---|---|---|
| **A** | full system, PD dock pre-plugged | sink | — | ✓ hub at 14.19 s; the drive behind the hub only at **96.68 s** (81 s USB-suspend) |
| **B** | full system, **hot-plug** after dock removal | source | — | ✗ xHCI **`Host halt failed, -110`**; no recovery |
| **C** | full system, **re-plug** (fresh CC edge) | source | normal | ✗ same **-110** |
| **D** | full system, pre-plug | source | **reverse** | △ xHCI alive, `ConnectStatus=0` for **464 s**, then a spontaneous connect → enumerated |
| **E** | **full system, pre-plug** | **source** | **normal** | **✓ device 13.05 s, storage 13.20 s, SCSI 14.21 s, `sdg` 14.21 s** |
| **F** | initramfs, pre-plug (dbgB) | source | — | ✗ port scan 2.7 s **before** PDR 3.5 s; never rescanned |

**Reading.** A is the sink reference (the dock is the power source and also a
hub, so the drive sits behind it and is subject to the hub's suspend). E is the
decisive boot: **the source-role pre-plug scenario the USB boot needs works in
the full system**. F is the same scenario inside the initramfs and it fails — the
only measured difference is *when* xHCI scans relative to the PDR.

## E — the decisive boot (normal orientation, SUCCESS)

Capture: [`logs/preplug-source/e-normal-success-20261111-172918/`](../logs/preplug-source/e-normal-success-20261111-172918/).
Stick directly attached (no hub), pre-plugged, booted into the full system.

| t (s) | event |
|---|---|
| 11.540 | `remoteproc0: powering up adsp` |
| 12.398 | `remote processor adsp is now up` |
| **12.454** | **`PDR: Indication received from msm/adsp/charger_pd`** |
| **12.787** | **xHCI `Port change event, 2-1 … portsc: 0x2802a0`** (first scan, post-PDR + 0.33 s) |
| 12.828 | xHCI `Port change event, 1-1 … portsc: 0xa0206e1` — **bit 0 set = connected** |
| 13.052 | `usb 1-1: new high-speed USB device number 2 using xhci-hcd` |
| 13.198 | `usb-storage 1-1:1.0: USB Mass Storage device detected` |
| 14.207 | `scsi 1:0:0:0: Direct-Access VendorCo ProductCode 2.00` |
| 14.210 | `sd 1:0:0:0: [sdg] 122880000 512-byte logical blocks: (62.9 GB/58.6 GiB)` |

The `typec` state at the same time (from `typec-power.txt`):

```
data_role  = [host] device
orientation= normal
power_role = [source] sink
qcom-battmgr-usb  usb_type=[Unknown] SDP DCP CDP ACA C PD PD_DRP PD_PPS BrickID  online=0  V=5063000
```

The PPM's own ULog for this boot (from `ppm-fingerprint.txt`) — the
**failing-side fingerprint**:

```
12.741811  charger_detection_evaluate_typec_charger: charger detection: Input[0] bLpdEn=0, bLiquidDetected=0
12.741830  battmngr_plat_scpqchg_qbg_r1_update_wlstx_otg_context: otg enable: 1
25.022890  charger_detection_event_handler: skip checking usb charging type while usb is sourcing
25.022901  Warn: icm_ncp_stby_main: keeps in icm_ncp_stby utill charger_type updated
```

**`usb_type=[Unknown]`, the skip-while-sourcing gate fired, the ICM is parked in
`ncp_stby` — and the drive enumerated at 13.05 s.** This is the measurement that
kills the "AP gates boot on `usb_type`" hypothesis and the whole
classification-first line of work.

## D — reverse orientation (△, then spontaneous connect)

Capture: [`logs/preplug-source/d-reverse-preplug-20261111-170417/`](../logs/preplug-source/d-reverse-preplug-20261111-170417/),
watcher: [`logs/preplug-source/d-reverse-spontaneous-flip-watch-20261111.log`](../logs/preplug-source/d-reverse-spontaneous-flip-watch-20261111.log).

Same setup as E but the stick was inserted in the **reverse** orientation.
In the 180 s capture window:

```
12.739611  PDR: Indication received from msm/adsp/charger_pd
12.799625  xhci-hcd xhci-hcd.2.auto: Port change event, 2-1, id 2, portsc: 0x2802a0
(no further USB events — ConnectStatus = 0, portsc bit 0 clear)
```

`orientation = reverse`, `power_role = [source]`, `usb_type=[Unknown]`. The
`dmesg -w` watcher (started later, reading the whole boot) shows the data path
eventually coming up **on its own**:

```
464.200976  Port change event, 2-1, id 2, portsc: 0x2802a0
464.228282  Port change event, 1-1, id 1, portsc: 0xa0206e1   <- connected (bit 0)
464.453443  usb 1-1: new high-speed USB device number 2 using xhci-hcd
464.600052  usb-storage 1-1:1.0: USB Mass Storage device detected
465.670931  sdg: sdg1 sdg2 sdg3
465.671762  sd 1:0:0:0: [sdg] Attached SCSI removable disk
```

Then, after the user **flipped the stick to normal** (disconnect `0x202a0` at
539.5 s, reconnect at 547.3 s), it re-enumerated immediately at 548.77 s.

**Reading.** Reverse orientation leaves the USB data path unrouted for minutes
(or never) even though CC/VBUS are fine; normal orientation enumerates at once
(E). ⇒ **the USB-boot recipe must specify normal orientation.** (The 464 s
spontaneous connect means reverse is not *deterministically* dead, only
unreliable — do not build a procedure on it.)

## B / C — a source-role role switch kills xHCI (`-110`)

Watcher: [`logs/preplug-source/bc-roleswitch-110-watch-20261111.log`](../logs/preplug-source/bc-roleswitch-110-watch-20261111.log).

In a live source-role session (dock attached, then removed):

```
2841.050348  Port change event, 1-1, id 1, portsc: 0x202a0      <- dock unplugged
2873.545138  xhci-hcd xhci-hcd.2.auto: probe with driver xhci-hcd failed with error -110
2874.663271  xhci-hcd xhci-hcd.2.auto: Host halt failed, -110
2874.663434  xhci-hcd xhci-hcd.2.auto: probe with driver xhci-hcd failed with error -110
...
5862.998729  Host halt failed, -110                              <- re-plug: same failure
5862.998951  probe with driver xhci-hcd failed with error -110
```

The trigger is the runtime re-probe of the host controller after the port is
reconfigured (empty ↔ occupied). It is accompanied by a QMP-combo PHY clock
`WARN` (`clk_core_unprepare` on an already-unprepared clock, via
`qmp_combo_typec_switch_set` → `pmic_glink_ucsi_connector_status`). A **fresh CC
edge does not recover it**; only a reboot does.

**This is a separate kernel/driver bug** (hot-plug robustness), **not** the boot
scenario: at boot the controller probes **once**, after the PDR, with the stick
already present — that is exactly E, and it works. It is recorded here because
it constrains any "unbind/rebind to rescan" design: the rebind must happen
**once, early, before the port has been through a live role switch**, and must
not be combined with a runtime role change.

## A — the dock (sink) reference

With the PD dock attached, the dock is the power source and also a USB hub, so
the drive is a device *behind* the hub. Two dock boots were captured
(`a-dock-reverse-20261111-162720`, `g-dock-normal-20261111-174454`); in the
first the hub came up at 14.19 s but the drive behind it only at **96.68 s**
(an 81 s USB-suspend gap) — a reminder that pre-plug enumeration behind a hub is
not instant, and why the clean direct-attach boot (E) is the right control.
The sink-role `usb_type` behaviour is covered in [ADSP_ULOG.md](ADSP_ULOG.md).

## F — the initramfs, and the `dracut` screenshot

The failing initramfs fingerprint is unchanged from dbgB
([logs/dbgB-preplug-usb-ulog-20261109.txt](../logs/dbgB-preplug-usb-ulog-20261109.txt)):
the xHCI port scan runs at **2.7 s, before the PDR at 3.5 s**, and never repeats.

The user supplied a photo of the initramfs console
([`logs/preplug-source/initramfs-dracut-timeout-20261111.md`](../logs/preplug-source/initramfs-dracut-timeout-20261111.md),
transcribed with a locally-extracted `tesseract` — no root needed). It shows the
same source-role PPM fingerprint (`usb_type=[Unknown]`, `src=[C]`, `ncp_stby`,
`seen=28…30`) **and** the consequence:

```
141.017935  dracut-initqueue[523]: Warning: dracut-initqueue: timeout, still waiting for following initqueue hooks:
141.022031  dracut-initqueue[523]: Warning: /lib/dracut/hooks/initqueue/finished/devexists-\x2fdev\x2fd isk\x2fby-uu id\x2f49a99c0a-3e...
141.062811  dracut-initqueue[523]:   -e "/dev/disk/by-uuid/49a99c0a-3e...
141.583555  dracut-initqueue[523]: Warning: dracut-initqueue: starting timeout scripts
```

dracut waits for the USB root `/dev/disk/by-uuid/49a99c0a-3e…` and loops the
timeout scripts because the stick never enumerated. With lever C the
`devexists` hook would be satisfied immediately after the post-PDR rescan.

## Verdict and what changes

1. **`usb_type` / classification is dead as the fix.** E proves the source-role
   pre-plug scenario enumerates with the failing-side PPM fingerprint. Stop
   pursuing classification (lever D / firmware byte) for *enumeration*.
2. **The fix is lever C:** a post-PDR rescan inside the initramfs — wait for the
   `PDR: Indication … charger_pd` line, then unbind/rebind `dwc3-qcom` (or the
   xHCI host) so the host controller scans **after** the PDR, exactly like E.
3. **Normal orientation is required** (D).
4. The `-110` role-switch failure (B/C) is a **separate** bug; keep the rescan
   single-shot and early so it is never hit.

Next boot: build the lever-C initramfs (post-PDR rebind hook) and run
`linux usb` with the stick pre-plugged in normal orientation; criterion =
enumeration **without** a re-plug, mirroring E.

## Instrument

`preplug-capture.sh` (also `~/.config/systemd/user/preplug-capture.service`,
enabled): at session start it writes `header.txt`, `typec-power.txt`, the full
`boot-journal.txt` (`journalctl -b -o short-monotonic`), `lsblk`/`lsusb`
snapshots, a copy of the boot-time PPM ULog, and a 180 s `poll.csv`
(`t_s,lsblk_disks,usb_type,online,V_uV,power_role,data_role` every 3 s). No root.

## References

- the control-boot request and the plan it changes:
  [INITRAMFS_CHANGES.md](INITRAMFS_CHANGES.md)
- success-side PPM fingerprint (sink/dock): [ADSP_ULOG.md](ADSP_ULOG.md)
- failing-side initramfs fingerprint: [../logs/dbgB-preplug-usb-ulog-20261109.txt](../logs/dbgB-preplug-usb-ulog-20261109.txt)
- why the early scan exists: [ABL_DR_MODE_HOST.md](ABL_DR_MODE_HOST.md)
- raw evidence: [../logs/preplug-source/](../logs/preplug-source/)
