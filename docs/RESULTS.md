# Results

Newest first. Each entry names its experiment ID
([EXPERIMENTS.md](EXPERIMENTS.md)); the console transcripts are in `logs/`.

## EXP-037 — eUSB2 repeater register dump (2026-11-14) — `FAIL-NO-SCAN-FULL`, dump complete

Image `dbgC8` (md5 `52c888a01f0470fb35f2b1a028209e9f`), hook v8, `linux usb`,
stick pre-plugged, normal orientation, zero actions. The chain is beta-2 for
the fourth time (partner 3 s, `otg enable` 5.48 s, `ESCALATE` 7 s with all
rc=0, `TREE[NO-SCAN-FULL]` 23 s, `scan-events=0`, no `-110`), and the dump —
which stalled in EXP-035 and EXP-036 — completes in 2 s:

```
RPT-S2: candidates=[0-00 0-01 0-05 0-07]
RPT-SCAN: 0-00 lines=92 … XX   (window beyond max_register: no HW read)
RPT-SCAN: 0-01 lines=92 … XX
RPT-SCAN: 0-05 lines=92 … XX
RPT-SCAN: 0-07 lines=92 WRN: 08=80 46=80 51=0b 53=06 54=03 57=03
                 KEY: 50=00 52=01 55=03 56=00 58=02 59=03 5a=01 5b=02
RPT-DONE: dump complete at 25s
```

The repeater is spmi device `0-07` (address 0x07 = pm8550b), identified by
its own signature `0xfd08 = RPTR_OK` + `0xfd46 = RPTR_EN`. Full transcript:
[`logs/lever-c/exp-037-dump.txt`](../logs/lever-c/exp-037-dump.txt); analysis:
[LEVER_C_IMPLEMENTATION.md](LEVER_C_IMPLEMENTATION.md) §12.5–12.7.

| reg | name | value | kernel writes it? |
|---|---|---|---|
| `fd08` | RPTR_STATUS (RO) | `80` (RPTR_OK) | — |
| `fd46` | EN_CTL1 | `80` (RPTR_EN) | yes |
| `fd51` | TUNE_IUSB2 | `0b` | yes (DT amplitude) |
| `fd53` | TUNE_HSDISC | `06` | yes (DT disc-thres) |
| `fd54` | TUNE_SQUELCH_U | `03` | yes (init table) |
| `fd57` | TUNE_USB2_PREEM | `03` | yes (DT preem) |
| `fd50` | TUNE_USB2_CROSSOVER | `00` | **no** |
| `fd52` | TUNE_RES_FSDIF | `01` | **no** |
| `fd55` | TUNE_USB2_SLEW | `03` | **no** |
| `fd56` | TUNE_USB2_EQU | `00` | **no** |
| `fd58` | TUNE_USB2_HS_COMP_CUR | `02` | **no** |
| `fd59` | TUNE_EUSB_SLEW | `03` | **no** |
| `fd5a` | TUNE_EUSB_EQU | `01` | **no** |
| `fd5b` | TUNE_EUSB_HS_COMP_CUR | `02` | **no** |

Takeaways: (1) the repeater is enabled and healthy in the broken state and
the kernel's init ran (the DT/init values are exactly the ones it writes);
(2) the eight un-written registers are **not zero** ⇒ the "ABL zeroed the
tuning" form of the `31bc94de` regression is refuted for `linux usb`;
(3) the "676 SPMI timeouts" model of the read duration is refuted
(0.2–1.1 s per map, `timeouts before=0`, `after=0`); (4) the scan-based
identification works on live hardware. The control (normal boot, same
image, EXP-038) decides whether the register file differs between the
working and the broken mode at all.

## EXP-035 / EXP-036 — why the dump stalled (2026-11-13/14) — both invalid as dumps

`dbgC6` (EXP-035) printed its first dump line at 23.629 s and then nothing
for 28 s; `dbgC7` (EXP-036) added step markers and located the stall:
`mkdir rc=0` → `mount rc=0` → `RPT-S2: globbing platform devices` @23.394 s
→ silence. debugfs mounts fine and the register read never starts: the hang
is the platform-device **symlink resolve** (`*eusb2*` glob, `[ -e ]`,
`cd -P`, `pwd -P`, `stat`). v8 removed it. Details:
[LEVER_C_IMPLEMENTATION.md](LEVER_C_IMPLEMENTATION.md) §12.1–12.4.

## dbgB run — failing-side PPM ULog capture (2026-11-09) — FAIL-NO-CLASSIFY

Experiment: **EXP-026** ([registry](EXPERIMENTS.md)).

Lever B as designed in [INITRAMFS_CHANGES.md](INITRAMFS_CHANGES.md): the
failing env's own PPM view, captured in the initramfs console. Image `dbgB`
(md5 `12a0327f…`), `linux usb`, stick pre-plugged, zero user action, ~41 s of
console ([raw capture](../logs/dbgB-preplug-usb-ulog-20261109.txt)).

The diff against the success-side fingerprint
([ADSP_ULOG.md](ADSP_ULOG.md)) is now on the full ULog, not on the
dbg49 `ncp_stby` excerpt:

- **Detection ran and saw the partner** — `FPM: GET_CONNECTOR_STATUS:
  Port[0]: … ConnectPartnerType=2, (USB=1, AltMode=0)` @7.41; the
  `charger_detection.c` tag is demonstrably enabled (`…get_active_charger`,
  `…get_charger_update` lines present), so the log-gate caveat of the
  decision rule does not apply.
- **The result was empty and never became a power type** —
  `activePort[4] PartnerType=0, Voltage_max=0 mV, Power_max_uw=0 uW` @17.67,
  `bChargeChanged = 0 max_vbus = 0`; and the PPM says why:
  `charger_detection_event_handler: skip checking usb charging type while
  usb is sourcing` @17.67. `usb_type` stays `[Unknown]` / `online=0` in
  every poll (5.4 s → 40.8 s).
- **ICM parked the whole time** — `keeps in icn_ncp_stby untill
  charger_type updated` @7.41, `ncp_stby_db - chgr_stat=7, soc=9980` @30.23
  (the dbg49 fingerprint, now on the full ULog); charger SM `0→1→2` then
  stuck at 2 (success side: →4 by PDR + 8 s).

**Verdict: FAIL-NO-CLASSIFY** (a `PartnerType=` line is present, `usb_type`
stuck `Unknown`) ⇒ decision-rule branch 2 (firmware side). The "ABL USB
host-session blocks detection" hypothesis is not supported: the PPM detected
the partner; what is missing is the source-role power path (VBUS source for
the stick), with the classification explicitly skipped "while usb is
sourcing". Next: the full-system pre-plug control with a directly-attached
stick (discriminates pre-plug/source-role from initramfs-vs-full), then the
firmware-side levers per [INITRAMFS_CHANGES.md](INITRAMFS_CHANGES.md).

## PPM ULog from the AP — success-side fingerprint (2026-11-08, boot 1 of 2)

Experiment: **EXP-025** ([registry](EXPERIMENTS.md)).

New instrument: the stock `pmic_pdcharger_ulog.ko` — never loaded in any
environment — reads the PPM charger ULog from the AP over the
`PMIC_LOGS_ADSP_APPS` rpmsg channel (1 s poll, 8 KB drain ring, tracepoint
output). Installed as `adsp-ulog-capture.service` at `sysinit.target`; the
module is **already in the stock initramfs**, so lever B
([INITRAMFS_CHANGES.md](INITRAMFS_CHANGES.md)) collapses to `modprobe` +
tracefs inside init.

Boot 1 = full-system pre-plug control (2026-11-08 15:39). The PPM's own view:

- **Initial detection ran at ADSP boot**: the first ULog drain (PDR + 21.9 ms)
  already contains `charger_detection_evaluate_typec_charger: Input[0]
  PartnerType=2, Voltage=5000 mV, Current=900 mA` plus charger SM
  `event_type=10, curr=0→1→2` and `otg enable: 1` / "OTG source not
  available". This is the PPM-internal event that `usb_type` timing measured
  as "classified at PDR + 55 ms" from the AP side.
- PD contract reflected at PDR + 2.06 s: `ActivePort[0] PartnerType=15,
  Voltage_max=9000 mV, Current_max=2440 mA`, `max_vbus = 9000`, `USB charger
  connected`, `Charging source is 2`, `usb_charge_now=1`; BattMngr Run level 3.
- Charger SM reaches **state 4** by PDR + 8.2 s (`event_type=20, curr=4`
  periodic; heartbeat `event_type=24, curr=4` at 43.0 s); steady state
  `scp_inov_db: fcc_ma=5700, icl_ma=2440, vin_mv=9000`.
- **Zero `ncp_stby` lines** — contrast dbg49 (initramfs): SM stuck at state 2
  (`event_type=24, curr=2, next=2` at 33.2 s and 52.7 s) with ICM parked in
  `ncp_stby` "untill charger_type updated" (`chgr_stat=7`), no PartnerType line
  at all.
- AP side (poller, same boot): SDP at PDR + 294 ms, PD 13.01 s, role=host
  15.72 s, `usb 1-1` 15.956 s, `sdg` 17.92 s. The power-path phase order
  differs from the 13:09 boot (no 9.083 V first sample, no 6 mV collapse) —
  offsets stable, phase order boot-dependent.
- The 2→4 SM transition line was lost to the 8 KB ring wrap (drain semantics);
  the state value at each drain is the reliable quantity.

The success/failure discriminator is the PPM's initial-detection result; boot
2 (lever B in the initramfs) captures the failing side for the diff.

Raw: [`logs/full-system/adsp-ulog-20261108-1539.log`](../logs/full-system/adsp-ulog-20261108-1539.log),
[`logs/full-system/usb-type-poller-20261108-1539.log`](../logs/full-system/usb-type-poller-20261108-1539.log).
Write-up: [ADSP_ULOG.md](ADSP_ULOG.md).

## `usb_type` timing — full-system pre-plug (2026-11-08)

Experiment: **EXP-024** ([registry](EXPERIMENTS.md)).

New instrument (`scripts/usb-type-poller.sh`, 50 ms, enabled at
`sysinit.target`) on a normal pre-plug boot, zero actions. It closes the
"when does it get classified?" hole left open in
[FULL_SYSTEM_PREPLUG_RESULT.md](FULL_SYSTEM_PREPLUG_RESULT.md) (next experiment
2):

- **`usb_type` is `SDP` at `charger_pd` PDR + 55 ms** (PDR 11.024750 → first
  readable sample 11.08, `online=1`, V = 9.083 V) — **inside the PPM, with no
  AP actor**: the in-kernel UCSI core had issued nothing (its
  `ucsi-source-psy` node only appears at 11.056 s *because* the PPM pushed
  state at it), there is no fresh CC edge, and `SetRerunApsd` is config-gated
  off. Trigger path **#1 (initial detection at PPM boot)** is the one that
  fires; #2/#3 were neither needed nor used.
- What follows is a **power-path** sequence, not classification: 9.08 V →
  VBUS collapse to 6 mV (11.71, `usb_type` → `Unknown` for 0.8 s) → 5.25 V +
  `SDP` (12.52) → PD negotiation (12.75) → 9 V + data-role swap to host
  (15.43, within one poller sample of the `xhci-hcd.2.auto` `device_add` at
  15.412) → first scan 15.664 → `sdg` 18.320 → mounted.
- **Discriminator vs the initramfs is the PPM state at the PDR**, not an AP
  trigger: the initramfs gets the same PDR (dbg49: 3.498103 s) and the same
  UCSI/typec nodes, yet `usb_type` never leaves `[Unknown]`, `online=0`,
  V = 5.062 V, no PD contract — for minutes (dbg1400, unchanged to t≈366 s).
- New PDR → xHCI sample: **4.387312 s** (range 2.7–4.4 s unchanged, now
  2.755 / 3.155 / 4.387 / 4.404 / 4.406 s).

Raw: [`logs/full-system/usb-type-poller-20261108-130924.log`](../logs/full-system/usb-type-poller-20261108-130924.log),
[`logs/full-system/usb-type-timeline-20261108.txt`](../logs/full-system/usb-type-timeline-20261108.txt).
Full write-up: [USB_TYPE_TIMING.md](USB_TYPE_TIMING.md). Consequence for the
fix: [INITRAMFS_CHANGES.md](INITRAMFS_CHANGES.md).

## dbg1400 run — `linux usb` pre-plug (2026-11-07, second run)

Experiment: **EXP-023** ([registry](EXPERIMENTS.md)).

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
  post-PDR scan. **It does not fit on its own**: a fresh CC edge works at
  ≤ ~24.7 s and fails at 38/59/102 s with an identical ABL session — the
  combined model (ABL blocks the *initial* classification, the PPM ~30 s/40 s
  window blocks *late* recovery) and the two remaining edge-free levers are in
  [KERNEL_PATCH_1400.md](KERNEL_PATCH_1400.md).
- Secondary anomaly: dwc3 probe at t≈164 s (full-boot xHCI ~14.8/17.75 s) —
  to be measured with the clean tail.

Next: re-run with the fixed `dbg1400` (clean PDR→xHCI Δ / flip timing / ICM
transitions) + full-boot re-check on the same CI build (control). Details:
[KERNEL_PATCH_1400.md](KERNEL_PATCH_1400.md).

## Kernel patch 1400 in the CI image — `linux usb` pre-plug (2026-11-07)

Experiment: **EXP-022** ([registry](EXPERIMENTS.md)).

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

Experiment: **EXP-020** ([registry](EXPERIMENTS.md)).

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

Experiment: **EXP-021** ([registry](EXPERIMENTS.md)).

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

Experiment: **EXP-008** ([registry](EXPERIMENTS.md)).

Image: `KERNEL.ci-5d953ca-dbg50`

- **Harness bug**: PM attributes read/written without `power/` prefix (`runtime_status`, `autosuspend_delay_ms`, `wakeup`)
  - Reads returned empty/ENOENT
  - Writes caused `open(O_CREAT)` in read-only sysfs -> `EACCES`
  - Status never observed, verdict was vacuous
- Side observations: `usb_type=Unknown`, ADSP fingerprint matched previous runs, `ppm-init-failed=1 stop-trying=1`
- Result: L2 question remained open

## dbg51 — Valid, L2/PM class closed

Experiment: **EXP-009** ([registry](EXPERIMENTS.md)).

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

Experiment: **EXP-003** ([registry](EXPERIMENTS.md)).

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
- [`logs/dbgB-preplug-usb-ulog-20261109.txt`](../logs/dbgB-preplug-usb-ulog-20261109.txt) — failing-side PPM ULog (lever B): partner detected (`ConnectPartnerType=2`), charger type skipped "while usb is sourcing", ICM parked in `ncp_stby`
