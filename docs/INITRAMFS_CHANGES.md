# What has to be added to the initramfs — and what cannot be

Status after the `dbg1400` run ([KERNEL_PATCH_1400.md](KERNEL_PATCH_1400.md))
and the full-system `usb_type` timing measurement
([USB_TYPE_TIMING.md](USB_TYPE_TIMING.md)). This document answers one
question: **given everything now measured, what would a `linux usb` initramfs
have to contain to enumerate a pre-plugged drive?**

## TL;DR

- **Already in (PR #704) and verified working:** (1) the dracut ADSP drop-in
  (`qcom_q6v5_pas` + board firmware) so the `charger_pd` PDR exists in the
  initramfs at all; (2) kernel patch 1400 (demote `dr_mode=host` → OTG) so the
  first host scan lands *after* the role flip. `dbg1400` shows both firing:
  demotion warning in dmesg, role flipped to HOST, xHCI created, ADSP running.
- **Neither is the missing piece.** The drive is still dead because the port is
  never classified: `usb_type=[Unknown]`, `online=0`, no PD contract, no VBUS.
- **There is no AP-side "set `usb_type`" switch to call from init.** The
  working environment classifies at `charger_pd` PDR + 55 ms **inside the PPM,
  with no AP actor at all** — so an init script cannot reproduce that step by
  sending a command; it can only change the *state/timing the PPM comes up in*,
  or nudge it through the paths that are still open.
- The two PPM re-trigger paths that would help are both blocked **before**
  init: a fresh CC edge is impossible from software on this board, and
  `SetRerunApsd` is config-gated off by `apsd-rerun-cfg = 0` in the firmware.
- ⇒ **Ranked candidates: A stage the ADSP start like a normal boot, B add the
  poller + ADSP ULog capture to init (diagnostic — the reader is the stock
  `pmic_pdcharger_ulog.ko`, already in the initramfs image, and the
  success-side fingerprint is already captured in
  [ADSP_ULOG.md](ADSP_ULOG.md)), C a post-PDR AP nudge inside the ≤30 s
  window. If all three are negative, the answer is "nothing that can be added
  to init" and the fix is the firmware byte (D, `dbg52`).**

## What is already in init (PR #704)

| commit | change | state |
|---|---|---|
| `68f68ad` | dracut drop-in `91-armada-adsp.conf`: `add_drivers += qcom_q6v5_pas` + `install_items +=` the board ADSP firmware images | **verified** — `remoteproc0 state=running` and `charger_pd` PDR present in `dbg1400` |
| `a699dd6` | kernel 1400: `dwc3_get_dr_mode()` demotes `HOST` → `OTG` when `usb-role-switch` is present | **verified** — marker `dr_mode=host ignored: usb-role-switch present, using OTG` in dmesg; role-switch registered; role flipped to HOST after the PDR; xHCI created |

Both were necessary: without the first, no PDR (nothing to sequence against);
without the second, the first scan happens at ~2.7 s, before the PDR at ~3.5 s
([ABL_DR_MODE_HOST.md](ABL_DR_MODE_HOST.md)). With both, `dbg1400` reached
"role flipped, xHCI up" and **still** did not enumerate — the break is one step
further down, on the port power path.

## Why "add a command to init" is not available

From [USB_TYPE_TIMING.md](USB_TYPE_TIMING.md): in the working environment
`usb_type` is already `SDP` **55 ms after the PDR**, before the in-kernel UCSI
core has sent anything (its power-supply node appears *because* the PPM pushed
state at it). The classification is a PPM-internal event. The two firmware
paths that could re-run it are both closed to an init script:

| PPM re-trigger path | why an init script cannot use it |
|---|---|
| **fresh CC edge** (physical) | No VBUS regulator node exists in the RP6 DT (`qcom_usb_vbus-regulator` matches only `qcom,pm8150b-vbus-reg`) → no AP-side VBUS cycle ([INVESTIGATION.md](INVESTIGATION.md)); `CONNECTOR_RESET` (0x03) is a no-op on this device ([RESULTS.md](RESULTS.md#dbg31dbg32--ucsi-command-re-decode-word-layout)); the role/power commands come back `-ECOMM` / `-EOPNOTSUPP` (dbg31/dbg32) |
| **`SetRerunApsd`** (AP `pmic_glink` → `dpm_usbc`) | Gated by `apsd-rerun-cfg = 0` in the PPM FDT — `SetRerunApsd` returns without doing anything, in **every** environment (payload byte-identical across all 7 public sm8550 variants, [ADSP_CONFIG.md](ADSP_CONFIG.md)) |
| **periodic/autonomous rerun** | dead code — `SetAiclPeriodicRerun` / `SetAiclRerunTimeCfg` have 0 references (trigger table in [ADSP_RE.md](ADSP_RE.md)) |

So the only things an initramfs can still change are **when the PPM starts**,
**what we can observe**, and **whether an AP-side nudge lands inside the
classification window**.

## Ranked init-side candidates

| # | add to init | what it tests | cost |
|---|---|---|---|
| **A** | **Stage the ADSP start like a normal boot.** Don't let `qcom_q6v5_pas` probe at ~3 s; delay it to ~10 s (blacklist + a hook that loads it later, or a `modprobe -r`/`modprobe` pair) | The one timing difference between the environments that has **never** been varied. Full system: ADSP up **10.978 s** (13:09 boot; 12.012 s in the 15:39 boot — the start drifts ~1.5 s boot-to-boot) → PDR 11.025 → classified 11.08. Initramfs: PDR 3.498 s, immediately behind ABL's USB host session. If the PPM coming up "late and clean" is what makes initial detection succeed, this reproduces it | one boot |
| **B** | **The poller + ADSP ULog capture in initramfs.** Ship [`scripts/usb-type-poller.sh`](../scripts/usb-type-poller.sh) and [`scripts/adsp-ulog-capture.sh`](../scripts/adsp-ulog-capture.sh) into the initramfs: mount tracefs, `modprobe pmic_pdcharger_ulog` (the **stock** AP-side reader — no dependencies, **already in the initramfs image**), enable `pmic_pdcharger_ulog:pmic_pdcharger_ulog_msg`, drain ~40 s. Grep the `PartnerType=` detection result, `ncp_stby_db`, `sm_state_loop` around the PDR | Diagnostic, no behaviour change: does initial detection **run** in the failing env, and what does it return? Success side already captured ([ADSP_ULOG.md](ADSP_ULOG.md)); this boot gets the failing side for the diff | one boot |
| **C** | **Post-PDR nudge inside the ≤30 s window** — a hook that waits for the `PDR: Indication … charger_pd` line, then (one lever per boot) mounts debugfs and issues the UCSI command, or toggles `/sys/class/usb_role/*/role`, or unbinds/binds `dwc3-qcom` | The last open AP-side option. Every previous attempt was either run **outside** the window (dbg49's re-probe at >32 s) or with a confounded command word (dbg31/dbg32) — `FULL_SYSTEM_PREPLUG_RESULT.md` next-experiment #1 has still never been run | one boot per lever |
| **D** | *(not an init change)* **`apsd-rerun-cfg` 0→1** in `adsp_dtb.mbn` (1 byte + `sha384` slot, recipe byte-verified, TZ accepts the re-hash) | Opens the only edge-free re-detection path the firmware has. Caveat: `SetRerunApsd` still needs the AP's `pmic_glink` message in the right DPM state, which is undecoded — so even D may need C | one boot (dbg52) |

**Recommended order: B → A → C → D.** B first because it turns the next boot
from "still broken" into a diagnosis; A because it is the untouched variable and
is free; C as the last AP-side option; D if the AP side is exhausted.

### What is *not* worth adding

- **A longer root-wait / `rootwait`** — enumeration completes **7.30 s** after
  the PDR and **2.91 s** after the role flip in the working environment; the
  dracut timeout already outlives everything by two orders of magnitude. The
  problem is classification, not patience.
- **`fw_devlink=permissive`, xHCI quirks, `usbcore.autosuspend=-1`** — the
  L2/PM class is closed (dbg51), no probe is deferred
  ([FULL_SYSTEM_MECHANISM_CAPTURE.md](FULL_SYSTEM_MECHANISM_CAPTURE.md)), and
  the controller did not exist before the flip.
- **Shipping the UCSI core "activly"** — it is already active in every initramfs
  run and in the working full system; active-vs-deferred is not the
  discriminator.

## Decision rule

The success-side fingerprint is captured ([ADSP_ULOG.md](ADSP_ULOG.md)): the
success env's PPM logs `charger_detection_evaluate_typec_charger …
PartnerType=2, Voltage=5000 mV, Current=900 mA` in the PDR + 22 ms drain, the
charger SM walks 2→4 by PDR + 8 s, and there is **no** `ncp_stby`. The failing
env (dbg49) shows the opposite: SM stuck at state 2 (`event_type=24, curr=2,
next=2` at 33.2 s and 52.7 s), ICM parked in `ncp_stby` "untill charger_type
updated" (`chgr_stat=7`), no PartnerType line at all.

1. **B shows no `PartnerType=` line in any drain** (detection produced nothing
   — the dbg49 fingerprint, now on the full ULog) → the PPM's initial
   detection ran blind or was skipped in the initramfs; A is about *making it
   see the port*; if A is negative, go straight to D.
2. **B shows a `PartnerType=` line (detection ran and saw the port) but
   `usb_type` stays `Unknown`** → the result never reaches the property
   service; that is a firmware-side defect and D is the only lever.
3. **A or C flips `usb_type` to `SDP`** → the fix is an initramfs change, and
   PR #704 grows a third commit: a staged ADSP start or a post-PDR nudge hook.
4. **All negative** → the documented conclusion is *"nothing that can be added
   to the initramfs fixes this; the gate is the PPM config byte"* — which is
   itself the falsifiable end-state this investigation has been converging on.

## References

- Success-side PPM ULog fingerprint: [ADSP_ULOG.md](ADSP_ULOG.md)
- Measurement: [USB_TYPE_TIMING.md](USB_TYPE_TIMING.md)
- Why the early scan existed: [ABL_DR_MODE_HOST.md](ABL_DR_MODE_HOST.md)
- Patch state and `dbg1400`: [KERNEL_PATCH_1400.md](KERNEL_PATCH_1400.md)
- Firmware levers: [ADSP_CONFIG.md](ADSP_CONFIG.md), [ADSP_RE.md](ADSP_RE.md)
- Replug window (the ≤30 s constraint): [INVESTIGATION.md](INVESTIGATION.md#the-replug-window-timing-correlation)
