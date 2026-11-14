# Documentation index

Read in this order if you are new to the project:

1. [../README.md](../README.md) — the problem, the current state, and the
   repository map.
2. [EXPERIMENTS.md](EXPERIMENTS.md) — **every boot ever run**, with a stable
   `EXP-NNN` ID, the image, the conditions, the verdict and whether the run
   is valid. Start here when a document mentions "run 4" or "dbgC5".
3. [TIMELINE.md](TIMELINE.md) — the chronology: what was believed when, and
   what changed the belief.
4. [LEVER_C_IMPLEMENTATION.md](LEVER_C_IMPLEMENTATION.md) — the current
   front: the post-PDR full-chain rescan and the eUSB2 repeater dump.

## Status legend

| status | meaning |
|---|---|
| **active** | work in progress; conclusions may change |
| **reference** | stable code/hardware facts, unlikely to change |
| **closed** | a question that was answered and is not being reopened |
| **log** | evidence: runs, captures, transcripts |

## Documents

| document | status | what it is |
|---|---|---|
| [EXPERIMENTS.md](EXPERIMENTS.md) | **reference** | Canonical experiment registry: conventions, verdict codes, `EXP-NNN` IDs, the legacy alias map (`dbgNN`, letter labels, "run N"), artifact md5 table |
| [TIMELINE.md](TIMELINE.md) | **log** | Chronological narrative, 2026-10-19 → today, one entry per finding |
| [RESULTS.md](RESULTS.md) | **log** | Per-run evidence: console excerpts, measurements, verdicts (newest first) |
| [LEVER_C_IMPLEMENTATION.md](LEVER_C_IMPLEMENTATION.md) | **active** | The lever-C hook: design, gates, the full-chain reset, hook versions v1–v8, the repeater register dump (EXP-035…037), the write ladder |
| [INVESTIGATION.md](INVESTIGATION.md) | **reference** | The hypothesis table (what was tested and how it was closed), the replug window, key code facts |
| [ABL_DR_MODE_HOST.md](ABL_DR_MODE_HOST.md) | **reference** | How `dr_mode=host` reaches the kernel in `linux usb`, and why the early host scan is the trigger for everything downstream |
| [KERNEL_PATCH_1400.md](KERNEL_PATCH_1400.md) | **closed** | Patch 1400 (demote the bootloader's `dr_mode=host` to OTG when `usb-role-switch` is present): design, the CI test, why it was necessary but not sufficient |
| [INITRAMFS_CHANGES.md](INITRAMFS_CHANGES.md) | **reference** | What an initramfs can and cannot do here; the ranked options and why the AP-side command set is empty |
| [SEQUENCER_TIMING_BEST_PRACTICE.md](SEQUENCER_TIMING_BEST_PRACTICE.md) | **reference** | Event-driven sequencing in the initramfs (`udevadm settle`/`wait`, no wall-clock sleeps) and why the "minimalism" option loses |
| [USB_TYPE_TIMING.md](USB_TYPE_TIMING.md) | **closed** | When the port gets classified (`usb_type = SDP` at PDR + 55 ms, inside the PPM) — and why classification is irrelevant to enumeration |
| [ADSP_ULOG.md](ADSP_ULOG.md) | **reference** | The PPM's own charger log read from the AP: the instrument, the success-side fingerprint, the diff against the failing side |
| [ADSP_RE.md](ADSP_RE.md) | **reference** | PPM/ADSP firmware reverse engineering: the wedge state, trigger map, glink RX, the "flag wall" refutation |
| [ADSP_CONFIG.md](ADSP_CONFIG.md) | **reference** | `adsp_dtb.mbn` container layout, PPM config values, the 1-byte `apsd-rerun-cfg` patch recipe |
| [FULL_SYSTEM_PREPLUG_RESULT.md](FULL_SYSTEM_PREPLUG_RESULT.md) | **log** | The 2026-11-05 control: full-system pre-plug works, `usb_type = SDP`, host after the PDR |
| [FULL_SYSTEM_PREPLUG_SOURCE_ROLE.md](FULL_SYSTEM_PREPLUG_SOURCE_ROLE.md) | **log** | The 2026-11-11 control: full-system pre-plug in the source role enumerates **with the failing-side PPM fingerprint** ⇒ `usb_type` is not the discriminator |
| [ULOG_DIFF_DATA_PATH.md](ULOG_DIFF_DATA_PATH.md) | **active** | The 2026-11-14 ULog diff (working E vs failing dbgB): the residual blocker is the **eUSB2 data path** — not classification, VBUS, or ordering; `apsd-rerun-cfg` repositioned to diagnostic; sets up EXP-042 (localize the closed routing element) |
| [FULL_SYSTEM_MECHANISM_CAPTURE.md](FULL_SYSTEM_MECHANISM_CAPTURE.md) | **closed** | Q1–Q5: the host controller is *created* on the Type-C role flip; nothing holds the probe |
| [FULL_SYSTEM_COLDPLUG_TEST.md](FULL_SYSTEM_COLDPLUG_TEST.md) | **reference** | How to run the full-system capture script |
| [TEST_METHOD.md](TEST_METHOD.md) | **reference** | The test protocol: image invariants, flashing, orientation, zero-action runs |
| [EXTERNAL_PRIOR_ART.md](EXTERNAL_PRIOR_ART.md) | **reference** | Web-search round: upstream corroboration (qmp-combo `-110`, `dr_mode`+role-switch, ROCKNIX-ABL) |

## Other directories

- [`../diagrams/`](../diagrams/) — architecture, ICM state machine, charger
  type chain, `usb_type`, UCSI command flow, PM chain
- [`../scripts/`](../scripts/) — capture scripts, firmware RE toolchain, and
  [`lever-c/`](../scripts/lever-c/) (the complete lever-C toolchain:
  hooks v2–v8, builders, fake-sysfs harness)
- [`../logs/`](../logs/) — raw and transcribed evidence;
  [`lever-c/`](../logs/lever-c/) holds the EXP-037 console transcript
