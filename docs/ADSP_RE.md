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

## Trigger table (consolidated)

| # | Trigger | Source | Status |
|---|---|---|---|
| 1 | fresh CC edge (attach) | HW (physical) | OUT — cold-plug = plugged before power-on; cannot re-plug |
| 2 | USB suspend→resume | AP PM → dpm_usbc.c @0x600d1dc0 → `SetRerunApsd(7)` | DEAD — tied to PDR/SSR (ADSP restart; run V) |
| 3 | charger-detection SM event | event 0x25 broadcast (HW CC IRQ **or** AP glink/UCSI) | **OPEN** — sources pinned (HW IRQ setup + glink RX); ADSP-side flag gates eliminated (ULog-only) |
| 4 | periodic/autonomous | `SetAiclPeriodicRerun` / `SetAiclRerunTimeCfg` / `set_hw_aicl_rerun` | DEAD CODE (0 refs) |

## Cross-firmware comparison

The PPM FDT payload (8315 B @MBN+208) is **byte-identical across all 7 sm8550
variants** (md5 `f7c72c64f8f7e0a75e5791ed973ea766`) — there is no "known-good" config
to copy. The MBN containers themselves differ (per-board signing), and the newer
SM8650 (kaanapali) and 8380 firmwares carry the same `apsd-rerun-cfg = 0`. Full md5
registry in [`cross-firmware-compare.txt`](../logs/adsp-re/cross-firmware-compare.txt).

## Remaining hypotheses and next steps

With the ADSP-side flag wall removed, the candidates narrow to:

1. **AP-side measurement (primary):** determine what the AP sends over glink in the
   initramfs environment vs a full system — charger-type intents, ULOG config
   type-0x19, battmgr notifications. The ADSP side is proven unconditional, so any
   difference in behavior must originate on the AP side (or in the absence of an AP
   event that would normally re-trigger detection).
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
