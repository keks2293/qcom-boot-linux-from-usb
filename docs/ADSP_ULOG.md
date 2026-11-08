# The PPM's own charger log, read from the AP

Status: new instrument (2026-11-08). The stock kernel ships an AP-side reader
for the PPM (ADSP) charger ULog — `pmic_pdcharger_ulog.ko` — that has
**never been loaded in any environment** (full system or initramfs). With it,
the PPM's own view of the boot — initial detection, ICM `ncp_stby`, the
charger state machine — is readable directly, with **no custom dbg firmware
image**. This is what lever **B** in [INITRAMFS_CHANGES.md](INITRAMFS_CHANGES.md)
asked for; the module is already in the initramfs image, so B collapses to
`modprobe` + tracefs.

## How it works

- `pmic_pdcharger_ulog.ko` binds the rpmsg channel `PMIC_LOGS_ADSP_APPS`
  (the PPM ULog glink channel, visible in `qcom_glink` traces as
  `PMIC_LOGS_ADSP_APPS[5/9]`).
- It polls `GET_CHG_ULOG_REQ` (opcode `0x18`, owner `32778`) once per second
  (`LOG_DEFAULT_TIME_MS 1000`) and emits every returned line through the
  tracepoint `pmic_pdcharger_ulog:pmic_pdcharger_ulog_msg`. Each poll is one
  glink tx (16 B request) + rx (up to 8204 B response).
- The PPM-side ULog is an **8 KB drain ring**: each GET returns only the lines
  logged *since the previous GET*. Lines logged before the first GET (ADSP
  boot → channel bind) are in the first drain only if the ring has not already
  wrapped; under boot-time logging load a single 1 s poll interval can exceed
  the ring and lines are lost (the charger-SM 2→4 transition line was lost
  exactly this way in the boot-1 capture).
- No module dependencies, no `MODULE_DEVICE_TABLE` — the source comment says
  it is *"loaded manually only"*, which is why nothing has ever auto-loaded
  it. `modprobe pmic_pdcharger_ulog` is the entire setup.
- **Already in the stock initramfs** (verified with `lsinitrd` on the stock
  7.2.6 image: `usr/lib/modules/7.2.6/kernel/drivers/soc/qcom/pmic_pdcharger_ulog.ko`),
  so it works in the initramfs identically: mount tracefs, `modprobe`, enable
  the tracepoint.
- **Never `rmmod` it in a live session.** Unloading unregisters the rpmsg
  endpoint, which tears the channel down on the PPM side; it does not come
  back until an ADSP restart (observed: `device: …PMIC_LOGS_ADSP_APPS…:
  device_unregister`, no re-announce for the rest of the session).

## Instrument

`scripts/adsp-ulog-capture.sh` + `scripts/adsp-ulog-capture.service`:

- ordered at `sysinit.target` with `DefaultDependencies=no`; loads the module,
  enables the tracepoint plus the glink transport event (filter
  `channel ~ "PMIC_LOGS*"`), sets the buffer to 64 MB, and runs the 40 s dump
  loop **in the background** so boot is not delayed.
- output: kmsg markers (ADSP power-up, "adsp is now up", `PDR: Indication`,
  driver bind) + the full trace → `/var/tmp/adsp-ulog-capture.log`.
- installed on device at `/var/lib/adsp-ulog-capture/capture.sh` +
  `/etc/systemd/system/adsp-ulog-capture.service`, enabled (2026-11-08).
- `CAPTURE_S` env var overrides the 40 s window.

## Boot 1 — the success-side fingerprint (2026-11-08 15:39, full system, pre-plug)

All times are kernel-uptime seconds (journal `short-monotonic` = same clock as
the trace and the poller).

| t (s) | source | event |
|---|---|---|
| 8.62 | poller | `usb-type-poller` starts |
| 12.0120 | kernel | `powering up adsp` |
| 12.4853 | kernel | `remote processor adsp is now up` |
| 12.5280 | kernel | **`PDR: Indication … charger_pd`** (ADSP-up + 42.7 ms) |
| 12.5487 | kernel | `PMIC_LOGS_ADSP_APPS` device_add → `qcom_pmic_pdcharger_ulog_rpmsg` bound (PDR + 20.7 ms) |
| 12.5499 | ULog drain 1 | **first drain (PDR + 21.9 ms)** — the initial-detection result (below) |
| 12.58 | poller | `usb_type=[Unknown]`, `online=0`, VBUS already 5.226 V |
| 12.82 | poller | **`usb_type=[SDP]`** (PDR + 294 ms), `online=1`, 5.262 V / 356 mA, `opmode=1.5A` |
| 13.01 | poller | PD contract (`opmode=usb_power_delivery`) |
| 14.5921 | ULog drain 3 | Run level 3 + ActivePort PartnerType=15 @ 9 V / 2440 mA (below) |
| 15.72 | poller | role=host, V = 8.954 V |
| 15.9560 | kernel | `usb 1-1: new high-speed USB device` |
| 17.8613–17.9201 | kernel | `[sdg]` detected → `Attached SCSI disk` |
| 18.06 | poller | `usbs=sdg` |
| 20.7349 | ULog drain 9 | **first `sm_state_loop: curr=4`** — charger SM reaches Run |
| 43.0071 | ULog | heartbeat `event_type=24, curr=4` + `scp_inov_db: fcc_ma=5700, icl_ma=2440, vin_mv=9000` |

### First drain (PDR + 21.9 ms) — the PPM's initial detection

```
typec_detect_partner: ssdev_typec::InputNum=0, TypeCPartnerType=0
charger_detection_evaluate_typec_charger: charger detection: Input[0] bLpdEn=0, bLiquidDetected=0
charger_detection_evaluate_typec_charger: charger detection: Input[0] PartnerType=2, Voltage=5000 mV, Current=900 mA bPDSuspendSupported:0
sm_state_loop: charger state: event_type=10, curr=0, next=1, status=0x0
sm_state_loop: charger state: event_type=10, curr=1, next=2, status=0x0
sm_state_loop: charger state: event_type=10, curr=2, next=2, status=0x0
battmngr_plat_scpqchg_qbg_r1_update_wlstx_otg_context: otg enable: 1
Warn: …update_wlstx_otg_context::OTG source not available
```

The PPM detected the partner (PartnerType=2, 5 V / 900 mA) within ~65 ms of
ADSP boot — this *is* the initial detection that `USB_TYPE_TIMING.md` measured
as "classified at PDR + 55 ms" from the AP side. The
`charger_detection_inital_detection: adsp rerun status=0x%X` line (the
AP-triggered rerun path) is **absent** on the success boot: the initial
detection at boot does not go through that path (and/or its line landed before
the first drain). The `charger_detection_evaluate_typec_charger …
PartnerType=` line is the detection result to look for in the failing env.

### Third drain (PDR + 2.06 s) — the PD contract reflected in the PPM

```
BattMngrStateMachineLevel_Run_Current_State: Current state is 3
charger_detection_get_active_charger: ActivePort[0] PartnerType=15, Voltage_max=9000 mV, Voltage_min=9000 mV, Current_max=2440 mA Power_max_uw=21960000 uW
battmngr_plat_scpqchg_qbg_r1_check_state_change: bChargerChanged = 0 max_vbus = 9000
battmngr_plat_scpqchg_qbg_r1_get_battery_status: usb_charge_now=1, …
battmngr_tech_scpq_chg_r1_get_chg_cable_state: USB charger cable is connected
battmngr_plat_scpqchg_qbg_r1_check_state_change: USB charger connected
battmngr_plat_scpqchg_qbg_r1_check_state_change: Charging source is 2
```

### Charger SM trajectory

- 12.5499: `event_type=10, curr=0→1→2` (initial-detection burst; holds 2)
- 14.5921: BattMngr **Run level 3**
- 20.7349: first `curr=4` (`event_type=20` periodic) — the 2→4 transition line
  itself was lost to the 8 KB ring wrap (boot-time logging load)
- 20.7–43 s: periodic `event_type=20, curr=4, next=4`; one recurring heartbeat
  `event_type=24, curr=4, next=4` at 43.007
- steady state: `scp_inov_db - curr_sub_state=0, fcc_ma=5700, icl_ma=2440, vin_mv=9000`
  (ICL vote 2440 mA at 9 V)
- **zero `ncp_stby` / `icm_ncp_stby` lines anywhere in the 40 s capture**

(Event numbers 10/20/24 are inferred from context: 10 = initial-detection
burst, 20 = periodic, 24 = recurring heartbeat — the same 24 is observed at
state 4 here and at state 2 in dbg49.)

## The failing-side reference (dbg49, `linux usb` pre-plug, initramfs)

From [`logs/dbg49-adsp-icm-ncp-stby.txt`](../logs/dbg49-adsp-icm-ncp-stby.txt)
(dbg49 image ULog; PDR 3.498103 s, immediately behind ABL's USB host session):

```
33.215584 ncp_stby_db_log: ncp_stby_db - chgr_stat=7, soc=6599
33.215588 Warn: icm_ncp_stby_main: keeps in icm_ncp_stby untill charger_type updated
33.215592 sm_state_loop: charger state: event_type=24, curr=2, next=2, status=0x0
…
52.736372 … same ncp_stby + sm_state_loop (still parked 19 s later)
```

## The diff — success vs failure

| marker | success (boot 1, full system) | failure (dbg49, initramfs) |
|---|---|---|
| initial detection result | `charger_detection_evaluate_typec_charger: Input[0] PartnerType=2, Voltage=5000 mV, Current=900 mA` in the PDR + 22 ms drain | **no PartnerType line at all** |
| charger SM | 0→1→2 at PDR + 22 ms; **reaches state 4** by PDR + 8.2 s | **stuck at state 2**: `event_type=24, curr=2, next=2` at 33.2 s and again at 52.7 s |
| ICM `ncp_stby` | **absent** | `ncp_stby_db - chgr_stat=7` + "keeps in icm_ncp_stby untill charger_type updated" |
| ActivePort partner | PartnerType=15 @ 9000 mV / 2440 mA (PD contract, PDR + 2.06 s) | never |
| `usb_type` (AP view) | `SDP` at PDR + 294 ms (poller) | `[Unknown]` for minutes (dbg1400: to t ≈ 366 s) |
| PDR | 12.5280 s (this boot; 11.0248 s in the 13:09 boot — ADSP start drifts ~1.5 s boot-to-boot) | 3.4981 s |

**Reading.** Both environments get the `charger_pd` PDR. In the success
environment the PPM runs initial detection at its boot, sees the partner
(5 V / 900 mA), the charger SM walks 2→4, the ICM is never parked in
`ncp_stby`, and the AP sees `SDP` 294 ms after the PDR. In the failing
environment the PPM **never produces a charger-type update**: the ICM sits in
`ncp_stby` "untill charger_type updated" and that update never arrives. The
discriminator is a PPM-internal fork at initial detection; boot 2 (lever B in
the initramfs) will show which side of it the initramfs PPM is on — detection
runs and returns nothing (points at D, the `apsd-rerun-cfg` byte), or never
runs (points at the staged-start, lever A).

## Caveats

- **Drain semantics**: 1 s poll, 8 KB ring. Lines can be lost under boot-time
  load (the 2→4 transition was); the state value *at each drain* is reliable,
  transition lines are not guaranteed.
- **First-drain window**: everything between ADSP boot and the first GET is in
  drain 1 unless the ring wrapped; the PPM's own boot sequence before
  detection is mostly not in it.
- **Boot-to-boot drift**: ADSP power-up at 10.978 s (13:09 boot) vs 12.012 s
  (15:39 boot). The *offsets* (PDR = ADSP-up + 42.7 ms; SDP = PDR + 294 ms;
  first drain = PDR + 21.9 ms) are the stable quantities.
- **Phase order is boot-dependent**: this boot had no 9.083 V first sample and
  no 6 mV VBUS collapse — the first poller sample was already 5.226 V
  ([USB_TYPE_TIMING.md](USB_TYPE_TIMING.md) caveat confirmed).
- **Never `rmmod`** the module in a live session (channel teardown, see above).

## References

- the `usb_type` data path and the two orderings behind the full-system
  success: [../diagrams/usb-type.md](../diagrams/usb-type.md)
- stock module source: `drivers/soc/qcom/pmic_pdcharger_ulog.c` (kernel 7.2.6)
- raw captures: [`logs/full-system/adsp-ulog-20261108-1539.log`](../logs/full-system/adsp-ulog-20261108-1539.log),
  [`logs/full-system/usb-type-poller-20261108-1539.log`](../logs/full-system/usb-type-poller-20261108-1539.log)
- failing-side reference: [`logs/dbg49-adsp-icm-ncp-stby.txt`](../logs/dbg49-adsp-icm-ncp-stby.txt)
- lever B and the decision rule: [INITRAMFS_CHANGES.md](INITRAMFS_CHANGES.md)
- AP-side classification timing: [USB_TYPE_TIMING.md](USB_TYPE_TIMING.md)
