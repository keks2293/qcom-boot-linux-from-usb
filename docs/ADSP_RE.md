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

- `dump_adsp.sh` — produce `text_all.txt` (a verified copy for the stock RP6
  firmware is published at [`logs/adsp-re/text_all.zst`](../logs/adsp-re/text_all.zst))
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

- `icm_ncp_stby_main` @0x601a1790 (body 0x601a1790–0x601a1c2c, **fully decoded**
  2026-11-09) is the **event dispatcher** for the wedge state:
  - Prologue: loads `T = *(*(0x60339210) + 1)`; early return unless
    `icm->+0xc == 2` — state **2 = icm_ncp_stby** (matches the diag
    `curr=2 next=2`).
  - Jump table on `event − 7` (table @0x60238cc0); valid index 0..0x11 ⇒ events
    7..0x18, default arm @0x601a1978. **Event 24 (0x18) is the maximum = the
    periodic tick** (matches the diag `event_type=24`).
  - **Handler-1** @0x601a182c: `chgr_stat == 3` **or** `(chgr_stat == 4 and
    vbat ≤ 0x2647)` → **direct `icm->+0xc = 3` @0x601a1898, before the flag
    section**.
  - **Flag section** @0x601a197c–0x601a1ae0 — the same logic as
    `icm_ncp_stby_init` (below): null-guarded vtable calls on `B = 0x6016e900()`
    (the ctxB singleton, `*0x60338c40`), selected by the T range:
    `T ∈ {21,22,23}` → `flag = !(B->vt[+0x1c/4](B) != 0)` (via 0x6016d2f0; the
    target is 0x6016aad0 = `GET(0x270b) & 0x10`); `T ∈ {2..16,19}` →
    `flag = !(B->vt[+0x20/4](B) != 0)` (via 0x6016d350; target 0x6016ab40 =
    `GET(0x270b) & 0x20`); `T ∈ {0,1,17,18,20}` or `T > 23` → **flag = 1
    unconditionally**.
  - Exit evaluation @0x601a1ae0 → `icm->+0xc = 3` @0x601a1b4c when `flag == 0`.
  - **Force-stay** @0x601a1ad8: when `flag == 1`, re-assert `icm->+0xc = 2` —
    **overwriting the state 3 that handler-1 may have set** — behind the ULog
    gate that also emits the WARN "keeps in icm_ncp_stby utill charger_type
    updated" (typo "utill" verbatim; the `main` variant's fmt string is
    @0x60238da2, the `init` variant's @0x60238d14).
  - Epilogue @0x601a1b58; the function returns the flag.

So the ICM state machine stays in `icm_ncp_stby` until charger-detection updates
`charger_type`. The questions are what re-triggers detection — and what value T
has at runtime (below).

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

### The value of T: two hypotheses (2026-11-09)

The write-site search is now **closed (negative)**: a full taint analysis (39 597
functions) plus a direct-address scan of the halfword at 0x603391b8 finds exactly
**one** store — the ICM init @0x6019ffe4 (`memh(##0x603391b8) = (old & 0xfff0) | 4`),
which preserves the byte. So T is either:

- **H1 (static, T = 0):** the byte is BSS (zero) and nothing ever writes it. Then the
  flag section takes the "otherwise" branch: **flag = 1 on every event,
  unconditionally** — no property value can clear the wedge, and the
  `apsd-rerun-cfg` patch cannot help (dbg53 dead).
- **H2 (config-loader, candidate T = 2):** a firmware config loader writes T from
  the config source. **Correction (2026-11-09):** the previously cited string evidence
  was wrong — `__symbols__` @ vaddr 0xb23e7341 belongs to a **DAL device-tree overlay
  embedded inside `adsp.mbn`** (an R/E segment whose string table holds `target-path`,
  `__overlay__`, `__fixups__`, `DAL_DeviceAttachEx`), and `battman` @ vaddr 0xf02fe8e1
  is the **`battman_policy.c` log tag**; the three code references to `0xd00dfeed`
  (f0117dfc, f0053d38, f0053e68) are **RPC message magics**, not FDT parsing.
  **The real evidence:** the firmware contains a **config-key name table at
  vaddr 0x601d7c38–0x601d7e0a** — 34 keys that map 1:1 by name to the FDT nodes
  (`ChgDetCfg`↔`chg_det_cfg`, `ChgIcmCfg`↔`chg_icm_cfg`, `TcpcCfg`↔`tcpc_cfg`,
  `UcsiCapCfg`↔`ucsi_cap_cfg`, `UcsiConnectorCapCfg`↔`ucsi_conn_cap_cfg`,
  `PDPoliciesCfg`↔`pd_policies_cfg`, `PDStaticInfo`↔`pd_static_info_cfg`,
  `LpmCfg`↔`lpm_cfg`, `WirelessCfg`↔`wls_chg_cfg`, `ChargerLedCfg`↔`led_cfg`,
  `BatteryAuthenticationCfg`↔`batt_auth_cfg`, `MaintenanceChgCfg`↔`mtc_chg_cfg`,
  `ChargeTableCfg`↔`chg_table_cfg`, `ThermThresholdCfg`↔`therm_thresh_cfg`,
  `QbgCfg`↔`qbg_cfg`, `IDTCfg`↔`chg_idt_cfg`, `LPDCfg`↔`chg_lpd_cfg`,
  `BhargerCfg`↔`pl_chg_cfg`, plus `ADC_BSP`, `BattmngrBSP`, `ChargerTempCfg`,
  `BatteryErrorCfg`, `VDMStaticInfo`, `UFCSCfg`, `owner`, `spmi_devices`,
  `image_id`, `VADC_BSP`, `VADCTM_BSP`, `APQ123456`, `MPSS 1.0`) — followed
  immediately by **baked binary config data** (vaddr 0x601d7e10, read-only
  segment; records with type tags 0x12/0x14/0x18/0x11/0x02 ×0x80 and
  0x00ff00ff "no value" markers). The config lookup `0x60084be0(name, index,
  out, size)` decodes to: name check + `base = *(0x60324a98) + index*size` + a
  generic unaligned/endianness memcpy (0x600080a0); the ICM init's
  `config_get("ChgIcmCfg", 0, &h, 3)` writes three handle bytes to
  0x603391e8/ea — **not** the T byte at 0x603391b9 — so the T write-site is still
  unidentified (prime candidate: the config system's generic memcpy from an
  FDT/baked config block, a write the taint analysis can miss when the
  destination pointer is computed dynamically). The `chg_icm_cfg` node
  (phandle 0x12) carries exactly two properties, `force-eoc-5v = 0` and
  `ptm-cfg = 2`; no property is named after the type byte, and `ptm-cfg = 2` is
  the only plausible T source. If T = 2, the flag is `!(GET(0x270b) & 0x20)` and
  the `apsd-rerun-cfg = 0→1` patch (dbg53) is viable, provided the re-detection
  path sets that bit.

**Logical constraint (2026-11-09):** the ICM always passes through pre_chg (state 1) →
ncp_stby (state 2) — pre_chg's **only** state write is `icm->+0xc = 2` @0x601a0bb8 —
and can leave ncp_stby only via `flag == 0`. The measured working system (full-system
boot: `PartnerType=15`, 9 V / 2440 mA) *does* leave ncp_stby, so in a working system
**T ∈ {2..23}**. H1 (T = 0) is therefore in tension with the working system unless the
working system never enters ncp_stby — not supported by the ICM init, which sets state
1 at boot (@0x6019ffc8). The next RE step is to **find the T write-site**: trace the
config system's generic memcpy (0x600080a0) for a destination of 0x603391b8, decode the
baked config block at vaddr 0x601d7e10 (does it carry `ptm-cfg`/T, and how is it mapped
into the `ChgIcmCfg` block), and determine where the config base `*(0x60324a98)` comes
from (runtime FDT parse vs the baked table). This decides dbg53 viability directly.

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
  @0x6014eab0 (needs a fresh physical edge; fully decoded 2026-11-10,
  including the **skip-while-sourcing gate** that suppresses the USB
  charging-type write in the source role — see
  [the handler section](#charger_detection_event_handler-and-the-skip-while-sourcing-gate-2026-11-10)).
  In the failing environment neither fires (no fresh edge +
  `apsd-rerun-cfg`=0; and even a fired edge would hit the skip gate in the
  source role) → the wedge.
- **Not found (remaining ceiling):** (1) the exact DPM state value that reaches the
  `SetRerunApsd` branch; (2) the specific pmic_glink message that drives it; (3) the
  exact `apsd-rerun-cfg` check site (FDT-only config, walked at runtime); (4) whether
  the AP's pmic_glink activity in the failing (initramfs) environment reaches that
  state at all.
- **AP-side actor (now named):** the userspace actor hunt was negative in all four
  zones (dracut config/modules, kernel modules, udev rules, userspace daemons)
  because the actor is not userspace: it is the **in-kernel UCSI core**
  (`ucsi.c` + `ucsi_glink.c`), which exists in every environment and sends the four
  PMIC-doorbell commands itself (0x03/0x09/0x0b/0x10) — see
  [the UCSI/PPM command protocol section](#the-ucsi-ppm-command-protocol-ap--adsp).
- **Conclusion:** the ADSP mechanism and the AP actor are both fully named, and the
  `apsd-rerun-cfg` patch is backed by the ADSP mechanism. The remaining unknown is
  the PPM/PMIC **state** in the failing environment (port misclassification + no
  fresh CC edge + `icm_ncp_stby` wedge) — only measurement can settle it. That is
  the role of the fresh-edge test (see below).

## The UCSI/PPM command protocol: AP ↔ ADSP

### There is no vendor renumbering — the AP speaks plain UCSI

The PPM dispatch table reconstructed from the disassembly (below) uses the
**standard UCSI command numbers** — they match kernel
`drivers/usb/typec/ucsi/ucsi.h:112-144` (v7.2.6) 1:1:

| # | Name | # | Name |
|---|---|---|---|
| 0x01 | PPM_RESET | 0x0d | GET_CAM_SUPPORTED |
| 0x02 | CANCEL | 0x0e | GET_CURRENT_CAM |
| 0x03 | CONNECTOR_RESET | 0x0f | SET_NEW_CAM |
| 0x04 | ACK_CC_CI | 0x10 | GET_PDOS |
| 0x05 | SET_NOTIFICATION_ENABLE | 0x11 | GET_CABLE_PROPERTY |
| 0x06 | GET_CAPABILITY | 0x12 | GET_CONNECTOR_STATUS |
| 0x07 | GET_CONNECTOR_CAPABILITY | 0x13 | GET_ERROR_STATUS |
| 0x08 | SET_CCOM | 0x14 | SET_POWER_LEVEL |
| 0x09 | SET_UOR | 0x15 | GET_PD_MESSAGE |
| 0x0a | SET_PDM | 0x16 | GET_ATTENTION_VDO |
| 0x0b | SET_PDR | 0x18 | GET_CAM_CS |
| 0x0c | GET_ALTERNATE_MODES | 0x1c..0x22 | SET_SINK_PATH / SET_PDOS / READ_POWER_LEVEL / SET_USB / GET_LPM_PPM_INFO |

The public QTI vendor driver `ucsi_qti_glink.c` (OnePlus SM8850 tree) also
passes the core commands through without remapping (sync =
`ucsi_sync_control_common` / `UCSI_MESSAGE_OUT`, async = `UCSI_CONTROL`
write; owner 32779; buffer 48 B v1 / 528 B v2) — the same shape as the
upstream `ucsi_glink.c`.

Command word layout (`ucsi.h:146-154`): bits[7:0] = command, bits[23:16] =
connector number, **bit 23 = CONNECTOR_RESET hard flag** (v1.0: hard reset;
v2.0: data reset).

### The dispatch table (from the disassembly)

RX handler `ppm_ucsi_mailbox_write` @0x600d60d0 (glink opcode **0x12** =
`UC_UCSI_WRITE_BUF_REQ`; the UCSI service's glink peer is the AP): gate
`memb(0x603286b4)` (UCSI-enable — set by the ADSP itself at service
registration, single write-site @0x600d39a8, never cleared ⇒ set in both
environments, **not** a discriminator), copies cmd(8 B) → 0x60328688 and
data(16 B) → 0x603286a0, logs the raw command byte, and — for **every**
write — also rings the PMIC (op 0x16, see below).

Dispatcher @0x600d4830 (vtable slot `svc->+0x24`):
`idx = memub(0x60328688) - 2`, bounds 0..0x11, jump table 0x6020c29c
(18 entries, commands 0x02..0x13):

| cmd | handler | note |
|---|---|---|
| 0x03 | 0x600d8620 | CONNECTOR_RESET (decoded below) |
| 0x04 | 0x600d7230 | ACK_CC_CI |
| 0x09 | 0x600d87f0 | SET_UOR — **rings the PMIC doorbell** |
| 0x0b | 0x600d8f30 | SET_PDR — **rings the PMIC doorbell** |
| 0x0c | 0x600d96d0 | GET_ALTERNATE_MODES |
| 0x10 | 0x600d7fb0 | GET_PDOS — **rings the PMIC doorbell** |
| 0x02, 0x05, 0x06, 0x07, 0x0d, 0x0e, 0x12, 0x13 | 0x600d4948 → 0x600d75e0 | "immediate" group: sub-table 0x6020c304 (18 entries, sub-idx = cmd−2, stub 0x600d7f7c); real handlers: 0x02→0x600d7f6c, 0x05→0x600d7634, 0x06→0x600d7820, 0x07→0x600d790c, 0x0d→0x600d7f4c, 0x0e→0x600d7f5c, **0x12 GET_CONNECTOR_STATUS→0x600d7b54**, **0x13 GET_ERROR_STATUS→0x600d7e88** |
| 0x08, 0x0a, 0x0f, 0x11 | 0x600d4a74 | error |

Evidence: [`logs/adsp-re/ppm-ucsi-dispatch-table.txt`](../logs/adsp-re/ppm-ucsi-dispatch-table.txt).

### Exactly four commands ring the PMIC doorbell

`ppm_set_request_to_lpm` @0x600da6d0 ("Relay OPM request to LPM") has
**exactly four callers in the whole firmware**:

| caller fn | command | call site |
|---|---|---|
| 0x600d7fb0 | 0x10 GET_PDOS | 0x600d83a8 |
| 0x600d8620 | 0x03 CONNECTOR_RESET | 0x600d87c4 |
| 0x600d87f0 | 0x09 SET_UOR | 0x600d8e64 |
| 0x600d8f30 | 0x0b SET_PDR | 0x600d9550 |

Chain: `0x600da6d0 → 0x600ccb80` (per-port, stride 0xf8, handles @0x60325f94+,
maxports @0x60325dcc) `→ 0x600da940 → 0x6019cd40(handle, 0x20) → 0x600810b0
→ 0x60003094(handle, 0x20)` = glink **doorbell to the PMIC**: OR bit 0x20
into the 64-bit shared command bitmap (CAS) + `trap0(#0x11)`.
`0x60003094` has a single caller (0x600810b0). Every UCSI write
additionally rings op **0x16** from the RX handler (0x600cc190(handle, 0xb)
→ 0x6019cd40(handle, 0x16) → 0x600810b0 → 0x60003094). Evidence:
[`logs/adsp-re/ppm-doorbell-callers.txt`](../logs/adsp-re/ppm-doorbell-callers.txt).

### The CONNECTOR_RESET handler (0x600d8620), fully decoded

NULL ctx → 0x203; `port = memub(cmd_buf+2) & 0x7f`, valid 1..4 else 0x202;
log `"Info: %s: CONNECTOR_RESET: Port[%d], HardReset=%d"` (fmt 0x6020d6ef,
name 0x6020d721: `ppm_proccess_connector_reset_command`, typo verbatim);
`ctx->+0x1ca = hard ? 0x0a : 0x09`; `ctx->+0x1c8 = 1`; `ctx->+0x1c9 = port−1`;
**`call 0x600da6d0`** (the doorbell chain); mailbox op 7 (0x600d5c20);
`ctx->+5 = 4`; return 0. The handler is elementary: it does **not** touch
CC/ICM state directly — it records the reset state and relays an OPM
request to the PMIC. Evidence:
[`logs/adsp-re/func-connector-reset-600d8620.txt`](../logs/adsp-re/func-connector-reset-600d8620.txt).

### The AP-side actor: the in-kernel UCSI core

The client that sends these commands is the **UCSI core** (`ucsi.c` +
`ucsi_glink.c`, all `=y`) — there is no userspace daemon and no separate
glink client. The core itself sends all four doorbell commands:

| command | site (ucsi.c, v7.2.6) | condition |
|---|---|---|
| SET_UOR (0x09) | `ucsi_dr_swap` :1725-1728, via `typec_set_data_role` from `ucsi_partner_change` :1334-1348 | **only if `PARTNER_TYPE` ∈ {UFP, CABLE, CABLE_AND_UFP, DFP}**; `PARTNER_TYPE = 0` (USB2) → `default: break` → not sent |
| SET_PDR (0x0b) | `ucsi_pr_swap` :1767-1770 | power-role swap request |
| GET_PDOS (0x10) | `ucsi_register_partner` :1279-1280 → `ucsi_read_pdos` :873 | **only if `PWR_OPMODE == PD`** |
| CONNECTOR_RESET (0x03) | recovery path `ucsi_role_cmd` :1687-1697 → `ucsi_reset_connector` :1594-1606 (plus PPM_RESET 0x01 + SET_NOTIFICATION_ENABLE via the async `UCSI_CONTROL` write, `ucsi_glink.c:190`) | after **any** role command returns `-ETIMEDOUT` |

Whether the core is **active or deferred** is set by the device tree, not
by the environment: with the `usb-role-switch` property absent (spliced
diagnostic images, dbg12+) the full handshake completes and the core runs
the commands above; with the property present and an empty role-switch class
(un-spliced stock/CI initramfs images) `ucsi_register_port` gets
`-EPROBE_DEFER`, retries 100 × 100 ms, gives up with
`"PPM init failed, stop trying"`, and the AP stops sending UCSI commands
(only the boot-time `UCSI_PPM_RESET` storm remains — 0x01 is not a doorbell
command).

The earlier inference that the **full system** is deferred is **refuted by
measurement** (2026-11-05): the full-system boot has
`/sys/class/typec/port0` + `port0-partner`, a registered `usb_role` switch,
`power_operation_mode=usb_power_delivery` and a 9 V PD contract, so the UCSI
core is **active** there too.

Consequence for the diagnosis: in the **active** initramfs runs (dbg31/32)
the UCSI core fires the doorbell commands — the PPM processed them
(refused with `UCSI_ERROR_CC_COMMUNICATION_ERR` or timed out, which is an
answer, not silence; GET_PDOS fired at boot because the state already
showed `power_operation_mode=usb_power_delivery`; the manual
CONNECTOR_RESET completed including the doorbell) — **and the wedge still
persists**. In the measured full-system environment the core is active as
well and enumeration works, so active-vs-deferred UCSI and the presence of
`qcom_battmgr` are both ruled out. The discriminator is therefore **not** the
presence or absence of an AP actor but the **PPM/PMIC state**: in the
failing environment the stick was attached before the PPM started (no
fresh CC edge after that), the port is misclassified (`PARTNER_TYPE = 0`,
USB2 — so the core itself stops sending SET_UOR), role commands are
refused with a CC communication error, and the ICM stays in
`icm_ncp_stby` until the charger type is updated
([charger-type-chain.md](../diagrams/charger-type-chain.md)). A fresh CC
edge (replug ≤ ~24.7 s, cold plug), a host-controller bring-up after the
charger service is ready (the measured full-system ordering), or a PMIC-side
re-run (`apsd-rerun-cfg`) is what re-arms detection. `qcom_pmic_typec`
(CONFIG_TYPEC_QCOM_PMIC) is not an actor on this board: its OF-match is
`qcom,pm8150b-typec` / `qcom,pmi632-typec` only — neither node exists in
the RP6 device tree (the active connector is `/pmic-glink/connector@0`).

## Trigger table (consolidated)

| # | Trigger | Source | Status |
|---|---|---|---|
| 1 | fresh CC edge (attach) | HW (physical) | OUT — cold-plug = plugged before power-on; cannot re-plug |
| 2 | DPM USB-C rerun | AP **pmic_glink** → handler 0x60088eb0 → 0x60089bc0 → `dpm_usbc` @0x600d1dc0 → `SetRerunApsd(7)` | **GATED** by `apsd-rerun-cfg` (FDT, =0 in stock → `SetRerunApsd` no-op). Chain fully traced; exact DPM state + pmic_glink message + config check site not yet decoded; whether the AP reaches that state in the failing env = full-system fork test |
| 3 | charger-detection SM event | event 0x25 broadcast (HW CC IRQ **or** AP glink/UCSI) | handler **fully decoded** (2026-11-10): in the **source role** it skips the USB charging-type classification entirely ("skip … while usb is sourcing", [handler section](#charger_detection_event_handler-and-the-skip-while-sourcing-gate-2026-11-10)) — so even a fresh edge cannot produce a `usb_type` write while the port sources |
| 4 | periodic/autonomous | `SetAiclPeriodicRerun` / `SetAiclRerunTimeCfg` / `set_hw_aicl_rerun` | DEAD CODE (0 refs) |

## Cross-firmware comparison

The PPM FDT payload (8315 B @MBN+208) is **byte-identical across all 7 sm8550
variants** (md5 `f7c72c64f8f7e0a75e5791ed973ea766`) — there is no "known-good" config
to copy. The MBN containers themselves differ (per-board signing), and the newer
SM8650 (kaanapali) and 8380 firmwares carry the same `apsd-rerun-cfg = 0`. Full md5
registry in [`cross-firmware-compare.txt`](../logs/adsp-re/cross-firmware-compare.txt).

## Remaining hypotheses and next steps

With the ADSP-side flag wall removed, the property system mapped and the AP
actor named (the in-kernel UCSI core — see
[the UCSI/PPM command protocol section](#the-ucsi-ppm-command-protocol-ap--adsp)),
the candidates narrow to:

1. **PPM/PMIC state in the failing environment (primary):** the UCSI core
   is active in the initramfs runs and **also active in the measured full
   system** (2026-11-05), yet only the full system enumerates — so the
   discriminator is not the AP actor or UCSI mode. In the failing environment
   the port is misclassified (`PARTNER_TYPE = 0`, USB2), role commands are
   refused with `UCSI_ERROR_CC_COMMUNICATION_ERR`, and the ICM waits for a
   charger-type update push that never comes. The target case is **pre-plug**
   (drive connected before power-on): there is no fresh CC edge after the PPM
   starts in *either* environment, so the fresh-edge mechanism (item 2) cannot
   explain why the full system still enumerates a pre-plugged drive. The
   full-system pre-plug fork was captured on 2026-11-05
   ([FULL_SYSTEM_PREPLUG_RESULT.md](FULL_SYSTEM_PREPLUG_RESULT.md)): the port
   is classified (`usb_type=[SDP]`, PD contract) and the xHCI host comes up
   **after** the `charger_pd` PDR (10.41 s → 14.81 s), unlike the initramfs
   (USB events 2.716/3.182 s before the PDR at 3.498 s). The next step is the
   falsifiable test: re-probe `dwc3-qcom` + `xhci-hcd` inside the ≤30 s window
   in the initramfs and check whether the drive enumerates.
   **Refinement (2026-11-10):** the dbgB capture plus the full handler decode
   pin the *exact* missing step — in the source role (pre-plug stick, the
   USB-boot scenario) the event handler takes the skip-while-sourcing gate
   and never writes the USB charging-type property, so `usb_type=Unknown` is
   **by-design firmware behavior** in that role, not a stuck/missing trigger.
   See [the handler section](#charger_detection_event_handler-and-the-skip-while-sourcing-gate-2026-11-10)
   (fix implication 1: the AP-side boot decision must not depend on
   `usb_type` in the source role).
2. **Fresh-edge window:** the replug-timing correlation (≤ ~24.7 s works, ≥ ~38 s
   fails; ~30 s boundary) points to a PPM/BC1.2 classification window. See
   [ADSP_CONFIG.md](ADSP_CONFIG.md#timer--replug-correlation).
3. **`apsd-rerun-cfg` 0→1 patch:** the firmware contains a full APSD-rerun mechanism
   that is disabled by config. A 1-byte FDT patch (+ `sha384` recompute) is the
   candidate config fix. See
   [ADSP_CONFIG.md](ADSP_CONFIG.md#the-1-byte-patch-recipe-verified-by-trial-patch).
   **Its effectiveness depends on T** (2026-11-09): under H1 (T = 0) the ICM flag is
   1 unconditionally and the patch cannot clear the wedge; under H2 (T = 2, written by
   the config loader from `ptm-cfg`) the flag is `!(GET(0x270b) & 0x20)` and the patch
   enables the concrete re-detection path. See
   [the value of T](#the-value-of-t-two-hypotheses-2026-11-09).

## The two remaining function bodies — now decoded (2026-11-09)

The full disassembly has been rebuilt locally (`text_all.txt`, 3,666,180 lines,
219 848 927 B; published compressed as
[`logs/adsp-re/text_all.zst`](../logs/adsp-re/text_all.zst), 27.9 MB,
`zstd -d text_all.zst > text_all.txt`) with Homebrew LLVM 23.1.3
(`llvm-objdump --triple=hexagon -d`, see
[`scripts/adsp-re/dump_adsp.sh`](../scripts/adsp-re/dump_adsp.sh)). The two
function bodies that were left open are decoded here. Firmware:
`adsp.mbn` md5 `535b2f806f1e87a4a063827c81270968`, segment PT_LOAD#19
file `0xa93000` ↔ vaddr `0x60000000` (string vaddr = `0x60000000 + (off − 0xa93000)`).

### `charger_detection_evaluate_typec_charger` @0x60150d50–0x60152380

1 421 instructions; the per-input Type-C evaluation that the chg-det SM calls
after each event-0x25 wake. Inputs and data:

- Reads the 7-byte Type-C status of the port via
  `ssdev_typec_get_status` @0x601580b0 (memcpy of `*(u8*)(port_state+0x7d)`
  × 7), the partner type via
  `ssdev_typec_get_partner_type` @0x601581e0 (`*(u8*)(port_state+0x84)`), and
  a helper @0x6015c1e0 (`*(u8*)(port_state+0x29)`). `port_state` is looked up
  in a per-port table (`memw(0x60256ef8) + input*0x14` for status/partner,
  `memw(0x60256ef4) + input*0x14` for the helper); NULL entry → return `0x202`.
  Also reads the SDAM OS state via `PmSdamBm_GetOS` @0x6009cb90 and three
  global getters (`memw(0x60338c40)` @0x6016e900, `memw(0x60336c00)`
  @0x6015ba00, `memw(0x60336bf8)` @0x60156e80).
- Per-input result table: `0x60334b40`, stride `0x14`: `+0x1c` present flag,
  `+0x1d` PartnerType, `+0x20` Voltage (mV), `+0x24` Current (mA), `+0x28`
  bLpdEn, `+0x29` bLiquidDetected, `+0x2a` bPDSuspendSupported, `+0x2c` power
  max (µW).
- Classification: status rc ≠ 0 → returns the rc. Type-C partner type in
  `{0xf, 0x10, 0xa, 0x13}` → PartnerType = the value itself (PD partners).
  Otherwise a cascade of branches (on the status bytes + the SS partner byte)
  writes 1 / 2 / 5 / … : branch **2 (SDP)** stores 5000 mV / 500 mA /
  2 500 000 µW max (`0x60152120`–`0x60152158`); another stores 5000 mV /
  1500 mA (`0x601521fc`–`0x60152214`). NULL state pointer → return `0x202`.
- **The `PartnerType=` print is ULog-gated.** The log block at
  `0x60152264`–`0x601522a0` is entered only if `tstbit(memub(0x60256f7c), #2)`
  is set, otherwise the default-mask check on bit 4 of `memub(0x6024a66c)`
  (disassembled as the predicate form `p0 = bitsclr(r2,#0x4)`, i.e. "bit
  clear"), and `memub(0x6024a660) > #2` — the same ULog enable-mask /
  default-mask / verbosity-counter gate as everything else (the identical
  shape, with `!tstbit`, is used at `0x60150e18` for the `bLpdEn=` line)
  ([`ulog-flag-globals-write-sites.txt`](../logs/adsp-re/ulog-flag-globals-write-sites.txt)).
  The `bLpdEn=` line is gated the same way with mask byte `0x60256f79` bit 6 /
  default `0x6024a669` bit 6. So **absence of the `PartnerType=` line in a
  drain is a logging-config artifact unless the capture demonstrably enables
  that tag** — it is not by itself proof of a functional detection miss. The
  functional marker that the result actually reached the charger state machine
  is the `sm_state_loop` event burst + the ICM `ncp_stby`
  "untill charger_type updated" (which is what the dbg49 fingerprint actually
  shows; see [ADSP_ULOG.md](ADSP_ULOG.md)).

### `battmngr_plat_scpqchg_qbg_r1_update_wlstx_otg_context` @0x60040050–0x60040784

462 instructions. It is **not** an IRQ-arming function — it is one step of the
battmngr platform init:

- Reads SDAM: `PmSdamBm_GetOS`, `PmSdamBm_Get_WlsTx_status` @0x6009e230,
  `PmSdamBm_Get_Otg_status` @0x6009e580; reads boost state:
  `PmSchgDcdc_GetBoostOnWls` @0x60090480 / `PmSchgDcdc_GetBoostOnUsb`
  @0x600906b0.
- Writes SDAM: `battmngr_plat_scpqchg_qbg_r1_set_wlx_tx_status_to_sdam`
  @0x600472b0, `battmngr_plat_scpqchg_qbg_r1_set_otg_status_to_sdam`
  @0x600471d0; calls `battmngr_plat_scpqchg_qbg_r1_enable_wireless_tx`
  @0x6003ab00 when wls tx is requested.
- Logs: `wlstx enable: %d`, `otg enable: %d`, `wls tx source = %d`,
  `IDT in wrong state, disabling wls tx…`, `otg source = %d`, `OTG source not
  available` — all ULog-gated like everything else.
- **Single caller:** `call 0x60040050` at `0x60030428`, inside
  `battmngr_plat_scpqchg_qbg_r1_one_time_init` (fn `0x6002f480`).

### The init call chain (corrects the "otg line = IRQ armed" phrasing)

```
BattMngr_init @0x6002ad50
  → BattMngr_BattMngr_init @0x6002a770
    → battmngr_platform_init @0x6002b030 (dispatch via fn-ptr table,
       platform init fn ptr stored at 0x6002b174)
      → battmngr_plat_scpqchg_qbg_r1_init @0x6002e0b0
          → (0x6002e8d8) battmngr_plat_scpqchg_qbg_r1_one_time_init @0x6002f480
              → (0x60030428) update_wlstx_otg_context @0x60040050   ← "otg enable: 1"
          → (0x6002e8e8) battmngr_plat_irq_scpqchg_qbg_r1_irq_setup @0x6004e260
```

Consequences:

- **`otg enable: 1` is a proxy only for "the scp_qchg platform init ran (at
  least through `one_time_init`)".** The IRQ setup is the *next* call in the
  same init, 10 bytes later; the line does not prove the IRQ setup itself ran.
- `battmngr_plat_irq_scpqchg_qbg_r1_irq_setup` @0x6004e260 loops the static
  descriptor table at `0x60248dc0` (stride `0x24`, ≤ 0x10 entries) through
  wrapper `0x60083a50`, which routes by index byte: 0 → register `0x60083460`,
  1 → EMIT @0x60083f60 (event id from the descriptor), ≥ 2 → return `0x202`.
  Its success log is `Setting up interrupt for IRQ_INDEX=%d succeeded`
  (format @0x601e9dcc, ULog-gated, tag `battmngr_plat_irq_scpqchg_qbg_r1.c`) —
  **that** line, if seen in a drain, is the marker that the IRQ arming ran.
- **Event 0x25 is not armed here.** The 9 event-0x25 subscriber
  registrations (via `0x60084740`, see
  [`event-0x25-subscribers.txt`](../logs/adsp-re/event-0x25-subscribers.txt))
  are in the individual module inits, not in `irq_setup`.
- The earlier wording "the `otg enable: 1` line is the proxy for 'did the
  scp_qchg HW init (and thus the event-0x25 trigger) run'" is **superseded**:
  it proves the init ran, not the event-0x25 arming, and its *absence* is a
  ULog-gate artifact like any other log line.

**Impact on the enum-only test**
([INITRAMFS_CHANGES.md](INITRAMFS_CHANGES.md#next-step-the-enum-only-test)):
the `FAIL-NO-DETECTION` branch (no `PartnerType=` line) must be read as
"detection produced no *logged* result" — distinguish *functional* miss (SM
stuck + `ncp_stby`, the dbg49 fingerprint) from *suppressed log* (tag/mask not
enabled in the capture). The decision rule branches 1 and 2 in
[INITRAMFS_CHANGES.md](INITRAMFS_CHANGES.md#decision-rule) and the
fingerprint table in [ADSP_ULOG.md](ADSP_ULOG.md) are updated accordingly.

## `charger_detection_event_handler` and the skip-while-sourcing gate (2026-11-10)

The CC-edge-driven re-detection path (the second route in the
[final answer](#final-answer-to-who-pulls-the-charger-type)) is now fully
decoded, and the dbgB `FAIL-NO-CLASSIFY` fingerprint
([run result](INITRAMFS_CHANGES.md#dbgB-run-result-2026-11-09--fail-no-classify))
is explained in code: **in the source role the handler deliberately skips the
USB charging-type classification and writes no property at all.**

### The handler @0x6014eab0 (tag `charger_detection_event_handler` @0x6022ba2c)

Source file (from the 2nd string copy): `charger_detection.c`.

```
entry (once, before the input loop):
  -0x18 = 0x6016e900()                     # getter-ctx singleton
  -0x28 = 0x60156e80()                     # input-ctx singleton
  -0x2c = 0x60148250()                     # main ctx
  PmHw_GetChargerPMICInfo(&-0x21, &-0x22, &-0x23)        # 0x6008dbd0
  if (-0x21 <= 0xa)
      PmSchgTypec_GetConnectionStatus(-0x21, &-0x20)     # 0x60093780
  status = 0                                # -0x12, halfword

for (in = 0; in < memw(0x60334b58); in++):  # per-input loop
    if (in > 3) break
    battmngr_platform_is_otg_enabled(&-0x1f)             # 0x6002db20
        # fail → log "get otg sts failed" (0x6022b9d6), exit with status

    if (in == 0 && -0x20 == 6 && -0x1f == 1) {          # *** the skip gate ***
        w = ssdev_typec_get_status(in)                   # 0x601580b0, byte 0 of 7
        b = ssdev_typec_get_partner_type(in)             # 0x601581e0
        if (w == 0 || b == 0 || b == 1) {
            log "skip checking usb charging type
                 while usb is sourcing"                  # 0x6022ba9f, ULog-gated
            continue                                     # no classification,
                                                         # no property write
        } else {
            log "reset charger partner, typec_partner:%d"  # 0x6022ba4c
            re-fetch otg status (0x60156860 / 0x60156760)
            → fall through to the main path
        }
    }

    # main path (0x6014ee74)
    charger-present flag → -0x1d (0x60156860 / 0x60156760, status)
    log "Input[%d] bPlugIn=%d"                              # 0x6022bbae
    if (flag == 0)  0x6014f7e0()                            # no-charger path
    else            0x6014f3d0()                            # detection:
        #   → charger_detection_inital_detection 0x60152970 [sic]
        #   → evaluate_typec_charger 0x60150d50 (the PartnerType= line)
    0x6014fd90()   # evaluate; fail → "evaluation failed" 0x6022bbee
    if (flag && memb(0x60334bad)) 0x60194380(in, 0)
    0x6014fea0()   # charger update; fail → "charger update failed" 0x6022bc43
```

All log sites are ULog-gated like everything else; the skip-gate line was
demonstrably emitted in the dbgB capture (tag enabled), so its presence in a
drain is functional, not a logging artifact.

### The skip-gate inputs, named (from their own ULog tags/fmts)

| vaddr | name (ULog tag) | role in the handler |
|---|---|---|
| 0x6008dbd0 | `PmHw_GetChargerPMICInfo` (tag @0x601fb5ce; fmts 0x601fb58c / 0x601fb5e6 "No Charger PMICs found") | scans the 14-entry PMIC table @0x603252c0 (8 B/entry, `e = 0..0xd`); returns the first entry whose byte+2 type code ∈ {0x20, 0x29, 0x2e, 0x3c, 0x44, 0x47, 0x4c}; outputs: index → -0x21, byte+8 → -0x22, byte+2 → -0x23; NULL args → 0x202, no match → 0x201 |
| 0x60093780 | `PmSchgTypec_GetConnectionStatus` (tag @0x601fd762; fmts 0x601fd718 / 0x601fd782 "Status = 0x%X") | per-PMIC fn-ptr dispatch: `fn = *(0x60325558 + idx*0xc)`, `callr fn(&out)`; `idx > 0xa` → 0x202, NULL fn → 0x201. Writes **-0x20 = the charger PMIC's TypeC connection status** |
| 0x6002db20 | `battmngr_platform_is_otg_enabled` (tag @0x601def0d; fmt 0x601deec2 "Platform Get otg status func pointer is NULL") | `callr memw(0x602805a4)(arg0)`; NULL fn → 0x206 + ULog. Per-input OTG status → -0x1f |
| 0x601580b0 | `ssdev_typec_get_status` (tag @0x6022d29a, fmt "[kevin-500]") | `in > 3` → 0x202; `ptr = memw(0x60256ef8 + in*0x14)`; NULL → 0x202; 7-byte memcpy from `ptr+0x7d` (the gate uses byte 0) |
| 0x601581e0 | `ssdev_typec_get_partner_type` (tag @0x6022d2c8, fmt "[kevin-522]") | same guards; `*out = memub(ptr+0x84)` |

The `ssdev_typec_*` family (`…_pd_req_current`, `…_pd_get_pdos`,
`…_pd_get_max_votlage` [sic], `…_pd_get_min` [sic], …) is the Type-C port
state block; the per-port state pointers live in the table at **0x60256ef8**
(stride 0x14, ≤ 4 ports) — the same table `evaluate_typec_charger` uses.

### The model, and the mapping to the measured environments

`-0x20` is the **TypeC connection status** of the charger PMIC; the value
**6** is the *sourcing* state (the log message says it itself). The full
skip condition:

```
in == 0
&& PmSchgTypec_GetConnectionStatus(charger_pmic) == 6      # "usb is sourcing"
&& battmngr_platform_is_otg_enabled(0) == 1
&& (typec_status[0] == 0 || typec_partner_type ∈ {0, 1})
→ log + continue: no classification, no USB_TYPE property write
```

| environment | FPM (measured) | conn status | skip gate | AP `usb_type` |
|---|---|---|---|---|
| dbgB (pre-plug stick, **source role**) | `PowerDirection=1`, `ConnectPartnerType=2`, USB=1 | 6 (sourcing) | **taken** @17.67 | `Unknown` (0) |
| full-system success (PD dock, **sink role**) | `PowerDirection=0`, PartnerType=15, 9 V / 2440 mA | ≠ 6 | not taken | `SDP` (1) |

Consequences:

- In the plain-USB-stick scenario (host/source role — exactly the USB-boot
  scenario) the firmware **intentionally never classifies the USB charging
  type**: a port that is sourcing has no charger to classify. The AP's
  `usb_type` therefore stays at its default (`Unknown`) in precisely the
  scenario USB boot needs.
- **In the source role the skip branch itself is the write-gate for the
  USB_TYPE(6) glink property** — there is no other gate upstream of it. This
  matches the upstream sm8350-class observation that `USB_TYPE` is "stale":
  here it is not even stale, it is never written in the source role.
- It also explains the dbgB discrepancy `typec_detect_partner:
  TypeCPartnerType=0` @5.35 vs the FPM's `ConnectPartnerType=2` @7.41: two
  different subsystems (ssdev Type-C block vs FPM connector status); the skip
  gate consumes the former (byte ∈ {0,1} → skip).

### Fix implications

1. **AP-side (practical):** do not gate the USB-boot decision on `usb_type`
   in the source role — treat `Unknown` + VBUS present + partner as bootable.
   The host controller does not need a charger type to enumerate the stick
   (the full system enumerates with the UCSI core active; the wedge is about
   the charger SM, not xHCI).
2. **Firmware-side:** bypassing the skip gate requires patching the signed
   `adsp.mbn` — not realistic.
3. **USB_ADAP_TYPE(7):** the upstream sm8350-class patch (v2, Reviewed-by
   Qualcomm — full text and measurements in
   [External corroboration](#external-corroboration-web-search-2026-11-10))
   says `USB_ADAP_TYPE` is the *live* adapter-type property there (PC 1/1,
   5 V-PD dock 1/6, 65 W PPS 1/8) — but our 7.2.6 does not consume it
   (absent from `sm8350_usb_prop_map`; a prop-7 push would hit
   `dev_warn("unknown property %#x")`, `qcom_battmgr.c:1521`). The earlier
   open question ("does *this* firmware write it in the source role?") is
   now closed by RE: the classifier writes the *same value* to both the
   USB_TYPE (`ctx+0x72c`) and USB_ADAP_TYPE (`ctx+0x730`) slots in the sink
   role, and in the source role the skip gate suppresses writes to *both* —
   see [the override-table stride-4 correction](#the-override-table-stride-4-correction)
   and [where the pre-plug `usb_type=0` comes from](#where-the-pre-plug-usb_type0-comes-from).

### Correction: earlier recorded string vaddrs were off by ~0x140 (2026-11-10)

The string-dump script used in earlier sessions had a loop bug (the `lo+i`
offset was applied to a shrinking slice while the base stayed fixed), so all
string vaddrs recorded before 2026-11-10 were shifted by ~0x140. The values
in this section were re-derived from the `##0x…` immediates in the
disassembly (authoritative) and verified byte-by-byte against the firmware.
Verified first-copy fmt vaddrs (the 2nd copy @0x60343000 carries the same
texts with a `<file>.c:` prefix, which is how the source file names above
were read):

| string (content) | 1st copy | 2nd copy |
|---|---|---|
| `skip checking usb charging type while usb is sourcing` | 0x6022ba9f | 0x60385204 |
| `reset charger partner, typec_partner:%d` | 0x6022ba4c | 0x603851a0 |
| `should disable WLS charing when USB charger in` [sic] | 0x6022bb54 | 0x603852dc |
| `Input[%d] bPlugIn=%d` (event_handler) | 0x6022bbae | 0x60385348 |
| `Input[%d] bPlugIn=%d, Module type=%d` (inital_detection [sic]) | 0x6022c392 | 0x60385e70 |
| `Input[%d] detection failed, status=0x%X` | 0x6022bb00 | 0x60385278 |
| `Input[%d] evaluation failed, status=0x%X` | 0x6022bbee | 0x60385398 |
| `Input[%d] get otg sts failed, status=0x%X` | 0x6022b9d6 | 0x60385138 |
| `Input[%d] charger update failed, status=0x%X` | 0x6022bc43 | 0x60385400 |
| `icm_ncp_stby_init: keeps in icm_ncp_stby utill [sic] charger_type updated` | 0x60238d14 | 0x6038e6c4 |
| `icm_ncp_stby_main: keeps in icm_ncp_stby utill [sic] charger_type updated` | 0x60238da2 | 0x6038e75c |
| `ncp_stby_db - chgr_stat=%x, soc=%d` | 0x60238e6c | 0x6038e82c |
| `wlstx enable: %d` | 0x601e6b2f | 0x6034f1e4 |
| `otg enable: %d` | 0x601e6bb7 | 0x6034f254 |
| `wls tx source = %d` | 0x601e6c07 | 0x6034f2c0 |
| `otg source = %d` | 0x601e6ce5 | 0x6034f3d8 |
| `IDT in wrong state, disabling wls tx…` | 0x601e6c5b | 0x6034f330 |
| `OTG source not available` | 0x601e6d36 | 0x6034f4b0 |

Note: in this string region 3–4 bytes of data words are sometimes packed
immediately in front of a string **without a NUL separator** (e.g.
`c4 e6 38 60` precedes the init-keeps fmt at 0x60238d10+4; `58 55 36 60`
precede the `PmSchgTypec` fmt at 0x601fd714+4). A walk-back-to-NUL string
dump therefore lands *before* the real string start; the vaddr cited here is
always the one the disassembly references.

## The pmic_glink RX path: dispatcher, opcode map, USB GET/SET (2026-11-10)

The full AP → glink → ADSP property path is now decoded end-to-end: every
`usb_type` the AP logs is the value of one word in a 4-byte-stride
"override table" inside the battmgr context, and the only writer of the
USB_TYPE slot in the source role is — nothing (the skip gate).

### RX dispatcher @0x60089bc0

```
allocframe(#0xf0); status = 0
loop:
  0x6008b840(&msg, &aux)                    # fetch next glink message
  if (!msg || !aux) break
  if (memw(msg+0x0) != 0x800a)              # owner PMIC_GLINK_OWNER_BATTMGR
      → 0x6008b1a8                          # other owners (0x800b / 0x800c)
                                            # dispatch on their own opcodes;
                                            # anything else → drop
  opcode = memw(msg+0x8)
  if (opcode > 0x47) → 0x6008b1a0           # default stub: free msg, loop
  fn = memw(opcode << 2 + 0x601fa8fc)       # JT, 0x48 entries
  jumpr fn
epilogue 0x6008b828: 0x600845a0(msg)        # free the message
              jump 0x60089bf8               # ← back to the fetch (drain loop)
```

All JT handlers converge on the same epilogue, so a single glink callback
drains a queue of messages.

### Opcode map (JT @0x601fa8fc, 0x48 words, idx = raw opcode)

| opcode | AP name (our 7.2.6 `qcom_battmgr.c`) | fw handler |
|---|---|---|
| 0x00 | (hello/version) | 0x60089c6c — responds `{0x800a, 1, 0, …}`, payload filled by 0x60176260 |
| 0x04 | `BATTMGR_REQUEST_NOTIFICATION` | 0x60089f50 — subscribes to notifications |
| 0x07 | `BATTMGR_NOTIFICATION` (fw→AP pushes only) | 0x6008b1a0 (stub) |
| 0x10 | — | 0x6008a110 |
| 0x30 | `BATTMGR_BAT_PROPERTY_GET` | 0x6008a3c4 |
| 0x31 | `BATTMGR_BAT_PROPERTY_SET` | 0x6008a528 |
| **0x32** | **`BATTMGR_USB_PROPERTY_GET`** | **0x6008a6f8** |
| **0x33** | **`BATTMGR_USB_PROPERTY_SET`** | **0x6008a80c** |
| 0x34 | `BATTMGR_WLS_PROPERTY_GET` | 0x6008a908 |
| 0x35 | `BATTMGR_WLS_PROPERTY_SET` | 0x6008aa1c |
| 0x36 | (none — our 7.2.6 numbers `BATTMGR_CHG_CTRL_LIMIT_EN` as **0x48**) | 0x6008a624 → `0x60178b20(memw(msg+0xc))` |
| rest | — | 0x6008b1a0 (silent drop) |

Numbering footnote: our 7.2.6 sends `BATTMGR_CHG_CTRL_LIMIT_EN = 0x48`
(`qcom_battmgr.c:101`) at probe, but the firmware's dispatcher rejects
`opcode > 0x47` (0x60089c54–0x60089c58) → the enable request is **silently
dropped** by this firmware; the fw's 0x36 entry matches the *old* consecutive
numbering (0x30..0x36). Side observation, not needed for USB boot.

### Message layout (verified on both sides of the wire)

```
request (AP → ADSP):
  +0x00  owner   = 0x800a
  +0x04  type
  +0x08  opcode
  +0x10  property  (byte; USB props 0..9, fw guard ≤ 0x13)
  +0x14  value / out-pointer

response (ADSP → AP, 0x18 B via 0x60084420(0x18)):
  +0x00  0x800a
  +0x04  1
  +0x08  opcode (0x32 / 0x33 / …)
  +0x0c  property (echo)
  +0x10  value
  +0x14  status (halfword; 0 = ok, 0x202 = bad arg)
  sent via 0x600895d0(0x603250d0, 0, 0x18, buf)
```

### USB GET: RX 0x6008a6f8 → handler 0x60177dc0 → wrapper 0x6002cc90 → getter 0x600452c0

- **RX 0x6008a6f8:** `prop = memub(msg+0x10)`, `out = &stack_word`
  (zero-init) → `call 0x60177dc0(prop, out)`; then builds the 0x18 response
  (echo prop @0xc, the word @0x10, status @0x14) and sends it.
- **Handler 0x60177dc0** (allocframe 0x10): `out == NULL` → 0x202;
  `prop > 0x13` → 0x202; else `call 0x6002cc90(prop, out)`, status = ret.
- **Wrapper 0x6002cc90:** `fn = memw(0x60280570)`; NULL → 0x202; `callr
  fn(prop, out)`.
- **Getter 0x600452c0** = the real USB property getter
  (`battmngr_plat_scpqchg_qbg_r1_get_usb_power_supply_properties`; name from
  its own ULog tag). Stack defaults: `0x4c4b40` (5,000,000 µV), `0x7a120`
  (500,000), `0x186a0` (100,000). Per-property **live read** (refreshes the
  override-table slot *before* the epilogue) for exactly:
  prop 1 → 0x718 @0x600453a4, prop 3 → 0x720 @0x6004540c, prop 5 → 0x728
  @0x60045468, prop 10 → 0x73c @0x600454c8, prop 12 → 0x744 @0x600455c0,
  prop 13 → 0x748 @0x600456b0, prop 14 → 0x74c @0x60045708, prop 17 → 0x758
  @0x60045840, prop 18 → 0x75c @0x600457d0, prop 19 → 0x760 @0x60045808.
  **There is no live-read case for 6 or 7** — those are answered purely from
  the table.
- **Epilogue 0x6004586c–0x600458e0:**

```
ctx = memw(0x60256ee8)                      # the battmgr context
if (memb(ctx+0x3a8) == 8 || == 9)
    memw(ctx+0x714) = 0                     # clear slot 0 (ONLINE)
*out = memw(ctx + prop*4 + 0x714)           # addasl(#0x2) = (prop<<2)
status = 0
```

### USB SET: RX 0x6008a80c → handler 0x60177e30

- **RX 0x6008a80c:** `prop = memub(msg+0x10)`, `value = memw(msg+0x14)` →
  `call 0x60177e30(prop, value)`; same 0x18 response shape (op 0x33).
- **Handler 0x60177e30** (allocframe 0x20): locals `-0x3`=prop, `-0x8`=value,
  `-0xa`=status, plus per-prop scratch words. `prop > 0x13` → 0x202. Then:

```
# generic table write (0x60177e9c–0x60177ea0):
ctx = memw(0x60256ee8)
memw(ctx + prop*4 + 0x714) = value          # addasl(#0x2)

# side effects (each ULog-gated like everything else):
prop 5 (INPUT_CURR_LIMIT):
    if (value != -1) value = (value * 0x10624dd3) >> 6   # 0x60177ec8–0x60177edc
    status = 0x6002cba0(value)
prop 8 (MOISTURE_DET_EN):
    status = 0x6002da30(value != 0)
prop 0xf:
    status = 0x601786d0(0, 7, 0x2646, 1, &local)
prop 0x11 / 0x12 / 0x13:
    status = 0x60153910(0xb / 0xd / 0xc, &value)
# *** no special case for 6 / 7 — the table write IS the whole story ***
```

### Slot map (the registered property getters)

| slot | fn | role |
|---|---|---|
| 0x60280570 | 0x600452c0 | USB GET (op 0x32) — via wrapper 0x6002cc90 |
| 0x60280574 | 0x600458f0 | WLS GET (op 0x34) — via wrapper 0x6002cd90 |
| 0x60280578 | 0x6003ab00 | — via wrapper 0x6002ce90 |

Related: `battmngr_plat_scpqchg_qbg_r1_set_usb_icl` @0x600449a0 (ULog tag
@0x601e3b4a; fmt `Debug: %s: battmngr_plat_schpqchg_qbg_r1_set_usb_icl::usb
type is %d, IclInMa:%d` @0x601e3af9 — note the `schpqchg` typo in the fmt)
reads the "usb type" from **ctx+0x730** (0x60044a04, 0x60044a2c, and five
more sites through 0x60044b10, branching on {1,3} / {6,7,8}).

## The override table: stride-4 correction

**Correction to earlier sessions:** the override table is base
`ctx+0x714` with **stride 4** (one 32-bit word per property), *not* stride 2.
Hexagon `addasl(rd, rs, #0x2)` computes `rd + (rs << 2)` = `rd + rs*4`; the
SET handler's write (`r2 = addasl(ctx, prop, #0x2); memw(r2+0x714) = value`)
and the GET epilogue's read (`r2 = addasl(ctx, prop, #0x2); *out =
memw(r2+0x714)`) both use `#0x2`.

Proof, independent of the two dynamic sites: the getter's live-read cache
always writes `0x714 + p*4` —

| prop | slot | store site |
|---|---|---|
| 1 (VOLT_NOW) | 0x718 | 0x600453a4 |
| 3 (CURR_NOW) | 0x720 | 0x6004540c |
| 5 (INPUT_CURR_LIMIT) | 0x728 | 0x60045468 |
| 10 | 0x73c | 0x600454c8 |
| 12 | 0x744 | 0x600455c0 |
| 13 | 0x748 | 0x600456b0 |
| 14 | 0x74c | 0x60045708 |
| 17 | 0x758 | 0x60045840 |
| 18 | 0x75c | 0x600457d0 |
| 19 | 0x760 | 0x60045808 |

ten points, all exactly `0x714 + p*4`; the successful boot really does read
these props, so the epilogue must read the same slots. Consequence:

- **prop 6 (USB_TYPE) = `ctx+0x72c`**
- **prop 7 (USB_ADAP_TYPE) = `ctx+0x730`**

(An earlier session concluded "prop 7 is dead" by scanning for `+#0x722` —
the stride-2 address — which is why it found nothing. The correct slot is
`+#0x730`, and it is *actively written*.)

### "Prop 7 is not dead" — but the AP never reads it

The charger-type classifier writes the **same value** into both 0x72c and
0x730. Write sites (all verified in the disasm):

```
0x6002f184 / 0x6002f18c   (defaults block, value 0 — see below)
0x6003d4c4 / 0x6003d4cc   (same r3 to both, + 0x740, 0x764)
0x60042bd8 / 0x60042be0   (r3 = 0 — the "reset to Unknown" site, + 0x740)
0x6004f1f4                (0x72c)
0x60056420                (0x72c)
0x60058b5c / 0x60058b7c
0x60103694                (0x72c ← ##0x60103b50)
0x6018d428                (0x72c)
0x601907f0 / 0x60190d2c / 0x60191274
```

So on the *firmware* side prop 7 is alive (`set_usb_icl` reads it, the
classifier feeds it). But the AP side of our 7.2.6 never requests prop 7:
`sm8350_usb_prop_map` (`qcom_battmgr.c:971–979`) maps
`POWER_SUPPLY_PROP_USB_TYPE` to `USB_TYPE` (6) only, and the rx-callback
switch (`qcom_battmgr.c:1516–1518`) only consumes a pushed prop-6 value.
For our purposes prop 7 remains irrelevant; the fix is unchanged.

## Where the pre-plug `usb_type=0` comes from

### The no-charger / defaults block

Inside the init function @0x6002eb30 (allocframe 0x10; identity and callers
still open — see Open items), the override table is filled with the
no-charger defaults (0x6002f134–0x6002f1c0; `r3 = 0`, `r4 = 0x4c4b40`,
later `r4 = -1`):

| slot | prop | value | site |
|---|---|---|---|
| 0x734, 0x738 | (10/11-range) | 0 | 0x6002f140/0x6002f148 |
| 0x718 (VOLT_NOW), 0x71c (VOLT_MAX) | 1, 2 | **0x4c4b40 = 5,000,000 µV** | 0x6002f158/0x6002f160 |
| 0x720 (CURR_NOW), 0x724 (CURR_MAX) | 3, 4 | 0 | 0x6002f168/0x6002f170 |
| 0x728 (INPUT_CURR_LIMIT) | 5 | **-1** | 0x6002f17c |
| **0x72c (USB_TYPE)** | **6** | **0 (Unknown)** | **0x6002f184** |
| **0x730 (USB_ADAP_TYPE)** | **7** | **0 (Unknown)** | **0x6002f18c** |
| 0x740, 0x73c (prop 10), 0x748 (13), 0x74c (14), 0x744 (12) | — | 0 | 0x6002f194…0x6002f1b4 |
| 0x750 (prop 15) | 15 | 1 | 0x6002f1c0 |

### The bulk ctx-init @0x6017b080

The large context initializer (allocframe 0x468) also writes the whole
override table in one block (0x6017ceac–0x6017cf0c):

```
0x708, 0x70c, 0x714 (ONLINE), 0x718, 0x71c, 0x72c, 0x730, 0x734  = r6
0x720, 0x724, 0x728                                            = r9
0x710                                                          = r12
r9 = 0x5f5e100 (100,000,000)      @0x6017c6ac
r6 = memw(r30-0x45c)             @0x6017b64c   (stack — value PENDING)
```

### The root-cause chain, now closed in code

```
boot → ctx init: USB_TYPE(0x72c) = 0 (defaults block)
       → source role (USB stick, host): charger_detection_event_handler
         skip gate taken → no classification, no write of 0x72c
       → AP GET 6 → epilogue reads 0x72c → 0
       → AP usb_type = (Unknown) → our boot decision fails

sink role (PD dock): classifier runs → writes type to 0x72c AND 0x730
       → AP GET 6 → SDP(1) / PD(6) / … → boot decision passes
```

The dbgB fingerprint (`usb_type=(Unknown) online=0` in every poll,
`skip checking usb charging type while usb is sourcing` @17.67) is exactly
this chain. The pre-plug value is not "stale" — it is the *initialized
default*, and nothing in the source role ever changes it.

## External corroboration (web search 2026-11-10)

Independent of the RE, the same property semantics are now documented in
public kernel sources (found 2026-11-10):

### 1. Upstream LKML: "qcom_battmgr: report the USB type from USB_ADAP_TYPE" (Oct 2026)

- v1: `patchew.org/linux/20261007123932.1664-1-26rote@gmail.com/`;
  v2: `20261012130053.442` (LKML thread 2026-10-12). Author: Joonhoe Kim;
  **Reviewed-by: Kamal Wadhwa (Qualcomm)** — "Add fixes tag, with that I
  think it should be good to go."
- Patch text (v1): *"On SM8350 and SM8550 class firmware the USB power
  supply reads its usb_type from the USB_TYPE property. On a Kaanapali
  (SM8850) tablet that property is **1 (SDP) whatever is plugged in**, while
  USB_ADAP_TYPE reports the adapter, using the same numbering as
  POWER_SUPPLY_USB_TYPE_\**." Measured on a Lenovo Legion Tab Y700 gen 5
  (`qcom,kaanapali-pmic-glink`, the SM8550 path):

  | adapter | USB_TYPE (6) | USB_ADAP_TYPE (7) |
  |---|---|---|
  | PC port | 1 | 1 (SDP) |
  | USB-C dock, 5 V PD | 1 | 6 (PD) |
  | 65 W PPS charger | 1 | 8 (PD_PPS) |

- Cover-letter facts: *"The downstream qti_battery_charger in SM8350,
  SM8450, SM8550, SM8650 and SM7635 vendor kernels uses the same property
  ids, maps USB_ADAP_TYPE to POWER_SUPPLY_PROP_USB_TYPE and reads it on
  every USB change, so the firmware of this family should implement it.
  Like downstream, values outside the enum (QC chargers, 0x80 and up there)
  are passed through."* And: *"Once, when the USB gadget did not connect to
  the PC after plugging, USB_ADAP_TYPE read 4 (ACA) until the cable was
  plugged again; when the gadget connects, the PC port reads 1 (SDP)."*
- The same author's second patch, "qcom_battmgr: Allow setting the USB input
  current limit": *"The SM8350 class USB power supply reports
  input_current_limit, but does not allow writing it, although the firmware
  accepts BATTMGR_USB_PROPERTY_SET for USB_INPUT_CURR_LIMIT"* … *"With a USB
  PD charger the firmware keeps its own limit and the written value is not
  reflected."*
- Kamal Wadhwa's multi-port series (Aug 2026,
  `20260806-b4-battmgr-multiport-usb-v2`) makes the same USB_TYPE→
  USB_ADAP_TYPE switch for X1E80100 (new `x1e80100_usb_prop_map`), leaving
  the shared SM8350/SM8550 map on USB_TYPE — which is what this patch fixes.

### 2. oneplus-pja110-mainline (SM8450, kernel 6.14, debugfs `raw_get`/`raw_set`)

`docs/fastcharge-fix-20261023.md` in that repo documents a real-device
investigation that hits the same walls:

- **Bug 1 — same as the upstream patch:** their `usb_type` read `USB_TYPE`
  (constantly 1/SDP); switching the map entry to `USB_ADAP_TYPE` made
  `usb_type` report `[PD_PPS]` correctly.
- **Bug 2 — the sm8350 rx-callback has no cases for the SET responses
  (0x31/0x33):** they fall into `default:` → `dev_warn("unknown message
  0x33")`. Their fix: add `case BATTMGR_BAT_PROPERTY_SET: case
  BATTMGR_USB_PROPERTY_SET: battmgr->error = 0; break;`.
  **Our 7.2.6 has the identical gap** (the callback switch at
  `qcom_battmgr.c:1559–1564` covers `BATTMGR_REQUEST_NOTIFICATION` /
  `BATTMGR_CHG_CTRL_LIMIT_EN` and the GET opcodes only).
- **Bug 3 — no `set_property` on the USB power supply.**
- **The firmware does not ack SET:** `raw_set` (0x31) returns `-110
  (ETIMEDOUT)` — the doc treats that as **normal success** (`-104
  ECONNRESET` is the real failure: ADSP not ready / channel down).
- Writing `USB_INPUT_CURR_LIMIT` (prop 5) with a PD charger: the firmware
  keeps its own limit (matches our SET decode — the prop-5 side-effect path
  exists, but whether the charger SM adopts the value is its call).
- **The limit can be reset by the ADSP on re-plug** → they re-issue via a
  udev rule on `power_supply change` + `POWER_SUPPLY_ONLINE==1`.
- The lever that actually worked for them: `BATTMGR_BAT_PROPERTY_SET (0x31)`
  + `BATT_CHG_CTRL_LIM (10)` = 3,000,000 µA → USB input 460 mA → 2809 mA
  (12.5 W), immediately.

### Comparison: external measurements vs this RE

| fact | external (Kaanapali / SM8450 write-ups) | this RP6 firmware (RE) |
|---|---|---|
| USB_TYPE (prop 6), sink role | **constant 1 (SDP)** | **live**: classifier writes the type to 0x72c (SDP on the PD-dock success) |
| USB_ADAP_TYPE (prop 7) | live adapter type (1/6/8); 4 (ACA) transiently in a failed source attach | **alive on the fw side** (classifier writes the same value to 0x730; `set_usb_icl` reads it) but the AP (7.2.6) never requests it |
| source role (host/PC) | ADAP_TYPE = 1 (SDP) when the gadget connects; 4 (ACA) once when it didn't | **never written**: skip gate suppresses classification → stays 0 (defaults) |
| SET 0x31/0x33 ack | no ack (ETIMEDOUT = success) | fw builds a normal 0x18 response for 0x33 (0x6008a80c); our 7.2.6 callback ignores it ("unknown message 0x33") |
| prop 5 write on PD | not reflected (fw keeps its own limit) | side-effect path present (0x60177eb8); adoption decided in the charger SM |

### Implications for our fix

1. **The AP-side fix is corroborated and sharpened.** In the source role,
   prop 6 is unreliable in *both* directions across this firmware family:
   stuck at SDP on the Kaanapali/SM8450 firmwares, never written (0) on ours.
   The boot decision must not gate on `usb_type` when the port is sourcing —
   use VBUS presence + partner/role state instead. Upstream's
   USB_TYPE→USB_ADAP_TYPE remap does **not** by itself fix the source role
   on our firmware (ADAP_TYPE is also 0 there).
2. If we ever send SET (0x33) from an AP-side debug hook: the fw will
   perform the table write + side effect, but our 7.2.6 callback will log
   "unknown message 0x33" and time out on the ack — treat ETIMEDOUT as
   success (external experience above).
3. The `CHG_CTRL_LIMIT_EN` numbering mismatch (AP 0x48 vs fw 0x36, guard
   `> 0x47`) means our AP's probe-time enable is silently dropped by this
   firmware. Not needed for USB boot, but it explains why the feature never
   engages.

## Open RE items (as of 2026-11-10)

1. Value of `r6` in the bulk ctx-init 0x6017b080 (it comes from the stack,
   `memw(r30-0x45c)` — trace the store).
2. Callers of the 0x72c/0x730 classifier writers — confirm they sit on the
   charger-detection path under the skip gate.
3. Identity/callers of the defaults fn 0x6002eb30 (boot init vs
   charger-disconnect event).
4. T-model: resolve the args of 0x601ccb10 at its call sites.
