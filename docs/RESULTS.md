# Results

## dbg50 — Invalid

Image: `KERNEL.ci-5d953ca-dbg50`

- **Harness bug**: PM attributes read/written without `power/` prefix (`runtime_status`, `autosuspend_delay_ms`, `wakeup`)
  - Reads returned empty/ENOENT
  - Writes caused `open(O_CREAT)` in read-only sysfs -> `EACCES`
  - Status never observed, verdict was vacuous
- Side observations: `usb_type=Unknown`, ADSP fingerprint matched previous runs, `ppm-init-failed=1 stop-trying=1`
- Result: L2 question remained open

## dbg51 — Valid, L2/PM class closed

Image: `KERNEL.ci-5d953ca-dbg51` (md5 `7d04d60fb30936d7ffbf354efa935832`)

Verification:
- Header diff only `rs@0x10` and sha1 id at `0x240-0x25F` (recalculated)
- Only `usr/bin/dracut-initqueue` changed in cpio
- `adsp_dtb.mbn` byte-identical
- DTB walk OK, bash/dash syntax OK
- All PM operations use `power/` prefix

Run: cold-plug, `linux usb`, zero actions, `done up=55.67s`

### Markers
```
[E0] paths: a600000.usb/xhci-hcd.0.auto/usb1/usb2 all via power/; wakeup glue MISSING
glue delay=5000, xhci delay=0, usb1/usb2 auto/-1000

[RPM]
17.391944  rpm_resume  a600000.usb   ret=1
31.918155  rpm_idle    a600000.usb   flags=8 cnt=1 dep=0 auto=0 irq=0 child=2 -> ret=-11
31.918223  rpm_idle    xhci-hcd.0.auto flags=8 cnt=1 dep=0 auto=0 irq=0 child=1 -> ret=-11
31.918253  rpm_idle    a600000.usb   flags=8 cnt=0 dep=0 auto=0 irq=0 child=1 -> ret=-16
31.918293  rpm_idle    xhci-hcd.0.auto flags=9 cnt=0 dep=0 auto=1 irq=0 child=2 -> ret=-16
lines=0 suspended-transitions=0

VERDICT: ENUM=0 trace-suspended=0 st_read=glue:1/xhci:1 final_glue_st=active
(no-suspend) glue never slept (status read OK)
hsp-phy-not-in-L2=0
```

### Takeaways

- `-EAGAIN` = `usage_count>0`, `-EBUSY` = `child_count>0`
- Root hubs (`usb1/usb2`) always active due to `delay=-1000` -> chain cannot suspend
- Glue children: `xhci-hcd.0.auto` + `a600000.usb-role-switch` (`child_count=2`)
- Wedge exists in all tested PM states -> **runtime-PM/L2 not the cause**
- ADSP remains in `icm_ncp_stby` until charger type updated -> P-06/BC1.2 remains the leading candidate

## Evidence logs (raw excerpts)

- [`logs/dbg31-role-swap-refused.txt`](../logs/dbg31-role-swap-refused.txt) — PPM/ADSP rejects role swaps (`SET_PDR` `-ECOMM`, `SET_UOR` `-ETIMEDOUT`)
- [`logs/dbg32-connector-reset.txt`](../logs/dbg32-connector-reset.txt) — `CONNECTOR_RESET` no-op or causes PDR down/up
- [`logs/dbg49-adsp-icm-ncp-stby.txt`](../logs/dbg49-adsp-icm-ncp-stby.txt) — ADSP stuck in `icm_ncp_stby` until charger type updated
- [`logs/dbg51-rpm-no-suspend.txt`](../logs/dbg51-rpm-no-suspend.txt) — RPM idle returns `-EAGAIN`/`-EBUSY`, chain cannot suspend
