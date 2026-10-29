# Charger type chain: PMIC hardware → ADSP → ICM exit

Everything the ICM exit flag (see [icm-state-machine.md](icm-state-machine.md))
depends on, where it comes from, and the levers on this chain.

## Plug event flow (inside ADSP)

```
PM8550B hardware
  CC1/CC2 (BC1.2 detection) + APSD
  (Automatic Power Supply Detection block)
      │  HW IRQ (firmware-internal)
      ▼
event bitmask dispatcher @0x601535a0     (HW-IRQ entry 0x601534c0)
  bit 2    → charger_detection_event_handler @0x6014eab0
  bit 3    → same handler + 0x600657c0(4)
  bit 0x18 → 0x60168890(1)        ← "event_type=24" of the wedge log
      │
      ▼
charger_detection_event_handler
  (inputs 0..min(count, 3); input count @0x60334b58)
  per input:
    "get otg sts" (string @0x6022ba00)
    → evaluate @0x60156860
        (per-input type table @0x60256ef0, stride 0x14;
         type 2 → 0x60166f80, type 3 → 0x6015b3b0)
    → bPlugIn state @0x60334b5c + 0x14*input
  on change:  log "Input[%d] bPlugIn=%d" (@0x6022bbae)
    → plug_in @0x6014f3d0 / plug_out @0x6014f7e0
    → notify @0x6016e3a0 → ctxB->+0xc0 (method 0x6016c070):
        if ctxB->+0x15 == 1: get property 0x270b → post events
        0x7e42 / 0x7ee5 (event post 0x6016a4c0)
      │
      ▼
state the ICM reads:
  ChgIcmCfg @0x603391b8:
    halfword +0x0  — low nibble = 4 (input count);
                     init = (hw & 0xfff0) | 4   (0x6019ffe4)
    byte     +0x1  — charger type T   ← what the wedge waits for
    word     +0x14 — changed flag (written by event screening)
    words    +0x20, +0x24 — data (ICM reads via 0x6016d350 / 0x6016d550)
  property 0x2606 (charger status):
    chgr_stat = prop & 7
    (getter chain: 0x601479b0 → ctxA->+0x4c = 0x601486d0
     → 0x60169a00(ctxA, 0x2606, &out))
      │
      ▼
ICM ncp_stby:  flag(T, ctxB) + chgr_stat + vbat → exit
      │
      ▼
PPM opens the USB data path → D+/D- → snps eUSB2 HS PHY → xHCI
```

## Who writes the type byte (open question)

| Site | What it does | Status |
|---|---|---|
| init `0x6019ffe4` | `memh(##0x603391b8) = (hw & 0xfff0) \| 4` | the only direct write found; the type byte itself is preserved |
| clone `0x601bebc0` | copies byte0 + byte1 + +0x8 from a template | called only from `ufcs_init` @0x601be4b0 (per-input slots 0x603396a0 + n·0x1b8) — dead end |
| APSD result path (candidate) | `battmngr_tech_scpq_chg_r1_get_usb_port_detection` → `PmSchgUsb_GetApsdStatus` / `PmSchgUsb_GetApsdResultStatus` (pm_usb.c); log `apsd_result = %d`; also `PmicTccPlatform_Schg_PDPhy_R1_HW_GetLegacyCableStatus (… apsd_result=%d)` | the mechanism exists in the code; the write of the type byte / property 0x2606 is not yet located |

If nothing writes `T`, it stays 0 → "otherwise" branch → flag = 1 forever.
Same wedge.

## Levers on this chain

| # | Lever | Where | State |
|---|---|---|---|
| 1 | fresh CC edge (replug / late plug) | hardware | works ≤ ~24.7 s after power-on, fails ≥ ~38 s |
| 2 | USB-resume → APSD rerun | ADSP: dpm_usbc resume @0x600d1dc0 → 0x600d25e4 → `PmSchgUsb_SetRerunApsd` @0x600978e0; failure log "APSD rerun failed during resume" (dpm_usbc.c) | path present in code; whether the failing environment ever triggers a resume is unmeasured |
| 3 | `apsd-rerun-cfg` 0→1 (dbg52 candidate) | `adsp_dtb.mbn` FDT: property record @MBN+0x980 (name via string-table offset 0x52f → "apsd-rerun-cfg"), value word @0x988 = 0x00000000; patch byte @0x98b + sha384 slot @12624 (49 bytes total) | recipe byte-verified by trial patch (TZ accepted the recomputed hash); not yet tested on device |
| 4 | ICM initial-detection status | ADSP: `charger_detection_inital_detection` @0x60152970 reads "adsp rerun status" (getter 0x6009dca0; second status 0x6009d9b0); log "charger_detection_inital_detection: adsp rerun status=0x%X" | needs a device run with ADSP ulog |

## Config key facts (adsp.mbn side)

- The code references config **subtrees** by key name. Key table
  `0x601d7c47..0x601d7d68`: `ADC_BSP`, `BattmngrBSP`, `ChargerTempCfg`,
  `BatteryErrorCfg`, `ChargeTableCfg`, `ChargerLedCfg`,
  `BatteryAuthenticationCfg`, `MaintenanceChgCfg`, `QbgCfg`,
  `ThermThresholdCfg`, `UcsiCapCfg`, `UcsiConnectorCapCfg`, `LpmCfg`,
  `PDPoliciesCfg`, `PDStaticInfo`, `WirelessCfg`,
  **`ChgDetCfg` @0x601d7d28, `ChgIcmCfg` @0x601d7d32**, `IDTCfg`,
  `VDMStaticInfo`, `TcpcCfg`, `LPDCfg`, `UFCSCfg`, `BhargerCfg`
  (+ test names `test_Name1..4`).
- The code contains **no FDT property name strings** —
  `apsd-rerun-cfg`, `chg-heartbeat-timer-ms`, `en-apsd-pwr`, … all absent
  from `adsp.mbn`. Properties are therefore matched by index/order (or by
  hash), not by name. An in-place value patch (lever 3) is safe under both
  interpretations: structure and order are unchanged.
- FDT struct section (`adsp_dtb.mbn`, payload @MBN+0xd0, 8315 B): custom
  layout — **node names are inline** (e.g. `chg_icm_cfg` @0x9b0) while
  **property names come from the string table** (@0x1610). Observed
  16-byte property record: `[0x00000004][name_off][value (4 B)][0x00000003]`:
  `dam-hc-override` (value 0) @0x970, `apsd-rerun-cfg` (value 0) @0x980,
  `bm-hw-poff-ctrl` (value 3) @0x990.

## Object map (vaddrs)

| Object | Address | Size | Key fields |
|---|---|---|---|
| `icm_ctx` | 0x603390ec | — | +0x0 event base; +0xc state (1/2/3/4); +0x10 → state-obj 0x60339110; +0x14 → screening fn 0x601a00e0; +0x1c → ChgIcmCfg 0x603391b8 |
| `ChgIcmCfg` | 0x603391b8 | 440 B | +0x0 count nibble; **+0x1 type T**; +0x14 changed; +0x20, +0x24 data |
| `ctxA` (heap) | \*0x60334ab8 | 0x7c | +0x0 obj-type=7; +0x1 (prop 0x105: 0x32/0x47); +0x15 (prop 0x103); +0x19 threshold select; +0x24 enable; **+0x4c = chgr_stat fn 0x601486d0** |
| `ctxB` (heap) | \*0x60338c40 | 0x108 | +0x1, +0x15 (==1 → property 0x270b path); +0x1c/+0x20/+0x34 data words (ICM queries 0x6016d2f0/0x6016d350/0x6016d550); **+0xc0 = notify method 0x6016c070**; +0xc4 = 0x6016c120 |
| ICM globals | 0x603391e8…0x60339214 | — | 0x603391e8/ea config handles; 0x60339200 threshold (0x898/0x1130); 0x60339204 UV/OC flag; 0x60339208 obj->+0x20 copy; **0x60339214 type-updated flag** |
| charger_detection | 0x60334bac…0x60334be0 | — | 0x60334b58 input count; 0x60334b5c+0x14·in bPlugIn; 0x60334bb0…0xbc UFCS config/handles; 0x60334be0 registered callback |
| per-input type table | 0x60256ef0 | stride 0x14 | evaluate selector (2/3/other) |
| property system | — | — | get/subscribe `0x60169a00(obj, id, &out)`; set `0x6016a150`; event post `0x6016a4c0` |

## Function map (vaddrs)

| Function | Address |
|---|---|
| ICM core init | 0x6019fe90 |
| ICM event screening | 0x601a00e0 (JT @0x60238910) |
| pre_chg init / main | 0x601a0740 / 0x601a0ac0 |
| ncp_stby reg / init / main / exit | 0x601a12c0 / 0x601a1320 / 0x601a1790 / 0x601a1c30 |
| charger_detection init | 0x6014e590 |
| charger_detection event_handler | 0x6014eab0 |
| evaluate | 0x60156860 |
| plug_in / plug_out | 0x6014f3d0 / 0x6014f7e0 |
| initial_detection | 0x60152970 |
| bitmask dispatcher | 0x601535a0 (entry 0x601534c0) |
| notify → ctxB callback | 0x6016e3a0 |
| ctxB notify method | 0x6016c070 |
| ctxA init / ctor / chgr_stat | 0x60148150 / 0x601482b0 / 0x601486d0 |
| chgr_stat wrapper | 0x601479b0 |
| vbat getter | 0x60147d30 |
| "adsp rerun status" getter | 0x6009dca0 (second status 0x6009d9b0) |
| `PmSchgUsb_SetRerunApsd` (pm_usb.c) | 0x600978e0 |
| dpm_usbc resume | 0x600d1dc0 (→ 0x600d25e4) |
| config key lookup | 0x60084be0 |

## Cross-references

- The wedge state in detail: [icm-state-machine.md](icm-state-machine.md)
- Where the whole chain sits in the system: [architecture.md](architecture.md)
- ADSP RE with evidence excerpts: [../docs/ADSP_RE.md](../docs/ADSP_RE.md)
- PPM config values and the 1-byte patch recipe: [../docs/ADSP_CONFIG.md](../docs/ADSP_CONFIG.md)
