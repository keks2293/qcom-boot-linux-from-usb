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
   see the port*; if A is negative, go straight to D. **Log-gate caveat
   (2026-11-09 RE):** the `PartnerType=` print is ULog-gated
   ([ADSP_RE.md](ADSP_RE.md#the-two-remaining-function-bodies--now-decoded-2026-11-09)),
   so this branch is *functional* only when the capture also shows other
   `charger_detection.c` lines (tag demonstrably enabled) — otherwise absence
   is a logging artifact. The functional markers that make the branch valid
   are the `sm_state_loop` state stuck at 2 + ICM `ncp_stby`
   "untill charger_type updated"; if those are absent too, re-enable the ULog
   tag before drawing a conclusion.
2. **B shows a `PartnerType=` line (detection ran and saw the port) but
   `usb_type` stays `Unknown`** → the result never reaches the property
   service; that is a firmware-side defect and D is the only lever.
3. **A or C flips `usb_type` to `SDP`** → the fix is an initramfs change, and
   PR #704 grows a third commit: a staged ADSP start or a post-PDR nudge hook.
4. **All negative** → the documented conclusion is *"nothing that can be added
   to the initramfs fixes this; the gate is the PPM config byte"* — which is
   itself the falsifiable end-state this investigation has been converging on.

## dbgB run result (2026-11-09) — FAIL-NO-CLASSIFY

The next boot was run as **B-only** (`dbgB`, md5 `12a0327f…` — CI base
`a699dd6` + the single `90-armada-ulog-b.sh` hook; the enum-only A + C-lite
build was not used — the "light logging only" decision). `linux usb`, stick
pre-plugged, zero user action, ~41 s captured from the console
([logs/dbgB-preplug-usb-ulog-20261109.txt](../logs/dbgB-preplug-usb-ulog-20261109.txt)).

**The PPM detected the partner and ran charger detection — and then never
classified the port to a power type; the ICM stayed parked in `ncp_stby`
through the whole capture.**

| what | line (t s) |
|---|---|
| capture alive | `Ulog capture ON` @3.33; heartbeats @17.7 / @34.5 with `ulog_ok=1` |
| FPM sees the partner | `FPM: GET_CONNECTOR_STATUS: Port[0]: … PowerDirection=1, ConnectPartnerType=2, (USB=1, AltMode=0)` @7.41 |
| charger detection ran | `charger_detection_get_active_charger: activePort[4] PartnerType=0, Voltage_max=0 mV, … Power_max_uw=0 uW` @17.67 (`charger_detection.c` tag demonstrably enabled → the log-gate check of decision rule 1 is satisfied) |
| classification skipped | `charger_detection_event_handler: skip checking usb charging type while usb is sourcing` @17.67 |
| ICM parked | `icn_ncp_stby_main: keeps in icm_ncp_stby untill charger_type updated` @7.41; `ncp_stby_db - chgr_stat=7, soc=9980` @30.23 (same `chgr_stat=7` as the dbg49 fingerprint) |
| charger SM stuck at 2 | `sn_state_loop: curr=2, next=2` on events 3 / 12 / 24 (the success side walks 2→4, [ADSP_ULOG.md](ADSP_ULOG.md)) |
| port never classified | `usb_type=(Unknown) online=0` in every poll, 5.4 s → 40.8 s, no change; `partner=yes` from 5.37 s |

**Verdict: FAIL-NO-CLASSIFY** — a `PartnerType=` line is present but
`usb_type` never leaves `Unknown` ⇒ decision-rule **branch 2**: the detection
result never reaches the property service; firmware side. The "ABL USB
host-session blocks detection" hypothesis is **not supported by this run**:
detection ran, and the FPM reports the partner (`ConnectPartnerType=2`,
USB=1). What is missing is the classification to a power type — and the PPM
logs the reason explicitly: it **skips** the USB charging-type check
**"while usb is sourcing"** (the port is in the source role, expected to power
the stick, instead of the sink role of the success environment, where the PD
dock was the power partner).

Open question this raises: in the source role the expected charger-detection
result is "no charger" — so the missing step is not classification per se, it
is whatever makes the PPM **release the port for host power (VBUS source)**
after a source-role partner is detected. The cheap control below (full-system
pre-plug with a directly-attached stick) now also discriminates
"pre-plug / source-role" from "initramfs vs full system".

Two discrepancies to keep in mind: `typec_detect_partner: TypeCPartnerType=0
(InputNum=0)` @5.35 vs the FPM's `ConnectPartnerType=2` @7.41 (the two
partner readings disagree), and the charger_detection active port is index
**4**, not 0 (success side: port 0).

## Next step: the enum-only test

The ranked candidates above are a plan; this is the concrete next boot. It
answers the one open question in the decision rule — **does the PPM's initial
detection run in the failing (initramfs) environment, and what does it
return?** — on the smallest drive that can carry the question.

**"Enum-only" = the milestone is enumeration, not boot.** The drive is one
partition: p1 (256 M, vfat, label `ARMADA`) holding the boot image (`KERNEL` =
`gzip(vmlinuz)+DTBs` + the fixed initramfs as ramdisk). No p2, no OS-root
clone, no real root (a placeholder `root=UUID=` is used and the debug init
ignores it). Booting the OS from the stick is the later step, only after
enumeration is proven.

**Why this vehicle.** One boot runs the first candidates of the ranked order
together — **A** (stage the ADSP start to ~T+11 s), **B** (the poller + the
stock `pmic_pdcharger_ulog` PPM-ULog drain), and **C-lite** (unbind/rebind
`dwc3-qcom` around the PDR) — and B's first-drain ULog window is exactly the
discriminator the decision rule needs. A debug PID-1
(`armada-usb-fix-debug-init`) runs the sequence with a console echo per step;
on enumeration it prints `ENUMERATION OK: /dev/sdX` and keeps refreshing the
init logs (including the PPM ULog) onto p1 so they can be read off the stick on
a PC.

**How to run it** (unprivileged build, no kernel rebuild; the build lives in
`agent-work/usb-fix/`, a sibling of this repo, on the device):

```sh
cd agent-work/usb-fix/build
./build-initramfs.sh  ../out/initramfs-fix.img              # A + B + C-lite
# lever-D variant — only if the first boot's verdict is FAIL-NO-DETECTION /
# FAIL-NO-CLASSIFY:
./build-initramfs.sh ../out/initramfs-fwD.img --fw-dir ../out/fw-apsdrerun
# on a spare stick (NOT Slim), with your sudo:
sudo ./make-drive.sh /dev/sdX ../out/initramfs-fix.img --enum-only
# unplug → pre-plug into the RP6 before power-on → ABL menu → linux usb
```

**Verdict → next boot** (the decision rule, mapped to the build):

| console verdict | decision-rule branch | next boot |
|---|---|---|
| `PASS usb_blocks=[sdX]` | A+B(+C-lite) fixed it | milestone 1 done → OS-root clone + boot-from-stick |
| `FAIL-NO-PDR` | A failed (staged ADSP start didn't reach the PDR) | read the ULog/dmesg remoteproc errors in the shipped logs |
| `FAIL-NO-DETECTION` (no `PartnerType=`) | branch 1 — detection ran blind or was skipped *(valid only with the log-gate check: `charger_detection.c` tag demonstrably enabled + SM/ICM markers, see decision rule 1)* | lever-D boot (`initramfs-fwD.img`), or refine A |
| `FAIL-NO-CLASSIFY` (`PartnerType=` present, `usb_type` stuck `Unknown`) | branch 2 — result never reaches the property service | lever-D boot (firmware-side) |
| `FAIL-NO-SCAN` (`usb_type=SDP`, no block device) | classification OK, the scan missed the drive | refine C (post-PDR nudge timing) |

**The confound to rule out (cheap control boot).** The measured full-system
success used a **PD dock** as the partner; the failing `linux usb` case is a
**directly-attached stick** — a different partner for the PPM. Before reading
an enum-only result as "initramfs vs full system," run the control: a
**full-system pre-plug with a directly-attached stick** (no tooling — boot the
normal OS with the stick already in the port and check it enumerates without a
replug). If the full system *also* fails to enumerate a pre-plugged direct
stick until a replug, the discriminator is partner-type/pre-plug, not
initramfs-vs-full, and the plan above changes.

## References

- Success-side PPM ULog fingerprint: [ADSP_ULOG.md](ADSP_ULOG.md)
- Measurement: [USB_TYPE_TIMING.md](USB_TYPE_TIMING.md)
- Why the early scan existed: [ABL_DR_MODE_HOST.md](ABL_DR_MODE_HOST.md)
- Patch state and `dbg1400`: [KERNEL_PATCH_1400.md](KERNEL_PATCH_1400.md)
- Firmware levers: [ADSP_CONFIG.md](ADSP_CONFIG.md), [ADSP_RE.md](ADSP_RE.md)
- Replug window (the ≤30 s constraint): [INVESTIGATION.md](INVESTIGATION.md#the-replug-window-timing-correlation)
