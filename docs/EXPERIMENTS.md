# Experiment registry

This file is the **single source of truth for experiment numbering**. Every
controlled boot gets an immutable ID. The IDs never change, are never reused,
and an experiment that turned out invalid **keeps its ID** (it is part of the
record: it explains why a later run looks the way it does).

Historically the project used three ad-hoc labels for the same thing — the
image name (`dbg24`, `dbgC5`), a letter label for the replug-window series
(`A`, `U`, `F′`, `T`, `C`, `S`, `R`, `Q`), and a per-document counter
("lever C run 4"). The counter was the worst of the three: it restarted per
document, counted invalid runs, and could not be quoted without the document
name. The **alias** column below maps every old label to its ID, so old text
and old photos remain readable.

## 1. Conventions

### 1.1 What counts as an experiment

One **boot of one image under one condition set**. Two boots of the same image
with a different plug state (pre-plug vs cold-plug), a different orientation,
or a different mode (`linux usb` vs normal) are two experiments. A boot that
never happened is `planned`, not an experiment.

### 1.2 ID format

`EXP-NNN` — three digits, assigned in chronological order of the *first
attempt*, zero-padded. Planned experiments are listed with a **reserved**
ID in §2.5; the reserved ID is not reused if the plan changes, and it becomes
a normal registry row on the first execution.

### 1.3 Fields

| field | meaning |
|---|---|
| **ID** | `EXP-NNN`, immutable |
| **date** | local date of the boot (`YYYY-MM-DD`; `YYYY-MM` when only the month is recorded) |
| **series** | `ABL` (bootloader/overlay), `PM` (runtime PM / L2), `UCSI` (AP-side Type-C commands), `ADSP` (firmware / PPM), `B` (PPM ULog capture), `C` (post-PDR full-chain rescan), `REPEATER` (eUSB2 register work) |
| **image** | `KERNEL.ci-…-dbgX`, short md5; `—` if the run used a stock/official image |
| **mode / plug** | `linux usb` or `normal`; `pre-plug` (drive connected before power-on), `cold-plug`, `replug@T`, or `none` |
| **verdict** | code from §1.4 |
| **validity** | `valid`, `invalid` + one-line reason, or `planned` |
| **evidence** | log in `logs/`, or the document/section holding the console transcript |

### 1.4 Verdict codes

| code | meaning |
|---|---|
| `OK-ENUM` | the drive enumerated (`/dev/sdX` appeared) |
| `FAIL-NO-DEV` | no xHCI device existed when the hook looked (hook race, not a hardware verdict) |
| `FAIL-NO-SCAN` | controller alive, scans ran, no connect event (`scan-events=0`) |
| `FAIL-NO-SCAN-FULL` | as above, after the full UCSI→xHCI→dwc3 unbind/rebind chain |
| `FAIL-NO-CLASSIFY` | the PPM never produced a partner/charger classification |
| `FAIL-ROOT-WAIT` | the boot reached the dracut root timeout (the drive was the root) |
| `INVALID` | the run cannot support a conclusion (wrong image, wrong path, confounded orientation…) |
| `PLANNED` | not executed yet |

### 1.5 Rules that came out of the invalid runs

These are process rules, not history — they exist because each one cost a
boot:

1. **Verify the md5 on both sides after flashing**, and keep a distinct
   image filename per version (EXP-028…030 were the same v1 image three times).
2. **Read the `orientation=` line first**; a `reverse` run is a confound
   (EXP-033).
3. **Never hard-code a sysfs driver path** — resolve it from the device's
   `driver` symlink (EXP-032).
4. **An empty scan is a datum, not a failure**: record `scan-events` and the
   role/partner state at the moment of the scan.
5. **A run that cannot be interpreted is still recorded** with its reason;
   silently dropping it makes the next reader repeat it.

## 2. Registry

### 2.1 October 2026 — the ABL / PM / UCSI / ADSP sweep

Individual boots in the October series are summarised in
[INVESTIGATION.md](INVESTIGATION.md) ("Attempts") and the private log; the
IDs below cover the *documented groups*. Images are listed where the record
names one.

| ID | date | series | image | mode / plug | verdict | validity | evidence |
|---|---|---|---|---|---|---|---|
| EXP-001 | 2026-10 | ABL | dbg10–dbg18 | `linux usb`, various | no fix | valid (group) | [INVESTIGATION.md](INVESTIGATION.md) |
| EXP-002 | 2026-10 | UCSI | dbg19–dbg29 | `linux usb` | no fix | valid (group) | [INVESTIGATION.md](INVESTIGATION.md) |
| EXP-003 | 2026-10 | UCSI | dbg30–dbg33 | `linux usb` | `CONNECTOR_RESET` no-op; second variant = invalid port 0 | partly invalid | [RESULTS.md](RESULTS.md#dbg31dbg32--ucsi-command-re-decode-word-layout) |
| EXP-004 | 2026-10 | ADSP | dbg34–dbg38 | `linux usb` | mbn patch blocked by hash/signature; role-switch not the sole gate | valid (group) | [INVESTIGATION.md](INVESTIGATION.md) |
| EXP-005 | 2026-10 | ABL | dbg39–dbg40 | `linux usb`, controlled replug | no fix; `fw_devlink=permissive` no-op | valid (group) | [INVESTIGATION.md](INVESTIGATION.md) |
| EXP-006 | 2026-10-23 | ADSP | dbg41–dbg45 | `linux usb` + normal | re-attach seen, no enumeration in initramfs | valid (group) | [INVESTIGATION.md](INVESTIGATION.md) |
| EXP-007 | 2026-10 | ADSP | dbg46–dbg49 | `linux usb` | BC1.2 stall fingerprint (`ncp_stby`, SM=2) | valid (group) | [ADSP_ULOG.md](ADSP_ULOG.md) |
| EXP-008 | 2026-10 | PM | dbg50 | `linux usb` | INVALID — `power/` path bug in the harness | invalid | [RESULTS.md](RESULTS.md#dbg50--invalid) |
| EXP-009 | 2026-10-26 | PM | dbg51 (md5 `7d04d60f…`) | `linux usb`, pre-plug | L2/runtime-PM class **closed** | valid | [RESULTS.md](RESULTS.md#dbg51--valid-l2pm-class-closed) |

### 2.2 The replug window (letter-labelled runs)

Timing correlation only — kept as supporting evidence, not as a fix (the
target case is pre-plug). Source: [INVESTIGATION.md](INVESTIGATION.md)
("The replug window").

| ID | alias | image | replug at | result | validity |
|---|---|---|---|---|---|
| EXP-010 | A | dbg24 | ~24.7 s | enumerates | valid |
| EXP-011 | U | dbg24 | ~24.7 s (or ~64 s, unverified) | enumerates | valid |
| EXP-012 | F′ | dbg27 | manual, early | enumerates | valid |
| EXP-013 | T | dbg27 | early | enumerates | valid |
| EXP-014 | C | dbg24 | 24.7 s + 82 s | fails (unexplained early failure) | valid |
| EXP-015 | S | dbg40 | 38.12 → 43.15 s | fails | valid |
| EXP-016 | R | dbg39 | 52.35 → 59.39 s | fails | valid |
| EXP-017 | Q | dbg38 | 90.30 → 102.40 s | fails | valid |
| EXP-018 | V | dbg42 (md5 `7fd4e77f…`) | ADSP restart ~11–22 s | EDGE=1, ENUM=0 | valid |
| EXP-019 | W/X/Y/Z | dbg43–dbg46 | zero actions (controls) | no enumeration | valid |

### 2.3 November 2026 — the full-system controls and the fix attempts

| ID | date | series | image | mode / plug | verdict | validity | evidence |
|---|---|---|---|---|---|---|---|
| EXP-020 | 2026-11-05 | ABL | stock | normal, pre-plug | `OK-ENUM` — `usb_type=SDP`, host comes up **after** the PDR | valid (control) | [FULL_SYSTEM_PREPLUG_RESULT.md](FULL_SYSTEM_PREPLUG_RESULT.md) |
| EXP-021 | 2026-11-06 | ABL | stock | normal, pre-plug | `OK-ENUM` — Q1–Q5 answered: the host controller is *created* on the role flip | valid (control) | [FULL_SYSTEM_MECHANISM_CAPTURE.md](FULL_SYSTEM_MECHANISM_CAPTURE.md) |
| EXP-022 | 2026-11-07 | ABL | CI image `a699dd6` (PR #704) | `linux usb`, pre-plug | `FAIL-ROOT-WAIT` — patch 1400 present in the flashed kernel, no enumeration; inconclusive (the CI console is `quiet`, no diagnostics) | valid | [RESULTS.md](RESULTS.md#kernel-patch-1400-in-the-ci-image--linux-usb-pre-plug-2026-11-07) |
| EXP-023 | 2026-11-07 | ABL | dbg1400 (md5 `91ee17b2…`) | `linux usb`, pre-plug | `FAIL-ROOT-WAIT` — patch 1400 fired, port still dead | valid | [KERNEL_PATCH_1400.md](KERNEL_PATCH_1400.md) |
| EXP-024 | 2026-11-08 | ABL | stock | normal, pre-plug | `usb_type=SDP` at PDR + 55 ms | valid (control) | [USB_TYPE_TIMING.md](USB_TYPE_TIMING.md) |
| EXP-025 | 2026-11-08 | ADSP | stock | normal, pre-plug | success-side PPM ULog fingerprint (`PartnerType=2`, SM=4, no `ncp_stby`) | valid (control) | [ADSP_ULOG.md](ADSP_ULOG.md) |
| EXP-026 | 2026-11-09 | B | dbgB (md5 `12a0327f…`) | `linux usb`, pre-plug | `FAIL-NO-CLASSIFY` — detection ran, classification never completed | valid | [RESULTS.md](RESULTS.md#dbgb-run--failing-side-ppm-ulog-capture-2026-11-09--fail-no-classify) |
| EXP-027 | 2026-11-11 | ABL | stock | normal, **source role**, pre-plug | `OK-ENUM` (`sdg` @14.21 s) with the *failing-side* PPM fingerprint ⇒ `usb_type` irrelevant | valid (control) | [FULL_SYSTEM_PREPLUG_SOURCE_ROLE.md](FULL_SYSTEM_PREPLUG_SOURCE_ROLE.md) |

### 2.4 Lever C — the post-PDR full-chain rescan

Images and hook versions: [LEVER_C_IMPLEMENTATION.md](LEVER_C_IMPLEMENTATION.md)
§1 and §10. This is where the old per-document counter lived; the mapping is
1:1 except that EXP-028/029/030 were three boots of the **same** image.

| ID | date | image (md5) | mode / plug | verdict | validity | evidence |
|---|---|---|---|---|---|---|
| EXP-028 | 2026-11-12 | dbgC v1 (`506cb36f…`) | `linux usb`, pre-plug | `FAIL-NO-DEV` @3.3 s | **invalid** — v1 hook written for a forced-host kernel; the controller appears only after the post-PDR role flip | §3.0 |
| EXP-029 | 2026-11-12 | dbgC v1 (the stick still held it) | `linux usb`, pre-plug | `FAIL-NO-DEV` @3.135 s | **invalid** — same hook race; the prepared v2 was never flashed | §3.1 |
| EXP-030 | 2026-11-12 | dbgC v1 (again) | `linux usb`, pre-plug | `FAIL-NO-DEV` @3.299 s | **invalid** — third bit-identical v1 repeat; v3 never flashed | §3.2 |
| EXP-031 | 2026-11-12 | dbgC3 (`9969eda…`) | `linux usb`, pre-plug | `FAIL-NO-SCAN` — 3 fresh scans (2 post-VBUS), `scan-events=0` | valid | §3.3 |
| EXP-032 | 2026-11-13 | dbgC4 (`5704495b…`) | `linux usb`, pre-plug | escalation aborted: wrong hard-coded UCSI driver path | **invalid** — no hardware verdict | §11.1 |
| EXP-033 | 2026-11-13 | dbgC5 (`c08490f9…`) | `linux usb`, pre-plug | `FAIL-NO-SCAN-FULL` | **invalid** — `orientation=reverse` | §11.2 |
| EXP-034 | 2026-11-13 | dbgC5 (`c08490f9…`) | `linux usb`, pre-plug, normal | `FAIL-NO-SCAN-FULL` — clean beta-2 | valid | §11.3 |
| EXP-035 | 2026-11-13 | dbgC6 (`17189737…`) | `linux usb`, pre-plug | `FAIL-NO-SCAN-FULL`; the register dump **stalled silently** after its first line | valid (beta-2); the dump itself invalid | §12.1 |
| EXP-036 | 2026-11-14 | dbgC7 (`8ab490c9…`) | `linux usb`, pre-plug | `FAIL-NO-SCAN-FULL`; the stall **located** in the platform-device symlink resolve | valid (beta-2); dump still incomplete | §12.3 |
| EXP-037 | 2026-11-14 | dbgC8 (`52c888a0…`) | `linux usb`, pre-plug | `FAIL-NO-SCAN-FULL`; **dump complete** — repeater `0-07`, the eight registers are **not** zero | valid | §12.5 |

### 2.5 Planned

| ID | planned experiment | why it decides |
|---|---|---|
| EXP-038 | normal boot of `dbgC8`, stick pre-plugged, dump | the control for the eight registers: same values ⇒ the `31bc94de` regression is **refuted**; `0x00` ⇒ known-good = zero ⇒ zero-out patch |
| EXP-039 | the write ladder on a write-capable kernel: step A (zero the eight) / step B (write the EXP-038 values) | proves or refutes the register-file hypothesis directly |
| EXP-040 | full-boot re-check of the 1400 kernel (protocol: [KERNEL_PATCH_1400.md](KERNEL_PATCH_1400.md#full-boot-re-check-control-experiment--protocol)) | confirms 1400 is a no-op in a normal boot |

### 2.6 Legacy alias map

Old text, old photos and old commit messages use ad-hoc labels. This table
translates them; when in doubt, the `EXP-NNN` in the registry is the
authority.

| legacy label | ID | notes |
|---|---|---|
| `dbg10`–`dbg18` | EXP-001 | ABL/PM group |
| `dbg19`–`dbg29` | EXP-002 | UCSI group |
| `dbg30`–`dbg33` | EXP-003 | `CONNECTOR_RESET` group |
| `dbg34`–`dbg38` | EXP-004 | ADSP group |
| `dbg39`, `dbg40` | EXP-005 | controlled replug |
| `dbg41`–`dbg45` | EXP-006 | re-attach group |
| `dbg46`–`dbg49` | EXP-007 | BC1.2 stall group |
| `dbg50` | EXP-008 | invalid (`power/` path bug) |
| `dbg51` | EXP-009 | L2/PM class closed |
| letter labels `A`, `U`, `F′`, `T`, `C`, `S`, `R`, `Q`, `V`, `W/X/Y/Z` | EXP-010…019 | see §2.2 for the per-letter row |
| "full-system pre-plug" (2026-11-05) | EXP-020 | |
| "mechanism capture" / Q1–Q5 (2026-11-06) | EXP-021 | |
| "CI 1400 test" (2026-11-07) | EXP-022 | the first patched-kernel boot |
| `dbg1400` | EXP-023 | the instrumented repeat |
| "`usb_type` timing" (2026-11-08) | EXP-024 | |
| "ULog boot 1 of 2" | EXP-025 | success-side fingerprint |
| `dbgB` | EXP-026 | failing-side ULog |
| "source-role control" (2026-11-11) | EXP-027 | |
| "lever C run 1" | EXP-028 | v1 hook, hook race |
| "lever C run 2" | EXP-029 | v1 again |
| "lever C run 3" | EXP-030 | v1 a third time |
| "lever C run 4" | EXP-031 | dbgC3, first genuine |
| "lever C run 5" | EXP-032 | dbgC4, wrong UCSI path |
| "lever C run 6" | EXP-033 | dbgC5, `reverse` |
| "lever C run 7" | EXP-034 | dbgC5, clean beta-2 |
| "lever C run 8" | EXP-035 | dbgC6, dump stalled |
| "lever C run 9" | EXP-036 | dbgC7, stall located |
| "lever C run 10" | EXP-037 | dbgC8, dump complete |

## 3. Artifacts

Boot images are **not** committed (≈200 MB each). Each one is reproducible
from a CI base image plus the builder script, and is identified by md5:

| image | size | md5 | builder |
|---|---|---|---|
| CI base (`a699dd6`, extracted) | 203 794 432 B | `9e2fa5376b9e5d395f745b7088da3995` | — (PR #704 artifact) |
| `dbg1400` | 202 106 472 B | `91ee17b24a4a25b78ce49e74a190484e` | [`build_dbg1400_ci.py`](../scripts/lever-c/build_dbg1400_ci.py) |
| `dbgB` | 202 107 190 B | `12a0327f1175439bb2cf5798b0c61384` | [`build_dbgB_ci.py`](../scripts/lever-c/build_dbgB_ci.py) |
| `dbgB2` (base of the C series) | 202 107 571 B | `62c84617968a0adfc97a5e2926568c98` | [`build_dbgB2_ci.py`](../scripts/lever-c/build_dbgB2_ci.py) |
| `dbgC` (v1) | 202 110 046 B | `506cb36f9eadd0459d064ac2f4883927` | [`build_dbgC_ci.py`](../scripts/lever-c/build_dbgC_ci.py) |
| `dbgC2` (v2, never booted) | 202 111 747 B | `ab8621850dabacb25e851f8b19f8f7ac` | [`build_dbgC2_ci.py`](../scripts/lever-c/build_dbgC2_ci.py) |
| `dbgC3` (v3) | 202 112 128 B | `9969edaff95d75c4766d84919d82cbb7` | [`build_dbgC3_ci.py`](../scripts/lever-c/build_dbgC3_ci.py) |
| `dbgC4` (v4) | 202 114 227 B | `5704495b563cd991102264581eb4e9e7` | [`build_dbgC4_ci.py`](../scripts/lever-c/build_dbgC4_ci.py) |
| `dbgC5` (v5) | 202 114 351 B | `c08490f9f3d7d9eb1440a175e597d6f5` | [`build_dbgC5_ci.py`](../scripts/lever-c/build_dbgC5_ci.py) |
| `dbgC6` (v6) | 202 115 458 B | `17189737e7ac022ab617b2f7598f0a0e` | [`build_dbgC6_ci.py`](../scripts/lever-c/build_dbgC6_ci.py) |
| `dbgC7` (v7) | 202 117 568 B | `8ab490c97a47c04770ee06814f4d3038` | [`build_dbgC7_ci.py`](../scripts/lever-c/build_dbgC7_ci.py) |
| `dbgC8` (v8) | 202 116 935 B | `52c888a01f0470fb35f2b1a028209e9f` | [`build_dbgC8_ci.py`](../scripts/lever-c/build_dbgC8_ci.py) |

Every image satisfies the same invariants (asserted by its builder):
`ANDROID!` magic, header `[20:576]` byte-identical to the base, kernel
byte-identical, SHA1 id recomputed at offset 576, and an initramfs
round-trip that replaces exactly one hook entry.

## 4. Related

- Hook sources: [`scripts/lever-c/`](../scripts/lever-c/) (v6/v7/v8 and the
  fake-sysfs harness)
- Console transcripts: [`logs/lever-c/`](../logs/lever-c/)
- Narrative of the lever-C series:
  [LEVER_C_IMPLEMENTATION.md](LEVER_C_IMPLEMENTATION.md)
- Chronology of the whole investigation: [TIMELINE.md](TIMELINE.md)
