# ADSP firmware reverse engineering

Reverse engineering of the PPM (Platform Policy Manager) / charger-detection firmware
that lives in `adsp.mbn` on the RP6 (QCS8550). Goal: understand why the firmware waits
forever in the `icm_ncp_stby` state after a cold-plug attach, and what could re-trigger
charger-type detection.

All facts below were read from the disassembly of the stock RP6 `adsp.mbn`
(28 494 168 B, md5 `535b2f806f1e87a4a063827c81270968`) and the stock `adsp_dtb.mbn`
(16 184 B, md5 `395b86387251969f32e974d616c085be`). Raw disassembly excerpts are in
[`logs/adsp-re/`](../logs/adsp-re/); the toolchain is in
[`scripts/adsp-re/`](../scripts/adsp-re/).

## Toolchain and pipeline

The firmware is a 32-bit little-endian Hexagon ELF (machine 0xa4, 57 PHDR, **no section
headers**). A Homebrew LLVM with the Hexagon backend disassembles it directly:

```
llvm-objdump --triple=hexagon -d adsp.mbn > text_all.txt     # ~3.67M lines
```

Three gotchas of the dump:

1. `--start-address/--stop-address` are broken (the tool warns "no section overlaps"
   and emits a ~164 KB slice) — disassemble the **whole file**.
2. String references use `immext(#X)` + `##` (split-immediate), not a literal pool.
3. The disassembler resolves `##` to the full 32-bit value, so a string→code xref is a
   plain `grep '##0x<vaddr>' text_all.txt`.

Address mapping (PT_LOAD#19): file `[0xa93000:0xcd67c4]` ↔ vaddr
`[0x60000000:0x602437c4]`. So `vaddr = 0x60000000 + (fileoff − 0xa93000)`. The
`scripts/adsp-re/` tools:

- `dump_adsp.sh` — produce `text_all.txt`
- `adsp_elfmap.py` — PHDR map
- `extract_func.py <vaddr>` — cut the function enclosing a site (by `allocframe`…`deallocframe`)
- `vaddr2str.py <strings-file> <vaddr>…` — resolve a vaddr to the string at that offset

**Write-site grep gotcha:** `= ##0xADDR` matches register *loads* (`rN = ##…`), not
memory *writes*. Direct writes are `memw/memb/memh/memd(##0xADDR) = …`. A "0 direct
write sites" conclusion based on the naive pattern is an artifact.

## The wedge: `icm_ncp_stby_main`

The diag fingerprint (`icm_ncp_stby_main: keeps in icm_ncp_stby until charger type
updated`, `sm_state_loop: event_type=24 curr=2 next=2`, `chgr_stat=7`,
`charger_present=0`) corresponds to the state machine in
[`func-icm-ncp-stby-main.txt`](../logs/adsp-re/func-icm-ncp-stby-main.txt):

- `icm_ncp_stby_main` @0x601a1790 is an **event dispatcher** for the wedge state.
- Entry gate: `arg0->field_0xc == 2` — state **2 = icm_ncp_stby** (matches the diag
  `curr=2 next=2`).
- Jump table on `arg1[0] − 7` (table @0x60238cc0); valid index 0..0x11 ⇒ events 7..0x18.
  **Event 24 (0x18) is the maximum = the periodic tick** (matches the diag
  `event_type=24`).
- The WARN log "keeps in icm_ncp_stby utill charger_type updated" (typo "utill" is
  verbatim in the firmware) is emitted from **four jumptable arms**, each behind a ULog
  gate (see below). The functional state write `memb(r2+#0xc) = #0x2` runs
  unconditionally.

So the ICM state machine stays in `icm_ncp_stby` until charger-detection updates
`charger_type`. The question is what re-triggers detection.

## Detection and the trigger chain

`charger_detection_inital_detection` @0x60152970 (typo "inital" verbatim) is the
detection routine; it logs "adsp rerun status=0x%X" and "Input[%d] bPlugIn…". The call
chain is **narrow and event-driven** (one caller per level), not free-running:

```
charger_detection_inital_detection @0x60152970
  <- 0x6014e828 (fn @0x6014e590)
       <- 0x60153e60 (fn @0x60153e10)
            <- 0x60153c74 (chg-det SM)
```

See [`call-sites-trigger-map.txt`](../logs/adsp-re/call-sites-trigger-map.txt).

### The APSD-rerun levers

Two code levers can re-run port detection, both are **indirect dispatchers** (the real
logic is behind a function pointer):

- **`PmSchgUsb_SetRerunApsd` @0x600978e0** (pm_usb.c) —
  [`func-setrerun-apsd-600978e0.txt`](../logs/adsp-re/func-setrerun-apsd-600978e0.txt).
  Arg validation (`arg <= 0xa`) jumps **directly** to the functional path: fn-ptr table
  `0x603255dc + arg*0xc + 0x20`, then `callr fn(arg)`. **No runtime-flag gate on the
  functional path.** The only caller is @0x600d25e4 (`arg=7`) inside the USB
  suspend→resume function @0x600d1dc0 (dpm_usbc.c), which also logs
  "APSD rerun failed during resume".
- **"adsp rerun" virtual action @0x6015b6a0** (charger_detection.c) — reads fn-ptr
  `arg0->field_0x38` and `callr`s it (NULL → 0x202). All 9 call sites are inside the
  charger-detection state machine.

The periodic/autonomous APSD rerun
(`PmSchgMisc_SetAiclPeriodicRerun` / `SetAiclRerunTimeCfg` /
`set_hw_aicl_rerun(_timer)`) is **dead code** in this build (0 code refs).

### The `SetRerunApsd` trigger chain: pmic_glink → dpm_usbc

The single caller of `SetRerunApsd` (the `arg=7` call @0x600d25e4 inside
`dpm_usbc` @0x600d1dc0) is now fully traced **upstream** — every link is a
single caller / single data reference, no vtable indirection, so the call
graph is closed:

```
AP pmic_glink message
  → pmic_glink notification handler 0x60088eb0
      (registered as a callback by the "pmic_glink" registration fn,
       string @0x601faee3, via the generic callback-register 0x6000e784)
  → 0x60089bc0   (large handler, allocframe #0xf0; lazily allocates the
      DPM USB-C objects 0x60325100/0x603250fc)
  → dpm_usbc 0x600d1dc0   (DPM USB-C state handler; reads the state byte
      object->+4, proceeds only while state <= 3)
      [one state branch, 0x600d25c8..]:
        memb(##0x6024bec4) = 1      (a "rerun requested" flag)
        call 0x600d1890
        r0 = #0x7
        call SetRerunApsd 0x600978e0   @0x600d25e4
  → *(0x603255dc + 7*0xc) + 0x20   (per-port APSD rerun method; NULL → no-op)
  → APSD re-run → charger type re-detected → property 0x270b updated → push
  → icm_ncp_stby_init exits the wedge
```

Key facts (from the disassembly):

- `dpm_usbc` @0x600d1dc0 is a **state handler** (not a one-shot constructor):
  it reads `object->+4` and only continues while `state <= 3` (else returns
  0x203). Its **only** caller is @0x6008b56c (inside 0x60089bc0).
- `SetRerunApsd` is a **no-op when the per-port rerun method is not
  registered**: it validates `port <= 0xa`, then reads the per-port table
  `0x603255dc + port*0xc`; if the entry or its `+0x20` method is NULL it
  returns without doing anything (bail-outs @0x600979c8 / 0x600979e8).
- The per-port table `0x603255dc` (BSS) is **only read** in the disassembly
  (all references in the `PmSchgUsb`/pm_usb.c region 0x60097xxx); it is
  populated indirectly at boot. The most plausible meaning of
  `apsd-rerun-cfg = 0` (FDT, MBN+2440) is that with the config off the
  per-port rerun method is **never registered**, so `SetRerunApsd` is a
  no-op. The exact config check site is **not located** (the config keys are
  FDT-only — absent from adsp.mbn; the firmware walks the FDT at runtime) —
  a remaining ceiling.

**Consequence:** the ADSP-side actor that re-evaluates the charger type is
**named** — the DPM USB-C state handler `dpm_usbc`, driven by an AP
**pmic_glink** message and gated by `apsd-rerun-cfg`. The `apsd-rerun-cfg
0→1` patch (see [ADSP_CONFIG.md](ADSP_CONFIG.md#the-1-byte-patch-recipe-verified-by-trial-patch))
is therefore the config that **enables this concrete path**, not an anonymous
lever. What is still not decoded: (1) the exact DPM state value that reaches
the `SetRerunApsd` branch, (2) the specific pmic_glink message that drives it,
(3) whether in the failing (initramfs) environment the AP's pmic_glink
activity reaches that state at all (the BATT-load inversion,
[INVESTIGATION.md](INVESTIGATION.md), decides this — the full-system
cold-plug fork test).

### Event 0x25: the port/CC-status broadcast

Charger-detection enters via **event 0x25 (37)** = a port/CC-status broadcast. There are
**9 subscribers** registered with `call 0x60084740` (r2 = 0x25) — see
[`event-0x25-subscribers.txt`](../logs/adsp-re/event-0x25-subscribers.txt). The
registration function @0x60084740
([`func-event-bus-register-60084740.txt`](../logs/adsp-re/func-event-bus-register-60084740.txt)):

- r0 = handler, r2 = event byte (≤ 0xff), r4 = ctx, r5 = pool size (in 4-byte units,
  must be > 0xff else error 0x204); pool bytes = `r5<<2`; sentinel `0xF8F8F8F8`;
  registry globals 0x601f9e80/0x601f9e8c.

The broadcast is produced by **EMIT** @0x60083f60
([`func-emit-60083f60.txt`](../logs/adsp-re/func-emit-60083f60.txt); gate byte
0x60283a61, object global 0x60283a7c) via the helper @0x600842b0
(`fn = *(*(arg0&~1 + 4) + 0x10); callr fn(3, arg0&~1, arg1)`). There are exactly **3 EMIT
sources**, all HW IRQ setup paths:

| EMIT wrapper | source fn | context |
|---|---|---|
| @0x60083a50 | 0x6004e300 in `battmngr_plat_irq_scpqchg_qbg_r1_irq_setup` @0x6004e260 | scp_qchg/QBG_R1 IRQ |
| @0x60083a50 | 0x6005cbf0 in unnamed fn @0x6005cbb0 | — |
| @0x60083a50 | 0x60119fdc in `PmicTccPlatform_Schg_PDPhy_R1_IRQ_Setup` @0x60119d20 | Schg PDPhy R1 IRQ |
| @0x60169730 | 0x60175ccc in `smb139x_irq_setup` @0x60175990 | smb139x IRQ |

Plus an isolated callback @0x600a5be0
([`func-emit-callback-600a5be0.txt`](../logs/adsp-re/func-emit-callback-600a5be0.txt)).

The HW CC logger is @0x60112090 (CC_STATUS message xref @0x60112bdc).

### HW CC arming: `PmicTccPlatform_Init`

`PmicTccPlatform_Init` @0x6010ac50
([`func-arming-tcc-init-6010ac50.txt`](../logs/adsp-re/func-arming-tcc-init-6010ac50.txt)):
null-arg → 0x203; PMIC-ID gate (0x32/0x47/0x4c); fills a method table (+0x6348…+0x6364)
and calls the fn-ptr at +0x6348 ("Platform init function pointer is NULL"). It has
**0 direct callers and 0 fn-ptr references**, so it is reached via a runtime pointer
table — the arming gate is not statically readable. (Lower priority now that the
runtime-flag hypothesis is refuted, see below.)

## glink RX: the AP-originated entry

The AP talks to the PPM over glink. Two RX entry points:

- **`pmic_glink_rx_intent_req` handler @0x60088cd0..0x60088e70** —
  [`func-glink-rx-60088cd0.txt`](../logs/adsp-re/func-glink-rx-60088cd0.txt).
  The intent is processed **unconditionally**:
  `call 0x601343e0(arg0, 0, arg2)` (QDI "queue intent") is reached without any flag
  check. `result == 0` → return 1; otherwise a ULog-gated
  "rx intent failed:%d" ERROR log and return 0. The name string is vaddr 0x601faa63
  (2 xrefs, both inside this handler); the log fmt strings are 0x601faa25 / 0x601faa7c.
- **`pmic_glink_ulog_process_rx_data` @0x600872f0..0x60088960** —
  [`func-ulog-rx-processor-type19-600872f0.txt`](../logs/adsp-re/func-ulog-rx-processor-type19-600872f0.txt).
  Parses the glink-ULOG stream (magic 0x800a, type field +0x8: 0x18/0x19/0x23).
  **Type-0x19 = "set ULog mask + level from the AP"**: it writes the enable mask
  (`memd(##0x60256f78) = *(payload+0x10)`), the level (`memw(##0x60256f80) =
  *(payload+0x18)`) and the verbosity counter (`memb(##0x6024a660) = level`), then
  re-applies them.

## Headline finding: the "runtime flag" wall is ULog logging (H1 refuted)

Earlier rounds identified three "runtime flag globals" that appeared to gate the
functional processing (charger detection, glink intent handling, the APSD rerun). A
full write-site analysis shows these are **ULog logging controls, not AP-ready or
HW-arming flags**:

| vaddr | kind | total refs | semantics |
|---|---|---|---|
| 0x60256f78 | dw | 1900 | ULog client **enable mask** (bit per log tag) |
| 0x60256f80 | word | 4 | ULog **level** |
| 0x6024a660 | byte | 3403 | ULog **verbosity counter** |
| 0x6024a668 | dw | 1896 | ULog **default (static)** enable mask; bit0 = fallback-enable; 0 direct writes |
| 0x60256f60 | word | (many) | ULog client object ptr (arg of every log call) |

Direct write sites (full map in
[`ulog-flag-globals-write-sites.txt`](../logs/adsp-re/ulog-flag-globals-write-sites.txt)):

- **0x60256f78 (enable mask)** — 3 writes:
  - ULog client init @0x60080e24 (fn @0x60080dc0, "BATTMAN ULog"): mask = 0x3F_FFFFFFFF
  - setter fn @0x60080e7c (fn @0x60080e60)
  - glink-ULOG RX type-0x19 @0x600873e0 (from the AP)
- **0x60256f80 (level)** — 2 writes: ULog init @0x60080e30 (=3); glink RX @0x600873f0
- **0x6024a660 (counter)** — 2 writes: setter @0x60080e54; glink RX @0x60087400 (= level)
- **0x6024a668 (default mask)** — 0 direct writes (read-only in this build)

The ULog client init @0x60080dc0
([`func-ulog-init-60080dc0.txt`](../logs/adsp-re/func-ulog-init-60080dc0.txt)) is called
**only** from `BattMngr_init` @0x6002ad50 (call site 0x6002ad78;
[`func-battmngr-init-6002ad50.txt`](../logs/adsp-re/func-battmngr-init-6002ad50.txt)) —
i.e. the mask/level defaults are set at **ADSP boot**, not at any AP-ready handoff.

Every investigated "gate" site is the same **log-gate pattern**:

```
if (ulog_mask_bit || default_mask_bit) {
    if (counter cmp N) { ULog log(...); }
}
```

Verified instances: `SetRerunApsd` error path @0x60097910 and post-call fail path
@0x60097a28; the glink-RX intent handler @0x60088cec (INFO) and @0x60088db4 (ERROR);
`icm_ncp_stby_main` warn arms @0x601a1a44 (plus an extra flag `memb(##0x60339214)`);
the charger-detection SM @0x6014e770/0x6014e9c8/0x6014ebd8/0x6014ed34/0x6014eddc/
0x6014eeb0/0x6014efc8/0x6014f1e0. In **all** of them the functional code (state
writes, `callr` dispatch, glink intent processing) runs unconditionally — the globals
gate only the log emission.

**Consequence:** the hypothesis "HW CC arming / functional processing is gated by an
AP-ready runtime flag" (H1) is **refuted** as a flag-gate mechanism. The ADSP side
processes glink intents and charger-detection events without such a flag. The remaining
open question is purely **AP-side**: what does the AP send over glink (charger-type
intents, ULOG config type-0x19, battmgr notifications) in the initramfs environment vs
a full system? That is an unmeasured gap and the next measurement target.

## Charger type and the property system (final model)

Later rounds answered "who pulls the charger type". The mechanism is now fully mapped;
the remaining unknown is behavioral, not static.

### The type byte T is static boot config

The type byte `T` (ChgIcmCfg @0x603391b8+1, read by the ICM flag function through the
global pointer @0x60339210, written **once** in the constructor @0x601a12c0 ← ICM init
@0x6019fe90) has **zero runtime writes** in the whole disassembly (only the init
@0x6019ffe4, which preserves it). `chgr_stat` (property 0x2606) is **PMIC-backed and
read-only** in the ADSP code (no setter). So "who pulls the charger type" is **not** a
runtime ADSP actor: the type is fixed by boot configuration (HW/FDT), and the dynamic
"charger present / type changed" information comes from the PMIC and is triggered by
AP-side USB/PD activity.

### Property 0x270b: every reference is a GET

A whole-file scan (code immediates + data const-words, both byte orders) finds exactly
**six** references to property id 0x270b and **all six are GETs**; there is **no SET**
with a visible id:

| Site | Context |
|---|---|
| 0x6016aaec (fn 0x6016aad0) | ctxB->+0x1c: `GET(0x270b) → out & 0x10` (bit 4 = PD-type present) |
| 0x6016ab5c (fn 0x6016ab40) | ctxB->+0x20: `GET(0x270b) → out & 0x20` (bit 5 = USB-type present) — the ICM "type updated" check for T∈{2..16,19} |
| 0x6016abcc (fn 0x6016abb0) | ctxB->+0x24: `GET(0x270b) → out & 0x80` (bit 7 = notify/cable-state) |
| 0x6016c0a4 (fn 0x6016c070) | ctxB->+0xc0 notify: `GET(0x270b)` → payload = (out>>7 & 1) ? 2 : 1 → post events 0x7e42 / 0x7ee5 (1 ref each, no other subscribers) |
| 0x600a84c4 / 0x600a9e94 (fn 0x600a83f0) | per-port getters (callr-only; port index > 0xa → error 0x202; per-port table 0x60325419 + idx·0x1c) via a **second** property chain 0x60081910 → 0x60081790 → 0x60082060 (global 0x60283620, not the ICM registry) |

The registry id-tables themselves are BSS (runtime), so ids exist only as code
immediates in the GETs above.

### `icm_ncp_stby_init` @0x601a1320 — the full wedge logic

Decoded in full ([`func-icm-ncp-stby-init-601a1320.txt`](../logs/adsp-re/func-icm-ncp-stby-init-601a1320.txt)):

- `T = *(*(0x60339210) + 1)`; `chgr_stat` = getter @0x601479b0 → byte.
- **chgr_stat switch:** 3 → `icm->+0xc = 3` (normal); 4 → vbat getter @0x60147e90,
  vbat ≤ 0x2647 (9799 mV) → `icm->+0xc = 3`; 5 → mask accumulator @0x6016e2d0(ctx,8,0);
  7 → @0x6016e2d0(ctx,3,0x1388) + @0x6016d930(ctx,0x1004) (thresholds 0x1388 = 5000,
  0x1004 = 4100 mV); otherwise nothing.
- **Flag recompute only when `icm->+0xc == 2`** (already in ncp_stby):
  - `T ∈ {21,22,23}` → flag = `!(0x270b & 0x10)` (via ctxB->+0x1c)
  - `T ∈ {2..16,19}` → flag = `!(0x270b & 0x20)` (via ctxB->+0x20)
  - `T ∈ {0,1,17,18,20}` or `T > 23` → **flag = 1 + ULog warn** and `icm->+0xc = 2`
    (the wedge)
  - flag = 0 → `0x60339214 = 0`
- The warn log (ULog-gated) is the **firmware original, typo and all**:

  ```
  Warn: %s: icm_ncp_stby_init: keeps in icm_ncp_stby utill charger_type updated
  ```

  (fmt string @0x60238d14, name @0x60238d62). In words: **the ICM stays in ncp_stby
  until the property service pushes a 0x270b (charger_type) update.**

### The property system is an RPC to a central property service

The ICM/charger property stack does not store property values locally — it talks to a
central property service over a channel (handle global @0x6024c170; the whole family
0x6012b008–0x6012b200 is the only user of that global):

- **Command inventory:** 0x101, open `{hi=2, lo=4}` (fn 0x6012b020), 0x103, 0x104,
  **0x107 = property access (GET and SET share it; direction in payload)** (fn
  0x6012b138, 24-byte payload via the dispatch walker 0x60007480/0x6000748c),
  **0x10a = ACK**, 0x10b (fire-and-forget 64-bit message, fn 0x6012b1c8),
  0x10c (fn 0x6012b1e8).
- **Boot initialization:** the service-table init (fn 0x60025bc0 area) registers the RX
  handler and opens the channel (0x6012b204: RX cb 0x6012b280 on cmd 0x103, second
  channel global 0x6032cf0c; 0x6012b020: `if (channel == -1) channel = send(open)`).
- **RX handler 0x6012afc8 = callback-push model**
  ([`func-property-rx-callback-6012afc8.txt`](../logs/adsp-re/func-property-rx-callback-6012afc8.txt)):
  loop { read 48-byte message @0x600072a0; ACK 0x10a; `cb = buf[4]; callr cb(buf[0],
  buf+8, buf+0x28)` } — i.e. **the service pushes change notifications with a
  callback pointer in the message**. That push is exactly the "charger_type updated"
  event the ICM waits for.
- **Local registry (BSS):** count @0x60338c69 (≤16), ids @0x60338c74, tables
  @0x60338c70, entries @0x60338cf0 (0x18 B: word0 = table_ptr, +8 = lock); entries are
  matched **by table_ptr, not by id**. Register 0x60191de0 ← single caller 0x601698c4
  (ICM-object init); GET 0x60192f40 (registry lookup + lock + RPC 0x107 at 0x60193270);
  SET 0x60192d30 (registry lookup, **masked value merge**
  `out = (out & mask) | (new & ~mask)`, then RPC 0x107 at 0x6019388c via 0x601933f0)
  ← single caller 0x6016a208 (state-1 branch of the SET wrapper 0x6016a150, which has
  ~200 callers from the charger stack with the id passed dynamically in a register).
- The ICM GET wrapper 0x60169a00 dispatches on `obj->+0x2`: 0 → vtable+0x0,
  1 → id-transformed registry GET, 2/3 → vtable+0x14.

**Where the service lives** (local ADSP service vs a remote DSP endpoint) is not
distinguishable from the disassembly; it does not block the fix.

### The ctxB object is a boot-time one-shot

The charger-type check object `ctxB` (\*0x60338c40, 0x108 B) is created **exactly once
at ADSP boot**:

```
service-table init (0x60025bc0 area)
  ├─ property service: RX registration 0x6012b204 + channel open 0x6012b020
  └─ battmngr_init 0x6002ad50        (strings "battmngr_platform_init",
                                       "battmngr_plat_scpqchg_qbg_r1_init")
     └─ 0x6002a770: client object alloc(0x798) → *0x60256ee8
        └─ stage dispatch 0x6002b030 (stage = ctx->+0x340, default 3,
            platform-byte override @0x6002a0f0)
           ├─ stage 3 → init batch 0x6002e0b0 ─┐
           └─ stage 4 → init batch 0x6004eca0 ─┤ both contain the factory:
                                               │ 0x60044810 / 0x60059b90
                                               ▼
                    singleton factory 0x6016e800
                      *0x60338c40 occupied → 0x202 EEXIST
                      else alloc(0x108) → *0x60338c40, memset,
                      callr ctor 0x6016a7c0(ctxB, 0x7)
                        ctxB: +0x1c = 0x6016aad0 (&0x10),
                              +0x20 = 0x6016ab40 (&0x20),
                              +0x24 = 0x6016abb0 (&0x80),
                              +0xc0 = 0x6016c070 (notify)
```

No re-creation or re-registration at runtime. So the runtime "charger_type updated"
can only arrive as a **property-service push** (RX callback → … → ctxB->+0xc0). See
[`func-ctxb-factory-6016e800.txt`](../logs/adsp-re/func-ctxb-factory-6016e800.txt).

### Final answer to "who pulls the charger type?"

- **Found (the mechanism, fully):** the wedge is `icm_ncp_stby_init` waiting for a
  0x270b update push from the central property service; the value is held/computed on
  the service side; ADSP never SETs it with a visible id (all six visible refs are
  GETs; a SET via the dynamic-id path is possible — the registry SET is the same RPC —
  and statically invisible, but it demonstrably does not happen in the failing
  environment, or the push would have arrived and the wedge would have cleared).
- **Found (the ADSP actor, named):** the charger type is re-evaluated by the **DPM
  USB-C state handler `dpm_usbc` @0x600d1dc0**, which — driven by an AP
  **pmic_glink** message (handler 0x60088eb0 ← 0x60089bc0) and in the appropriate
  DPM state — calls `SetRerunApsd(7)` → per-port APSD rerun → re-detection → 0x270b
  update → push. This path is **gated by `apsd-rerun-cfg`** (=0 in stock, so
  `SetRerunApsd` is a no-op). See
  [the trigger-chain section](#the-setrerunapsd-trigger-chain-pmic_glink--dpm_usbc).
  The second path is the CC-edge-driven `charger_detection_event_handler`
  @0x6014eab0 (needs a fresh physical edge). In the failing environment neither
  fires (no fresh edge + `apsd-rerun-cfg`=0) → the wedge.
- **Not found (remaining ceiling):** (1) the exact DPM state value that reaches the
  `SetRerunApsd` branch; (2) the specific pmic_glink message that drives it; (3) the
  exact `apsd-rerun-cfg` check site (FDT-only config, walked at runtime); (4) whether
  the AP's pmic_glink activity in the failing (initramfs) environment reaches that
  state at all. The AP-side static actor hunt remains negative in all four zones
  (dracut config/modules, kernel modules, udev rules, userspace daemons).
- **Conclusion:** the ADSP mechanism is now fully named and the `apsd-rerun-cfg`
  patch is backed by it. The remaining unknown is behavioral: whether the AP drives
  the DPM to the rerun state in the failing vs working environment — only
  measurement can settle it. That is the role of the full-system cold-plug fork test
  and the fresh-edge test (see below).

## Trigger table (consolidated)

| # | Trigger | Source | Status |
|---|---|---|---|
| 1 | fresh CC edge (attach) | HW (physical) | OUT — cold-plug = plugged before power-on; cannot re-plug |
| 2 | DPM USB-C rerun | AP **pmic_glink** → handler 0x60088eb0 → 0x60089bc0 → `dpm_usbc` @0x600d1dc0 → `SetRerunApsd(7)` | **GATED** by `apsd-rerun-cfg` (FDT, =0 in stock → `SetRerunApsd` no-op). Chain fully traced; exact DPM state + pmic_glink message + config check site not yet decoded; whether the AP reaches that state in the failing env = full-system fork test |
| 3 | charger-detection SM event | event 0x25 broadcast (HW CC IRQ **or** AP glink/UCSI) | **OPEN** — sources pinned (HW IRQ setup + glink RX); ADSP-side flag gates eliminated (ULog-only) |
| 4 | periodic/autonomous | `SetAiclPeriodicRerun` / `SetAiclRerunTimeCfg` / `set_hw_aicl_rerun` | DEAD CODE (0 refs) |

## Cross-firmware comparison

The PPM FDT payload (8315 B @MBN+208) is **byte-identical across all 7 sm8550
variants** (md5 `f7c72c64f8f7e0a75e5791ed973ea766`) — there is no "known-good" config
to copy. The MBN containers themselves differ (per-board signing), and the newer
SM8650 (kaanapali) and 8380 firmwares carry the same `apsd-rerun-cfg = 0`. Full md5
registry in [`cross-firmware-compare.txt`](../logs/adsp-re/cross-firmware-compare.txt).

## Remaining hypotheses and next steps

With the ADSP-side flag wall removed and the property system mapped, the candidates
narrow to:

1. **AP-side measurement (primary):** the wedge waits for a property-service
   **push** of the charger-type update (0x270b). The trigger for that push is a
   behavioral/timing event sequence of the AP-side USB/charger stack — identify it by
   capturing the AP activity in the window before successful enumeration in the
   working (full-system) environment: the full-system cold-plug fork test (pre-plug +
   cold-plug, dmesg window [T−2 s, T], typec/power_supply/udevadm) plus the fresh-edge
   test (boot without the stick, plug in after 5–10 s).
2. **Fresh-edge window:** the replug-timing correlation (≤ ~24.7 s works, ≥ ~38 s
   fails; ~30 s boundary) points to a PPM/BC1.2 classification window. See
   [ADSP_CONFIG.md](ADSP_CONFIG.md#timer--replug-correlation).
3. **`apsd-rerun-cfg` 0→1 patch:** the firmware contains a full APSD-rerun mechanism
   that is disabled by config. A 1-byte FDT patch (+ `sha384` recompute) is the
   candidate config fix. See
   [ADSP_CONFIG.md](ADSP_CONFIG.md#the-1-byte-patch-recipe-verified-by-trial-patch).

The decisive low-cost experiment remains the full-system cold-plug fork test
(pre-plug vs post-plug) to capture what the AP does at the moment of enumeration —
see [FULL_SYSTEM_COLDPLUG_TEST.md](FULL_SYSTEM_COLDPLUG_TEST.md).
