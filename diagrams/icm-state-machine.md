# ICM charger state machine (the wedge)

ICM is the charger power-path state machine inside the PPM firmware
(`adsp.mbn`, Hexagon). Context object: `icm_ctx @0x603390ec`; the current
state lives at `icm_ctx->+0xc`. The ICM core is initialized at `0x6019fe90`:
it registers 12 state modules and resolves its config subtree
`ChgIcmCfg` (config key lookup `0x60084be0("ChgIcmCfg", 0, &h, 3)` →
handles @0x603391e8/ea).

## States

```
  boot
    │  icm_core_init @0x6019fe90
    ▼
 ┌───────────────────────────┐
 │ pre_chg     (state = 1)   │   pre_chg_init @0x601a0740
 │  gate: icm_ctx->+0xc == 1 │   pre_chg_main  @0x601a0ac0
 │                           │
 │  vbat = 0x60147d30(ctxA)  │
 │  threshold @0x60339200    │  ← 0x1130 (ctxA->+0x19 == 1) else 0x898
 └─────────────┬─────────────┘
   vbat ≤ threshold:
     UV/OC protection recovery:
       0x60147e20, 0x60147b70(7), 0x60147a20(0xfa),
       0x60147db0(0x1194|0x2328), timers 0x6016f3d0/440/4b0,
       0x601537d0(3, 0x64);
     log: "enter Batt UV/OC protection recovery - vbat=%d, status=%d"
   otherwise:
     chgr_stat ∈ {1,2} → 0x60147b00(5) + 0x60147be0(0)
     otherwise ─────────────────────────────┐
                                            ▼
 ┌───────────────────────────────────────────────────────────┐
 │ ncp_stby (state = 2)      ◀────────────── THE WEDGE       │
 │  reg @0x601a12c0   init @0x601a1320                       │
 │  main @0x601a1790  exit @0x601a1c30                       │
 │  gate: icm_ctx->+0xc == 2                                 │
 │  event jump table @0x60238cc0, index = event − 7 (7..0x18)│
 │                                                           │
 │  on every event, compute the "type updated" flag          │
 │  @0x60339214 from the charger type byte T                 │
 │  (T = ChgIcmCfg @0x603391b8 + 1):                         │
 │    T ∈ {2..16, 19} → flag = (ctxB->+0x20 == 0)            │
 │    T ∈ {20..23}     → flag = (ctxB->+0x1c != 0)           │
 │    otherwise (0, 24, …) → flag = 1   ← stuck             │
 │                                                           │
 │  exit ⇔ flag == 0 AND                                     │
 │         ( chgr_stat == 3                                   │
 │           OR (chgr_stat == 4 AND vbat ≤ 9800) )            │
 └──────────────────────────────┬────────────────────────────┘
                                │
                                ▼
 ┌───────────────────────────────────────────────────────────┐
 │ normal (state = 3)                                        │
 │  PPM proceeds; the USB data path is opened                │
 └───────────────────────────────────────────────────────────┘

 state = 4: error — set by the ctxA state handler @0x60148df0
 (icm_ctx->+0xc = 4) when handle bring-up 0x6016f0f0 fails
```

Event screening (which inputs each state sees): `icm_core_event_screening`
@0x601a00e0 (jump table @0x60238910, index = event − 2, 2..0x19). The event
base byte is `icm_ctx->+0x0` (each consumer subtracts its own offset:
screening −2, ncp_stby −7).

## Where the exit inputs come from

| Input | Source |
|---|---|
| `T` (charger type) | `ChgIcmCfg` byte +1 @0x603391b8+1 — written only when charger detection classified the port; the full chain is in [charger-type-chain.md](charger-type-chain.md) |
| `chgr_stat` | `(property 0x2606) & 7` — getter chain `0x601479b0` → `ctxA->+0x4c` = `0x601486d0` → `0x60169a00(ctxA, 0x2606, &out)` (property get/subscribe) |
| `vbat` | ctxA voltage getter `0x60147d30` (guarded by `ctxA->+0x24 != 0` in `0x60147e90`) |
| `ctxB->+0x1c/+0x20` | data words of the ctxB object @\*0x60338c40, read by ICM queries `0x6016d350`/`0x6016d2f0` |

## Why it wedges in the failing environment

- `T` is updated only when charger detection runs. Detection is
  **event-driven**: fresh CC edge → HW IRQ → bitmask dispatcher
  `0x601535a0` → `charger_detection_event_handler` @0x6014eab0
  (see [charger-type-chain.md](charger-type-chain.md)).
- Stick pre-plugged before PPM starts (~3.4 s after kernel boot): there is
  no CC edge after PPM starts, detection never classifies, `T` keeps its
  initial value. The only direct write to the type region found in the
  disassembly is the init at `0x6019ffe4`:
  `memh(##0x603391b8) = (hw & 0xfff0) | 4` — it preserves the type byte
  (BSS: 0).
- `T = 0` falls into the "otherwise" branch → flag @0x60339214 = 1 on
  every event → the exit condition is never satisfied → the USB data path
  is never opened (CCS=0 on xHCI, `New USB device` never printed).
- The firmware logs the stuck state (ULog, level 1/Warn; message
  @0x60238da2, log site @0x601a1aac):

  ```
  icm_ncp_stby_main: keeps in icm_ncp_stby until charger type updated
  sm_state_loop: charger state: event_type=24, curr=2, next=2, status=0x0
  mcp_stby_db_log: chgr_stat=7
  ```

  `event_type=24` is the periodic tick event (bit 0x18 of the HW-IRQ
  bitmask dispatcher), **not** the type byte. `chgr_stat=7` = no charger.

## Evidence

- Function excerpts with the state gate, jump table, flag logic and log
  site: [../logs/adsp-re/func-icm-ncp-stby-main.txt](../logs/adsp-re/func-icm-ncp-stby-main.txt)
- Wedge fingerprint on device: [../logs/dbg49-adsp-icm-ncp-stby.txt](../logs/dbg49-adsp-icm-ncp-stby.txt)
- Firmware RE with all vaddrs: [../docs/ADSP_RE.md](../docs/ADSP_RE.md)
