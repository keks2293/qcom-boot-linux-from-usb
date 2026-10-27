# Logs

Raw/near-raw evidence from initramfs diagnostic runs (screen/ULOG captures). These are small excerpts kept as proof for key claims.

## Files

| File | Source | What it proves |
|---|---|---|
| [`dbg31-role-swap-refused.txt`](dbg31-role-swap-refused.txt) | dbg31 (run J, 17 Oct) | AP-side role swaps refused by PPM/ADSP: `SET_PDR` -> `-ECOMM` (`UCSI_ERROR_CC_COMMUNICATION_ERR`), `SET_UOR` -> `-ETIMEDOUT`. All UCSI power/data role swaps are rejected; not a fix. |
| [`dbg32-connector-reset.txt`](dbg32-connector-reset.txt) | dbg32 (run K, 17 Oct) | `CONNECTOR_RESET` is mostly no-op or causes PPM to hang and recover via PDR down/up. Not a fix. |
| [`dbg49-adsp-icm-ncp-stby.txt`](dbg49-adsp-icm-ncp-stby.txt) | dbg24 runs (16 Oct), excerpt | ADSP fingerprint: `icm_ncp_stby_main: keeps in icm_ncp_stby until charger type updated`, `chgr_stat`/state info. Points to BC1.2/charger classification blocking the data path (P-06). |
| [`dbg51-rpm-no-suspend.txt`](dbg51-rpm-no-suspend.txt) | dbg51 (26 Oct) | Runtime PM trace showing `rpm_idle` returns `-EAGAIN`/`-EBUSY`, `child_count>=2`, root hubs pinned at `autosuspend_delay_ms=-1000`. Chain cannot enter runtime suspend; L2/runtime-PM class is closed as the cause. |

## Notes

- Full screen photos/captures are not included (binary). See [`docs/RESULTS.md`](../docs/RESULTS.md) for summarized markers.
- These excerpts are intentionally minimal to serve as direct evidence.
