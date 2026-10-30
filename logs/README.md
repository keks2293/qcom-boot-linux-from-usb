# Logs

Raw/near-raw evidence from initramfs diagnostic runs (screen/ULOG captures)
and from the PPM/ADSP firmware reverse engineering. These are small excerpts
kept as proof for key claims.

## Firmware RE evidence: [`adsp-re/`](adsp-re/)

Disassembly excerpts and xref dumps from `adsp.mbn` (rp6) and `adsp_dtb.mbn`.
Every claim in [`../docs/ADSP_RE.md`](../docs/ADSP_RE.md) /
[`../docs/ADSP_CONFIG.md`](../docs/ADSP_CONFIG.md) has a file here. Method:
xref = `grep '##0x<vaddr>' text_all.txt`; writes =
`memw/memb/memh/memd(##0xADDR) = …`. Tools in
[`../scripts/adsp-re/`](../scripts/adsp-re/).

| File | What it proves |
|---|---|
| `elfmap-adsp-mbn.txt` | PHDR map; PT_LOAD#19 file↔vaddr mapping |
| `ppm-fdt-rp6.dts` | dtc dump of the PPM FDT payload (8315 B @MBN+208) — 216 properties |
| `strings-xref-sample.txt` | string→code xref method + the glink/ULog/BattMngr name-string xrefs |
| `func-icm-ncp-stby-main.txt` | the wedge state: event dispatcher, state gate `==2`, jump table (event 24 = tick), WARN log xref + its ULog gate |
| `func-setrerun-apsd-600978e0.txt` | `PmSchgUsb_SetRerunApsd` full 128 L: functional path has NO flag gate; the ULog globals gate only the two error logs |
| `func-adsp-rerun-virtual-6015b6a0.txt` | "adsp rerun" virtual action (fn-ptr `field_0x38`, NULL→0x202) |
| `event-0x25-subscribers.txt` | the 9 subscribers of the port/CC broadcast event 0x25 |
| `func-event-bus-register-60084740.txt` | event-bus registration fn (handler/event/ctx/pool args, sentinel, registry globals) |
| `func-emit-60083f60.txt` | the EMIT (broadcast source) prologue + gate |
| `func-emit-callback-600a5be0.txt` | the isolated emit callback |
| `func-arming-tcc-init-6010ac50.txt` | `PmicTccPlatform_Init`: PMIC-ID gate, method-table fill; 0 direct callers (runtime pointer table) |
| `call-sites-trigger-map.txt` | every trigger path into charger detection / APSD rerun (one caller per level; glink RX entry; dead-code periodic rerun) |
| `func-glink-rx-60088cd0.txt` | glink intent RX handler: processing UNCONDITIONAL (QDI queue intent), ULog gates only the logs |
| `func-ulog-init-60080dc0.txt` | ULog client init ("BATTMAN ULog"): sets mask `0x3FFFFFFF`/level 3; setter fns; sole caller = `BattMngr_init` (ADSP boot) |
| `func-ulog-rx-processor-type19-600872f0.txt` | `pmic_glink_ulog_process_rx_data`: AP sets ULog mask/level over glink (type-0x19) |
| `func-battmngr-init-6002ad50.txt` | `BattMngr_init` (183 L) — the sole caller of the ULog client init |
| `ulog-flag-globals-write-sites.txt` | **the headline**: full write-site map of the three "flag" globals = ULog logging controls; the log-gate pattern; H1 refuted |
| `cross-firmware-compare.txt` | md5 registry: FDT payload byte-identical in all 7 sm8550 variants; sm8650/sm8380 comparison; no "fixed" config exists |
| `ppm-ucsi-dispatch-table.txt` | UCSI WRITE dispatcher 0x600d4830 prologue: command dispatch (idx = cmd−2, table 0x6020c29c, commands 0x02..0x13) — the standard UCSI numbers, no vendor renumbering |
| `ppm-doorbell-callers.txt` | **the full enumeration**: exactly 4 callers of `ppm_set_request_to_lpm` 0x600da6d0 = the only PPM commands that ring the PMIC doorbell bit 0x20 (0x03/0x09/0x0b/0x10); the 0x60003094 caller map |
| `func-connector-reset-600d8620.txt` | CONNECTOR_RESET handler in full: port validation (1..4 else 0x202), hard bit 23, reset-state fields, the direct `call 0x600da6d0` (doorbell chain), mailbox op 7 |

## Files

| File | Source | What it proves |
|---|---|---|
| [`dbg31-role-swap-refused.txt`](dbg31-role-swap-refused.txt) | dbg31 (run J) | AP-side role swaps refused by PPM/ADSP: `SET_PDR` -> `-ECOMM` (`UCSI_ERROR_CC_COMMUNICATION_ERR`), `SET_UOR` -> `-ETIMEDOUT`. Proves the UCSI glink channel + the in-kernel UCSI core are **active** in the initramfs env (the PPM answers; the wedge persists anyway). Not a fix. |
| [`dbg32-connector-reset.txt`](dbg32-connector-reset.txt) | dbg32 (run K) | `CONNECTOR_RESET` word `0x00010003` (port 1): rc=0, handler completed including the PMIC doorbell, no effect (no fresh CC event). Word `0x00800003` re-decoded: hard flag + **port 0 = invalid** — the hang was a confounded experiment, not a hard-reset measurement. Not a fix. |
| [`dbg49-adsp-icm-ncp-stby.txt`](dbg49-adsp-icm-ncp-stby.txt) | dbg49 run, ULOG excerpt | ADSP fingerprint: `icm_ncp_stby_main: keeps in icm_ncp_stby until charger type updated`, `chgr_stat`/state info. Points to BC1.2/charger classification blocking the data path (P-06). |
| [`dbg51-rpm-no-suspend.txt`](dbg51-rpm-no-suspend.txt) | dbg51 run | Runtime PM trace showing `rpm_idle` returns `-EAGAIN`/`-EBUSY`, `child_count>=2`, root hubs pinned at `autosuspend_delay_ms=-1000`. Chain cannot enter runtime suspend; L2/runtime-PM class is closed as the cause. |

## Notes

- Full screen photos/captures are not included (binary). See [`docs/RESULTS.md`](../docs/RESULTS.md) for summarized markers.
- These excerpts are intentionally minimal to serve as direct evidence.
