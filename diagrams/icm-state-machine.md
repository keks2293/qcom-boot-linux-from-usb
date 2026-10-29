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
  ┌────────────────────────────────────────────────────────────────────────────┐
  │ ncp_stby (state = 2)        ◀────────────── THE WEDGE                      │
  │ reg @0x601a12c0   init @0x601a1320 (icm_ncp_stby_init)                     │
  │ main @0x601a1790  exit @0x601a1c30                                         │
  │ gate: icm_ctx->+0xc == 2                                                   │
  │ event jump table @0x60238cc0, index = event − 7 (7..0x18)                  │
  │                                                                            │
  │ T = *(*(0x60339210) + 1)   (global pointer, written once in the            │
  │      constructor 0x601a12c0 ← ICM init 0x6019fe90)                         │
  │                                                                            │
  │ icm_ncp_stby_init (per event while state == 2):                            │
  │   chgr_stat switch:                                                        │
  │     3 → icm->+0xc = 3 (normal)                                             │
  │     4 → vbat getter 0x60147e90; vbat ≤ 0x2647 (9799 mV) → icm->+0xc = 3    │
  │     5 → mask accumulator 0x6016e2d0(ctx, 8, 0)                             │
  │     7 → 0x6016e2d0(ctx, 3, 0x1388) + 0x6016d930(ctx, 0x1004)               │
  │         (0x1388 = 5000 mV, 0x1004 = 4100 mV)                               │
  │   then, only if icm->+0xc == 2, recompute flag @0x60339214:                │
  │     T ∈ {21,22,23} → flag = !(GET(0x270b) & 0x10)   (PD types)             │
  │     T ∈ {2..16,19} → flag = !(GET(0x270b) & 0x20)   (USB types)            │
  │     T ∈ {0,1,17,18,20} or T > 23 →                                         │
  │         flag = 1 + ULog warn + icm->+0xc = 2        ← STUCK                │
  │   flag = 0 → 0x60339214 = 0                                                │
  │                                                                            │
  │ exit ⇔ flag == 0 AND                                                       │
  │        ( chgr_stat == 3                                                    │
  │          OR (chgr_stat == 4 AND vbat ≤ 9799) )                             │
  └─────────────────────────────┬──────────────────────────────────────────────┘
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
| `T` (charger type) | `*(*(0x60339210) + 1)` — global pointer written **once** in the constructor @0x601a12c0; the byte itself (ChgIcmCfg @0x603391b8+1) is **static boot config**: zero runtime writes in the whole disassembly (only init @0x6019ffe4, which preserves it) |
| `chgr_stat` | `(property 0x2606) & 7` — getter chain `0x601479b0` → `ctxA->+0x4c` = `0x601486d0` → `0x60169a00(ctxA, 0x2606, &out)`; property 0x2606 is **PMIC-backed and read-only** in the ADSP code |
| `vbat` | ctxA voltage getter `0x60147d30` (guarded by `ctxA->+0x24 != 0` in `0x60147e90`) |
| `GET(0x270b)` bit checks | ctxB methods `0x6016aad0` (+0x1c, `& 0x10`), `0x6016ab40` (+0x20, `& 0x20`), `0x6016abb0` (+0x24, `& 0x80`); each is `rc = 0x60169a00(ctxB, 0x270b, &out); rc == 0 ? (out & BIT) : 0` reached through the indirections `0x6016d2f0`/`0x6016d350` (`callr ctxB->+0x1c/+0x20`). The 0x270b value lives in the **central property service** (RPC, see [charger-type-chain.md](charger-type-chain.md)) |

## Why it wedges in the failing environment

- `T` is **static boot config**: the only write to the type region in the
  whole disassembly is the init at `0x6019ffe4`:
  `memh(##0x603391b8) = (hw & 0xfff0) | 4` — it preserves the type byte
  (BSS: 0). With `T = 0` the "otherwise" branch fires: **flag = 1 on every
  event, unconditionally** — no property value can save it.
- Even for a valid `T`, the flag depends on **property 0x270b**
  (`flag = !(0x270b & 0x20)` for USB types). That value is held/computed in
  the **central property service** (RPC channel, callback-push model — see
  [charger-type-chain.md](charger-type-chain.md)); the ADSP never sets it
  with a visible id (all six visible 0x270b references are GETs). The value
  changes only when the service **pushes a charger-type update** — triggered
  by AP-side USB/charger activity. In the failing environment (initramfs
  cold-plug) that push never arrives → flag stays 1.
- Either way the exit condition is never satisfied → the USB data path is
  never opened (CCS=0 on xHCI, `New USB device` never printed).
- The firmware logs the stuck state (ULog, level 1/Warn). Two variants of
  the same warn exist in the firmware — the typo "utill" is verbatim theirs:

  ```
  Warn: %s: icm_ncp_stby_init: keeps in icm_ncp_stby utill charger_type updated   (fmt @0x60238d14)
  Warn: %s: icm_ncp_stby_main: keeps in icm_ncp_stby utill charger_type updated   (fmt @0x60238da2)
  ```

  Device fingerprint (diag screen):

  ```
  keeps in icm_ncp_stby until charger type updated
  sm_state_loop: charger state: event_type=24, curr=2, next=2, status=0x0
  chgr_stat=7
  ```

  `event_type=24` is the periodic tick event (bit 0x18 of the HW-IRQ
  bitmask dispatcher), **not** the type byte. `chgr_stat=7` = no charger.

## Evidence

- Function excerpts with the state gate, jump table, log site:
  [../logs/adsp-re/func-icm-ncp-stby-main.txt](../logs/adsp-re/func-icm-ncp-stby-main.txt)
- `icm_ncp_stby_init` — the full flag logic (chgr_stat switch, 0x270b bit
  checks, the wedge warn, the flag write):
  [../logs/adsp-re/func-icm-ncp-stby-init-601a1320.txt](../logs/adsp-re/func-icm-ncp-stby-init-601a1320.txt)
- ctxB object creation (boot one-shot factory chain):
  [../logs/adsp-re/func-ctxb-factory-6016e800.txt](../logs/adsp-re/func-ctxb-factory-6016e800.txt)
- Wedge fingerprint on device: [../logs/dbg49-adsp-icm-ncp-stby.txt](../logs/dbg49-adsp-icm-ncp-stby.txt)
- Firmware RE with all vaddrs: [../docs/ADSP_RE.md](../docs/ADSP_RE.md)
