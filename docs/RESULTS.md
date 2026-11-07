# Results

## dbg1400 run — `linux usb` pre-plug (2026-11-07, second run)

Image: `KERNEL.ci-a699dd6-dbg1400` (CI kernel with patch 1400 + CI initramfs
+ CI cmdline + dracut `initqueue/timeout` dump hook). The run used the
**pre-dedup build** — the hook's own dump lines (written to `/dev/kmsg`)
re-appeared inside its own dmesg tail (nested `DBG1400:` lines in the
photos), evicting the real kernel timeline from the tail-80 section. The
fixed build (202 106 472 B, md5 `91ee17b24a4a25b78ce49e74a190484e`) is
built, verified, and has been written to the drive for the re-run.

Protocol: `linux usb`, drive pre-plugged, zero actions.

- **The kernel-side chain of the fix works end-to-end** (photos,
  kernel-monotonic): 1400 marker in dmesg `[164.06] … dr_mode=host ignored:
  usb-role-switch present, using OTG` (the demotion fired) → runtime `[DT]`
  carries both `dr_mode=host` and `usb-role-switch` (the ABL overlay is
  present in the unspliced mode) → `a600000.usb-role-switch` exists with
  `role=host` → `port0-partner` PRESENT, `data_role={host}`, 3.0A →
  `remoteproc0` (adsp) `state=running` → xHCI up.
- **The break is on the port power path**: `qcom-battmgr-usb`
  `usb_type=[Unknown]`, `online=0`, `voltage_now=5062000` — the
  `icm_ncp_stby` fingerprint; no VBUS on the port → the drive is electrically
  dead, never attaches, never enumerates (USB devices = the two root hubs
  only). `ucsi debugfs` ABSENT is benign — debugfs is not mounted in the
  initramfs. The state does not change for 6+ minutes (hook iterations up to
  t≈366 s); the boot ends in the dracut root-wait timeout.
- **The root-wait timeout is trivially explained**: the CI disk image *is*
  the drive (identical MBR layout — 525.3 MB FAT + 1 GiB + 27 GiB; the
  `.armada-bootimg.id` boot marker found inside the image's p1; the cmdline
  `root=UUID=49a99c0a-…` found verbatim in the image's p3 superblock region).
  No enumeration ⇒ no root ⇒ timeout. (Topology: `mmcblk0` is the eMMC — the
  full-boot root — and `sda–sdf` are the UFS LUNs, not USB.)
- **Leading hypothesis (unproven)**: the ABL/XBL USB host session that reads
  `\KERNEL` in `linux usb` mode leaves the PPM/ICM in a state that is not
  re-classified at kernel handoff (pre-plug ⇒ no fresh CC edge; the ICM in
  `ncp_stby` does not rescan). In a normal boot the bootloader never touches
  the port, so PPM detects the drive fresh and it enumerates on the first
  post-PDR scan.
- Secondary anomaly: dwc3 probe at t≈164 s (full-boot xHCI ~14.8/17.75 s) —
  to be measured with the clean tail.

Next: re-run with the fixed `dbg1400` (clean PDR→xHCI Δ / flip timing / ICM
transitions) + full-boot re-check on the same CI build (control). Details:
[KERNEL_PATCH_1400.md](KERNEL_PATCH_1400.md).

## Kernel patch 1400 in the CI image — `linux usb` pre-plug (2026-11-07)

First device test of the patched kernel (Armada PR #704, HEAD `a699dd6`; CI
run 42324657729, artifact `armada-disk-pr704`):

- Patch presence **verified in the flashed `KERNEL`** — the vmlinux marker
  string `dr_mode=host ignored: usb-role-switch present, using OTG` is in the
  boot image.
- `linux usb` mode, drive pre-plugged → **dracut root-wait timeout, no
  enumeration**.
- **Inconclusive, not a clean negative**: the CI image is `quiet` with no
  diagnostic block, so the runtime behavior of the demotion (did it fire, did
  the role flip happen after the PDR, when did xHCI probe, what is the ICM
  state) was not observable.
- Follow-up: the `dbg1400` diagnostic run (above) resolved the observability
  gap — the kernel-side chain works, the break is on the port power path.
  The **full-boot re-check on the same CI build** (control) is still pending
  — protocol and decision matrix in
  [KERNEL_PATCH_1400.md](KERNEL_PATCH_1400.md).

## Cell II — full-system pre-plug (2026-11-05)

Full-system boot (internal storage) with the dock and drive connected before
power-on: the drive enumerated at **16.99 s**, 13 s after switch-root and
**4.4 s after the ADSP `charger_pd` PDR** (10.41 s), when the xHCI host came up
(14.81 s).

- `qcom-battmgr-usb/usb_type` = **SDP** (current; `Unknown` in the initramfs)
- UCSI port present and PD-negotiated: `data_role=host`, `power_role=sink`,
  9 V contract; `qcom_battmgr` is loaded (the "likely dead in full system"
  prediction is refuted)
- PM state matches the predicted working values (`glue=auto/active/5000`,
  `xhci=on/active/0`); L2 remains closed
- Ordering difference vs the initramfs: full system host bring-up **after**
  the `charger_pd` PDR (10.41 → 14.81 s); initramfs USB events at
  2.716/3.182 s and PDR at 3.498 s (host events **before** the PDR), after
  which no new bus events occur

Details, caveats and the next falsifiable test (host re-probe inside the
≤30 s window): [FULL_SYSTEM_PREPLUG_RESULT.md](FULL_SYSTEM_PREPLUG_RESULT.md).

## Full-system mechanism capture (2026-11-06)

Second pre-plug boot, captured with `scripts/full-system-mechanism-capture.sh`:

- **The attach is the first scan, not a fresh CC edge** — the root hub is
  registered at 17.758 s and `usb 1-1` appears 246 ms later with *no* port
  change / CSC / reset / role line in between (same on the 2026-11-05 boot).
- **The 3–4.4 s gap after the `charger_pd` PDR is a UCSI↔ADSP contract round
  trip, not a deterministic hold** — 4.403966 s / 4.406008 s on 11-05, but
  **3.155016 s** and **2.754997 s** on the two sampler boots (root run, see
  [FULL_SYSTEM_MECHANISM_CAPTURE.md](FULL_SYSTEM_MECHANISM_CAPTURE.md)).
  In the full system the `charger_pd` PDR fires *early* (~10–14 s, before
  `suspend`), so the role flip overlaps the boot instead of extending it.
- **The gap is not `-EPROBE_DEFER`**: `devices_deferred` never contains
  `a600000.usb`, and the `dd.c` dynamic-debug trace shows `device: 'a600000.usb':
  device_unregister` (gadget UDC torn down) followed **0.4 ms later** by
  `device: 'xhci-hcd.2.auto': device_add`, which probes bound with no defer in
  39 ms. The host controller did not exist before that point — it is *created*
  by the Type-C role flip. See `logs/full-system/boot-deferred.log`.
- Q4: glue `power/control=auto` comes from
  `60-armada-usb-autosuspend.rules` (Armada-specific); the `5000` ms delay is
  not from udev/hwdb.

Full write-up: [FULL_SYSTEM_MECHANISM_CAPTURE.md](FULL_SYSTEM_MECHANISM_CAPTURE.md).

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
