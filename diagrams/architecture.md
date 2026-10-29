# System architecture: what is where

The whole system in one picture, then each layer in detail. Every element is
cross-referenced to the doc/evidence that proves it.

## Big picture

```
┌──────────────────────── AP (QCS8550, AArch64) ───────────────────────────────┐
│                                                                              │
│  boot: XBL (closed DXE; finds + reads the USB stick)                         │
│        → ABL (LinuxLoader) → Linux v7.2.6 (USB data path: all builtin)       │
│                                                                              │
│  userspace:   initramfs (dracut)              full system (armada rootfs)    │
│               "linux usb" boot mode           normal boot                    │
│               └─ no actor touches typec/ucsi/glink (4-zone static hunt)      │
│                                                                              │
│  kernel drivers (all =y unless noted):                                        │
│   USB data:  a600000.usb (dwc3 glue) → xhci-hcd.0.auto → usb1/usb2 hubs      │
│              dwc3-qcom, snps eUSB2 HS PHY (+ PM8550B repeater)               │
│   USB-C:     ucsi + ucsi_glink (UCSI-over-glink client)                      │
│              qcom_pmic_tcpm (=y), usb-role-switch (never registered on RP6)  │
│   ADSP link: pmic_glink (glink host), qcom_q6v5_pas (=m, starts ADSP)        │
│              qcom_battmgr (=m; auto-loaded in initramfs via modalias)         │
│   firmware files (initramfs, passive pack, dracut module armada-adsp):        │
│              /usr/lib/firmware/qcom/sm8550/retroidpocket/rp6/                │
│                 adsp.mbn (code) + adsp_dtb.mbn (PPM config FDT)              │
└──────────────────────────────┬───────────────────────────────────────────────┘
                               │ glink channel (pmic_glink / rpmsg;
                               │ services: charger_pdr, msm/adsp/charger_pd)
   AP → ADSP: UCSI commands (RESET, GET_CAPABILITY, SET_PDR, SET_UOR,
              CONNECTOR_RESET…), BATT notifications (qcom_battmgr,
              BATTMGR_REQUEST_NOTIFICATION), ULOG config (type-0x19)
   ADSP → AP: UCSI responses + connector/BC status, ulog ring
              (pmic_pdcharger_ulog = ADSP log messages readable by AP)
┌──────────────────────────────┴───────────────────────────────────────────────┐
│                  ADSP (Hexagon) — PPM firmware                               │
│   code:   adsp.mbn (28.5 MB, ELF 32-bit LE, machine 0xa4, no shdrs)          │
│   config: adsp_dtb.mbn → FDT payload (8315 B @MBN+208, 216 properties)       │
│            chg_det_cfg:    apsd-rerun-cfg = 0   ← the 1-byte patch lever     │
│            ucsi_cap_cfg:   attributes = 0x4046 (BC1.2+PD3.0+TypeC+UsesVBUS)  │
│            tcpc_cfg:       en-snk = 1 / en-src = 0                           │
│            platform_cfg:   chg-heartbeat = 30 s, poll = 40 s                 │
│                                                                              │
│   BattMngr_init @0x6002ad50 (ADSP boot: ULog init, mask 0x3FFFFFFF, lvl 3)   │
│    ├─ ICM state machine: icm_ncp_stby_main @0x601a1790  ◀── THE WEDGE        │
│    │   (event dispatcher; gate field_c==2; waits for charger_type update)    │
│    ├─ charger-detection SM: initial_detection @0x60152970, Dispatcher A      │
│    │   @0x6014eab0, vtable @0x60280540 (event-driven, not free-running)      │
│    ├─ event 0x25 broadcast bus: EMIT @0x60083f60 — 4 HW-IRQ call sites       │
│    │   (scp_qchg/QBG_R1, unnamed, Schg PDPhy R1, smb139x) + 9 subscribers    │
│    ├─ glink RX entry: pmic_glink_rx_intent_req @0x60088cd0 — UNCONDITIONAL   │
│    │   (→ QDI 0x601343e0); ULOG processor @0x600872f0 (AP sets mask/level)   │
│    ├─ TCPC/PDPhy HW arming: PmicTccPlatform_Init @0x6010ac50                 │
│    ├─ APSD re-run: SetRerunApsd @0x600978e0 + virtual @0x6015b6a0            │
│    │   (full mechanism present; config-disabled by apsd-rerun-cfg=0)         │
│    └─ ULog: globals 0x60256f78/7c (mask), 0x60256f80 (level),                │
│        0x6024a660 (counter), 0x6024a668 (default mask) — logging controls    │
│        only; every investigated "gate" is a log gate (H1 refuted)            │
└──────────────────────────────┬───────────────────────────────────────────────┘
                               │ SPMI/I²C + HW IRQs (firmware-internal)
┌──────────────────────────────┴───────────────────────────────────────────────┐
│                      hardware (PM8550B + PHYs)                               │
│   USB-C connector:  CC1/CC2 → PM8550B CC detect (BC1.2 sensing)              │
│                     SBU1/SBU2 → SBU mux (gpio-sbu-mux, usb0-sbu-mux)         │
│                     D+/D- ──→ data path (opened by PPM only after BC1.2      │
│                               classification) ──→ snps eUSB2 HS PHY          │
│                     VBUS ≈ 5.06 V with stick present (measured in wedge)     │
└──────────────────────────────────────────────────────────────────────────────┘
```

## The data path and where it is gated

```
plug stick → CC edge → PM8550B CC → HW IRQ → ADSP charger-detection SM
  → charger_type updated → ICM leaves icm_ncp_stby → PPM opens the data path
  → D+/D- reach the HS PHY → xhci RxDetect (CCS=1) → "New USB device"
```

The gate is the first hop: **classification is done entirely by ADSP + hardware;
the AP is not in the loop**. A fresh CC edge is what starts detection. In the
failing environment the stick is already in the port when PPM starts (~3.4 s
after kernel boot) — there is no edge after that, detection never starts,
`charger_type` is never updated, ICM stays in `icm_ncp_stby` and the data path
stays closed. ADSP fingerprint of the wedge (ULOG):

```
icm_ncp_stby_main: keeps in icm_ncp_stby until charger type updated
sm_state_loop: charger state: event_type=24, curr=2, next=2, status=0x0
mcp_stby_db_log: chgr_stat=7
battmgr: charger_present=0        usb_type=[Unknown] (AP side, probe-time cache)
```

The replug runs pin the window: a fresh CC edge works **≤ ~24.7 s** after
power-on and fails **≥ ~38 s** (boundary numerically matches the PPM config
`chg-heartbeat-timer-ms = 30000`; correlation, mechanism open — see
[../docs/ADSP_CONFIG.md](../docs/ADSP_CONFIG.md) and
[../docs/INVESTIGATION.md](../docs/INVESTIGATION.md)).

## What is identical in both environments (not discriminators)

| Factor | initramfs (failing) | full system (working) |
|---|---|---|
| ADSP firmware | `adsp.mbn`/`adsp_dtb.mbn` md5-verified | identical (stock == repo == all 7 public sm8550 variants) |
| ADSP bring-up | from initramfs firmware pack, ~3.4 s | from initramfs firmware pack (stock initramfs also carries it), ~3.4 s |
| userspace actors | none (static hunt, all 4 zones) | none (same hunt) |
| UCSI client | deferred (`usb-role-switch` in DTB → `-EPROBE_DEFER`, "PPM init failed, stop trying") | deferred as well (predicted: stock DTB has the property; check: `ls /sys/class/typec/`) |
| AP-side USB data path | all builtin, up since ~0.5 s | same |

## What differs (candidate discriminators, unmeasured)

| Factor | initramfs (failing) | full system (working) | Status |
|---|---|---|---|
| CC edge at the moment of interest | stick pre-plugged: no edge after PPM start | cold-plug **after** boot: fresh edge while PPM is up | the leading model; T (plug time) never measured |
| BATT client (`qcom_battmgr`) | ACTIVE (auto-loaded via modalias in every initramfs run) | likely DEAD (stale `modules.builtin` says builtin, boot kernel has `=m` → modprobe no-ops) | inverted direction — its absence in the working env makes it an unlikely trigger; check: `ls /sys/class/power_supply/` |
| what the AP sends over glink | BATT notifications + UCSI (dead) + ULOG | unknown | the ADSP side processes everything unconditionally (RE); the AP-side difference is the open measurement — see below |

Consequence: the difference between the environments is **not a userspace
actor and not the firmware** — it is either the **fresh CC edge** (HW, the
leading candidate) or **what the AP sends over glink / how the AP re-arms the
USB PHY-port chain**. Both are measurable, neither was measured.

## Where the levers are

| Lever | Where | State |
|---|---|---|
| `apsd-rerun-cfg` 0→1 (1 byte @MBN+2443 + hash slot @12624) | `adsp_dtb.mbn` (PPM config FDT) | recipe verified by trial patch; not yet tested on device (dbg52 candidate) |
| fresh CC edge (replug / late plug) | hardware | works ≤ ~24.7 s, fails ≥ ~38 s |
| UCSI SET/RESET levers | AP → glink → PPM | all measured: refused or no-op (SET → `-ECOMM`/`-ETIMEDOUT`, CONNECTOR_RESET → no-op) |
| AP PM / runtime-PM of the USB chain | AP kernel | closed (dbg51: wedge coexists with every PM state) |
| XBL/ABL handoff | boot | rejected (dbg45: XBL never touched USB in the failing boot) |

## Cross-references

- ADSP internals with vaddrs and evidence: [../docs/ADSP_RE.md](../docs/ADSP_RE.md)
- PPM config values, container layout, patch recipe: [../docs/ADSP_CONFIG.md](../docs/ADSP_CONFIG.md)
- PM chain / runtime-PM blockers: [pm-chain.md](pm-chain.md)
- Hypotheses, run table, actor hunt: [../docs/INVESTIGATION.md](../docs/INVESTIGATION.md)
- Raw evidence: [../logs/](../logs/) (initramfs runs), [../logs/adsp-re/](../logs/adsp-re/) (firmware RE)
