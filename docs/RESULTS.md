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

## Initramfs analysis (dbg51 image)

The CI initramfs inside the `KERNEL` image was decoded to verify module composition:

```
header v1: page=2048, kernel_size=25532009, ramdisk_size=122811153
ramdisk @ 25534464 =
  [ raw early cpio, 306176 B (microcode) ]
  [ zstd stream @ +306176 -> main cpio, 397752032 B, 3092 entries ]
/init -> usr/lib/systemd/systemd   (systemd-based; modules loaded by systemd-udevd)
```

Findings:

- **`qcom_battmgr.ko` (35536 B) is already present** in the CI initramfs (base commit `5d953ca`, i.e. *before* the explicit `add_drivers` commit). dracut runs with `--no-hostonly`, which ships the full module set into the image.
- **`modules.alias`**: `alias auxiliary:pmic_glink.power-supply qcom_battmgr` — the module is auto-loaded by udev on the auxiliary-bus ADD uevent; no `modules-load.d` entry is needed.
- **`modules.dep`**: `qcom_battmgr.ko` has **zero** dependencies; `qcom_q6v5_pas.ko` pulls 4 modules (`qcom_pil_info`, `qcom_q6v5`, `qcom_sysmon`, `qcom_common`).
- **`modules.builtin`**: lists `typec_ucsi.ko` and `ucsi_glink.ko` as built-in; `qcom_battmgr` and `qcom_q6v5_*` are not built-in (they are `=m`).
- Battery power-supply attributes (`qcom-battmgr-usb`, `battery`, `qcom-battmgr-wls`) are alive and readable in every initramfs run (dbg48–dbg51: VBUS 5057000–5069000 uV) — the module is loaded and probing successfully, so the "missing module" hypothesis is refuted.

## dbg31/dbg32 — UCSI command re-decode (word layout)

With the command word layout known (`bits[7:0]` = command, `bits[23:16]` =
connector number, `bit 23` = CONNECTOR_RESET hard flag; kernel
`ucsi.h:146-154`) the manual UCSI commands of the two AP-side experiment
runs re-decode as:

| run | word | decode | result |
|---|---|---|---|
| dbg32 (K) | `0x00010003` | CONNECTOR_RESET, port 1 | rc=0; handler completed **including the PMIC doorbell** — no visible effect (no fresh CC event to re-detect; port misclassified as `PARTNER_TYPE=0` USB2) |
| dbg32 (K) | `0x00800003` | CONNECTOR_RESET + hard flag, port `0x80 & 0x7f` = **0 → invalid** | confounded: the hang was a reset of a **nonexistent port** (handler rejects port 0), not a clean hard-reset measurement |
| dbg32 (K) | `0x00020003` | CONNECTOR_RESET, port 2 | no-op |
| dbg31 (J) | SET_PDR (sink) | power-role swap | PPM error `UCSI_ERROR_CC_COMMUNICATION_ERR` (bit 4) → `-ECOMM` (the only kernel source of `-ECOMM` is `ucsi_read_error`, `ucsi.c:185-186`) |
| dbg31 (J) | SET_UOR ×2 | data-role swap | PPM never completes → `-ETIMEDOUT` (this also triggered the kernel recovery path: PPM_RESET 0x01 + SET_NOTIFICATION_ENABLE + CONNECTOR_RESET) |

Both runs prove the glink UCSI channel is alive in the initramfs environment
(the PPM answers — with errors or completion), and the UCSI core is active
(spliced DTB: full handshake, `partner=PRESENT`, `power_operation_mode=usb_power_delivery`
at BEFORE, so the automatic GET_PDOS had already fired at boot). The wedge
persists regardless — see
[diagrams/ppm-ucsi-command-flow.md](../diagrams/ppm-ucsi-command-flow.md#why-dbg31dbg32-looked-dead-even-though-the-actor-is-present).

## Evidence logs (raw excerpts)

- [`logs/dbg31-role-swap-refused.txt`](../logs/dbg31-role-swap-refused.txt) — PPM/ADSP rejects role swaps (`SET_PDR` `-ECOMM`, `SET_UOR` `-ETIMEDOUT`)
- [`logs/dbg32-connector-reset.txt`](../logs/dbg32-connector-reset.txt) — `CONNECTOR_RESET` rc=0 no-op; the second variant was a reset of invalid port 0 (re-decoded, above)
- [`logs/dbg49-adsp-icm-ncp-stby.txt`](../logs/dbg49-adsp-icm-ncp-stby.txt) — ADSP stuck in `icm_ncp_stby` until charger type updated
- [`logs/dbg51-rpm-no-suspend.txt`](../logs/dbg51-rpm-no-suspend.txt) — RPM idle returns `-EAGAIN`/`-EBUSY`, chain cannot suspend
