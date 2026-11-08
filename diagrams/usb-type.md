# `usb_type`: where it is born, where it is read, and why it is `SDP` in the full system

Answers two questions in one picture: **what `usb_type` actually is** (a data
path, not a switch) and **what makes USB enumerate in the full system** (two
orderings that the full system has and `linux usb` breaks).

## 1. What `usb_type` is

A sysfs attribute on the **AP**:

```
/sys/class/power_supply/qcom-battmgr-usb/usb_type
```

- Created by `qcom_battmgr` (`drivers/power/supply/qcom_battmgr.c`), bound to
  the auxiliary device `pmic_glink.power-supply`.
- Allowed values (the `.usb_types` mask): `Unknown | SDP | DCP | CDP | ACA |
  C | PD | PD_DRP | PD_PPS | BrickID`.
- **It is a read-only mirror, not a switch.** Reading it makes the AP send
  `BATTMGR_USB_PROPERTY_GET (0x32)` / property `USB_ADAP_TYPE` to the PPM's
  battmgr (owner `32778`) over the pmic_glink channel and return the PPM's
  answer (`qcom_battmgr_usb_sm8350_update` → `battmgr->usb.usb_type = resp`).
  The AP never *writes* the value — it can only query what the **PPM has
  detected**. There is no AP command that sets `usb_type`.

## 2. Data path (PPM → AP)

```
PPM (ADSP) — the only writer of the value
  CC1/CC2 + APSD (PM8550B hardware)
       │  charger detection
       ▼
  charger_detection_evaluate_typec_charger
     → partner type:  PartnerType=2  → 5 V / 900 mA   (BC1.2 / USB)
                      PartnerType=15 → 9 V / 2440 mA  (PD contract)
       │
       ▼
  charger SM (sm_state_loop 0→1→2→4)  +  ICM (ncp_stby gate)
       │
       ▼
  battmgr glink client (owner 32778)
       │   pmic_glink "power-supply" channel (glink RPC)
       │     AP asks:  BATTMGR_USB_PROPERTY_GET / USB_ADAP_TYPE
       │     PPM answers: the detected type
       ▼
AP — passive mirror
  qcom_battmgr  (auxiliary: pmic_glink.power-supply)
     → battmgr->usb.usb_type = resp
     → power supply "qcom-battmgr-usb"
     → /sys/class/power_supply/qcom-battmgr-usb/usb_type
            ▲ read by: usb-type-poller (50 ms), udev, userspace
```

**The writer of the value is the PPM's charger detection.** Everything on the
AP is a query-and-echo. This is why "add a command to init that sets
`usb_type`" is not available — see
[../docs/INITRAMFS_CHANGES.md](../docs/INITRAMFS_CHANGES.md#why-add-a-command-to-init-is-not-available).

## 3. When the PPM (re)writes the value — three trigger paths

| # | trigger | what happens | status in the working pre-plug env |
|---|---|---|---|
| **1** | **initial detection at PPM boot** | PPM boots, runs `charger_detection_evaluate_typec_charger` once against the *current* CC state, writes the partner type | **the one that fires** — `usb_type = SDP` at PDR + 55 ms |
| **2** | fresh CC edge (replug / late plug) | HW IRQ → charger_detection re-evaluates | not needed (drive is pre-plugged ⇒ no fresh edge) |
| **3** | `SetRerunApsd` rerun (AP pmic_glink → `dpm_usbc`) | AP asks the PPM to re-run detection | **gated off** by `apsd-rerun-cfg = 0` (no-op in every env) |

Only path **#1** can explain the working *pre-plug* case: there is no fresh CC
edge and #3 is disabled. So the whole question reduces to: *does the PPM's
one-shot initial detection succeed?*

## 4. Full-system timeline — why it works (measured, 2026-11-08 15:39)

Two orderings line up:

```
t=0        drive PRE-PLUGGED — VBUS/CC already present on the port at power-on
t~0–8 s    ABL normal boot — NO dr_mode=host overlay → DWC3 stays OTG
           → NO early host scan
           (contrast: `linux usb` adds dr_mode=host → first host scan at
            ~2.7 s, BEFORE the PDR)
t=12.012   powering up adsp            ← PPM starts LATE, after the port settled
t=12.4853  adsp is now up
t=12.5280  PDR: charger_pd             (ADSP-up + 42.7 ms)
t=12.5499  PPM initial detection: PartnerType=2, 5 V / 900 mA
           ← this is where usb_type gets its value
t=12.58    usb_type = [Unknown], online=0 (poller), VBUS already 5.2 V
t=12.82    usb_type = SDP              (PDR + 294 ms, online=1)
t=13.01    PD contract (opmode=usb_power_delivery)
t=15.72    role flips to HOST          (only AFTER the PDR)
t=15.956   xHCI host controller CREATED (gadget → host)
t=15.956   FIRST host scan → drive enumerates
t=17.920   [sdg] Attached SCSI disk
```

**What makes it work** — two conditions, both about order:

1. **The PPM boots *late and clean*** (≈ 12 s), so its one-shot initial
   detection sees the *settled* pre-plugged port and classifies it (SDP, VBUS
   on). If it had come up early behind a USB host session, the detection
   produces nothing (see §5).
2. **The controller stays *OTG* until the role flips *after* the PDR**, so the
   **first host scan lands *after* classification + VBUS** — not before. The
   scan has a live, powered, classified port to talk to.

The full system has the right order naturally; no AP actor is involved in the
classification itself.

## 5. Failing initramfs (`linux usb`) timeline — why it breaks

```
t~2.7 s    ABL (linux usb) adds dr_mode=host → EARLY host scan, BEFORE the PDR
t=3.4981   PDR: charger_pd    ← PPM starts EARLY, right behind ABL's USB host session
t~3.5 s+   PPM initial detection produces NO charger-type update
           → ICM parks in ncp_stby:
             "keeps in icm_ncp_stby untill charger_type updated"
             sm_state_loop stuck at curr=2 (event_type=24), chgr_stat=7
t=…        usb_type stays [Unknown], online=0, no VBUS, no PD, no role flip
           → the early host scan was absorbed (CCS=0); nothing re-arms the port
           → the drive never enumerates (for minutes; dbg1400 to t≈366 s)
```

**What breaks** — the same two orderings, wrong at once:

1. The PPM comes up **early** (right behind ABL's USB host session), and its
   one-shot initial detection does **not** produce a charger-type update (ICM
   wedged in `ncp_stby`, no `PartnerType` line).
2. The host scan **already happened before the PDR**, so even a late
   classification would not re-trigger it — there is no fresh CC edge and
   `SetRerunApsd` is gated off.

## 6. So: what makes USB work in the full system?

- **The PPM's one-shot initial detection at its boot is the only thing that
  sets `usb_type`** in the pre-plug case (no AP command, no fresh edge).
- It **succeeds** in the full system because the PPM starts **late and clean**
  and sees the settled port.
- It is then **usable** because the controller stays **OTG** until the role
  flips **after the PDR**, so the first host scan lands **after**
  classification + VBUS.

Therefore the `linux usb` fix must restore those two orderings:

| ordering | how to restore it in the initramfs |
|---|---|
| first host scan *after* the PDR | **already done** — kernel patch 1400 demotes `dr_mode=host` → OTG (PR #704) |
| PPM initial detection *succeeds* | **open** — lever **A** (stage the ADSP start late/clean) or lever **D** (`apsd-rerun-cfg` 0→1, the AP re-trigger) |

## Cross-references

- Measured AP-side classification timing: [../docs/USB_TYPE_TIMING.md](../docs/USB_TYPE_TIMING.md)
- PPM's own log — boot-1 success fingerprint: [../docs/ADSP_ULOG.md](../docs/ADSP_ULOG.md)
- The ICM wedge (`ncp_stby`) in detail: [icm-state-machine.md](icm-state-machine.md)
- Charger-type chain and property layer: [charger-type-chain.md](charger-type-chain.md)
- AP-side fix candidates (A/B/C/D): [../docs/INITRAMFS_CHANGES.md](../docs/INITRAMFS_CHANGES.md)
- Where the whole chain sits in the system: [architecture.md](architecture.md)
