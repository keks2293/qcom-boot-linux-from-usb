# ULog diff (working E vs failing dbgB) — the residual blocker is the eUSB2 **data path**, not classification, VBUS, or ordering

Status: **analysis of two already-recorded boots** (no new hardware run).
Diffed the PPM ULog of the **working** full-system pre-plug control
([EXP-027](EXPERIMENTS.md), boot "E", 2026-11-11) against the PPM ULog of the
**failing** `linux usb` pre-plug run
([EXP-026](EXPERIMENTS.md), `dbgB`, 2026-11-09), plus the xHCI bus events of
each. It localizes the residual blocker to the **eUSB2 D+/D− data path** and
refutes classification, VBUS, and host-bring-up ordering as the fix. It is the
evidence base for the repositioning of the
[`apsd-rerun-cfg`](ADSP_CONFIG.md) patch (diagnostic, not the fix) and for the
next instrumented boot, [EXP-042](EXPERIMENTS.md).

Raw files:

- Working (E, EXP-027):
  [`logs/preplug-source/e-normal-success-20261111-172918/ppm-ulog-boot.full.log`](../logs/preplug-source/e-normal-success-20261111-172918/ppm-ulog-boot.full.log)
  (2239 lines, 1798 PPM events) and
  [`…/usb-events.txt`](../logs/preplug-source/e-normal-success-20261111-172918/usb-events.txt)
  (xHCI port-change / enumeration timeline).
- Failing (dbgB, EXP-026):
  [`logs/dbgB-preplug-usb-ulog-20261109.txt`](../logs/dbgB-preplug-usb-ulog-20261109.txt)
  (68 lines — the lever-B *filtered* PPM ULog + `usb_type` poller).
- Repeater register dumps:
  [`logs/lever-c/exp-037-dump.txt`](../logs/lever-c/exp-037-dump.txt) (broken),
  [`logs/lever-c/exp-038-dump.txt`](../logs/lever-c/exp-038-dump.txt) (working).

## TL;DR

- The two boots are **identical in every physical variable** — source role,
  host data role, `normal` orientation, **direct stick** (no PD partner),
  **pre-plug** — and differ only in the **environment**: E boots the full
  system (stock kernel 7.2.6), dbgB boots the `linux usb` initramfs
  (patch-1400 kernel). E **enumerates**, dbgB **never does**. The discriminator
  is therefore the environment, not role, partner, orientation, or the
  firmware byte.
- The PPM's **full** ULog in the *working* boot logs **no**
  eUSB2 / repeater / HSIC / route / mux / lane / SS-PHY action at all (keyword
  sweep below). **Data-path routing is not a PPM-logged action** — it cannot be
  found in the ULog and must be read at the register level.
- The PPM **fingerprint is bit-for-bit the same** in both boots (partner
  detected, `otg enable: 1`, `otg source = 1`, VBUS ≈ 5.06 V,
  `skip checking usb charging type while usb is sourcing`, ICM parked in
  `ncp_stby`, `usb_type=[Unknown]`). **Classification is not the blocker.**
- **VBUS is physically driven in the failing boot** (5.061 V, `otg source = 1`)
  — this **corrects** the earlier
  [`dbg1400` "no VBUS / electrically dead"](KERNEL_PATCH_1400.md) phrasing. The
  port is not dead for *power*; it is dead for *data*.
- The **only** divergence is on the xHCI side: E's USB2 root port reports a
  **connect** (port change, connect bit set) and enumerates; dbgB's port
  **never** reports a connect (no port-change event after VBUS). The eUSB2
  repeater's seven activity registers are all `00` in the broken mode
  ([EXP-037/038](LEVER_C_IMPLEMENTATION.md)) — the D+/D− link **never reaches
  the repeater**.
- **Host-bring-up ordering is not the discriminator**: *both* pre-PDR xHCI
  (stock kernel, the original runs) and post-PDR xHCI (patch-1400 kernel:
  `dbg1400`, `dbgB`, EXP-037) fail in the initramfs; only the full system
  (post-PDR) succeeds. Re-ordering the first xHCI init to after the PDR — the
  cleanest form of the "launch-order" fix — has been run (EXP-037) and does not
  enumerate.
- Consequence: the
  [`apsd-rerun-cfg` 0→1](ADSP_CONFIG.md) firmware patch re-arms
  *classification*, but classification is not the blocker — **it is not the fix
  for enumeration**. It remains a useful **diagnostic** (its re-detection is
  what would drive the seven activity registers if a link did reach the
  repeater), not the cure. The cure is on the **data-path / environment** side.

## The clean isolation (E vs dbgB)

| variable | E (works) | dbgB (fails) |
|---|---|---|
| environment | **full system** (stock kernel 7.2.6) | **`linux usb` initramfs** (kernel `a699dd6`, patch 1400) |
| power role | source (`power_role=[source]`) | source (`power=[source]`) |
| data role | host (`data_role=[host]`) | host (`data=[host]`) |
| orientation | normal | normal |
| partner | **direct stick**, `supports_usb_power_delivery=no` | **direct stick**, `TypeCPartnerType=0` (USB2, no PD) |
| pre-plug | yes (connected before power-on) | yes (connected before power-on) |
| xHCI vs PDR | post-PDR (PDR 12.454 s → first port change 12.787 s) | post-PDR (1400 demotes to OTG; xHCI appears after the PDR role flip) |
| result | **enumerates** (usb 1-1 @13.05 s → sdg) | **never enumerates** |

Everything physical is held constant; only the environment moves. That is the
sharpest possible isolation of the "environment" discriminator, and it is the
datum the "both failed" result (direct stick **and** PD dock both fail in
`linux usb`, while the same dock works in the full system) was driving at:
role/partner are out, the `linux usb` environment is in.

## Finding 1 — the PPM does not log data-path routing

Keyword sweep over E's **full, unfiltered** PPM ULog (all 2239 lines):

| keyword family | lines |
|---|---|
| `eusb` | 0 |
| `repeater` | 0 |
| `hsic` | 0 |
| `route` | 0 |
| `mux` | 0 |
| `lanes` | 0 |
| `ssphy` | 0 |
| `tcpc` | 14 — **all** the periodic `tcpci_clear_alert` (`AlertToClear=0xFFEF, currAlert=0x0010`), ~one every 2 s; an alert *clear*, not a routing write |

So even in the boot that *works*, the PPM never logs an eUSB2/route/mux/HSIC
action. The data path is opened (or not) by a **register-level** action that is
invisible in the ULog. (The `dbgB` capture used a narrow `INCLUDE` filter —
`PartnerType|charger_detection|sm_state_loop|ncp_stby|…` — so *absence* in
dbgB is a filter artifact, not evidence; but E's unfiltered log proves routing
is not a logged action in the working mode either, which is the point.)

## Finding 2 — the PPM fingerprint is identical (the phase table)

| phase | E (works) | dbgB (fails) |
|---|---|---|
| ADSP up / `charger_pd` PDR | 12.398 s / **12.454 s** | ~3.4 s / **3.498 s** |
| `typec_detect_partner` (`TypeCPartnerType=0`) | 12.742 s | 5.346 s |
| `otg enable: 1` | 12.742 s | 5.362 s |
| `otg source = 1` | 12.742 s | 5.364 s |
| VBUS measured | ≈ 5.06 V | **5.061 V** (`V=5061000`) |
| ICM parked in `ncp_stby` ("…untill charger_type updated") | yes | yes |
| `skip checking usb charging type while usb is sourcing` | 25.02 s | 17.67 s |
| `usb_type` | `[Unknown]` | `[Unknown]` |
| xHCI connect on the USB2 root port | **port change 1-1 @12.828 s** (`portsc 0xa0206e1`, connect bit set) → `usb 1-1: new high-speed` @13.05 s | **none** — no port-change event after VBUS |

Both boots run the *same* PPM state machine to the *same* (unclassified,
`ncp_stby`) steady state, and both drive VBUS. The working boot's drive
enumerates **despite** `usb_type=[Unknown]` + `ncp_stby` + the
skip-while-sourcing gate — so none of that classification machinery is what
lets the link through.

## Finding 3 — the divergence is the xHCI D+/D− connect

- **E:** `xhci-hcd xhci-hcd.2.auto: Port change event, 1-1 … portsc: 0xa0206e1`
  (connect status set) @12.828 s → `0x200e03` (port enabled) @12.980 s →
  `usb 1-1: new high-speed USB device` @13.05 s → `usb-storage 1-1:1.0`
  @13.20 s → `sdg`.
- **dbgB:** after VBUS is on (5.36 s) there are **no** `Port change` /
  `new high-speed` / `usb 1-1` events at all — the USB2 root port **never**
  sees the stick's D+/D− pull-up.
- **Repeater** (EXP-037 broken vs EXP-038 working): the eight never-kernel-
  written *tuning* registers (`fd50..fd5b`) are **bit-identical** between the
  modes (the repeater is enabled and configured in both), but the seven
  never-AP-written *activity* registers (`fd00 fd02 fd04 fd05 fd09 fd0a fd42`)
  are **all `00`** in the broken mode and non-zero in the working one
  (`fd00=02 fd02=03 fd04=0b fd05=0e fd09=9f fd0a=18 fd42=80`). The link never
  reaches the repeater's input in `linux usb`.

So VBUS reaches the port (the stick is powered) but D+/D− does **not** reach
the SoC's eUSB2 PHY/repeater. That is the signature of an **unrouted data
path**, not a power, classification, or scan-timing fault.

## Finding 4 — host-bring-up ordering is not the discriminator

| xHCI first-init order | environment | result |
|---|---|---|
| **pre-PDR** (forced HOST by ABL `dr_mode=host`, stock kernel; port-change 2.716/3.182 s vs PDR 3.498 s) | initramfs | fails |
| **post-PDR** (patch 1400 demotes to OTG; xHCI appears after the PDR role flip — `dbg1400`, `dbgB`, and EXP-037, where `xhci=ABSENT` at 3 s and appears post-PDR) | initramfs | fails |
| **post-PDR** (full system, stock kernel; PDR 12.454 s → port change 12.787 s) | full system | **works** |

The cleanest form of the "launch-order" fix — *no early init at all, first xHCI
init after the charger PDR* — is exactly what the patch-1400 kernel does, and
it has been run on hardware (EXP-037) without enumerating. Re-probing the host
post-VBUS (lever C, EXP-034) also failed. **Ordering is necessary-looking but
not the cause**; the same post-PDR order works in the full system and fails in
the initramfs, so the environment — not the order of the xHCI init — is what
discriminates.

## Finding 5 — the `apsd-rerun-cfg` patch is not the fix for enumeration

The patch ([recipe in ADSP_CONFIG.md](ADSP_CONFIG.md)) enables an **edge-free
re-arming of BC1.2 classification** (`pmic_glink → dpm_usbc → SetRerunApsd`).
But the working boot enumerates with the *same* unclassified fingerprint
(`usb_type=[Unknown]`, `ncp_stby`, skip-while-sourcing) that the patch would be
trying to clear. **Classification is not what gates the link**, so a
classification re-arm cannot be the cure for a link that is being blocked at
the data path. The patch is repositioned to **diagnostic**: booting it in
`linux usb` pre-plug and reading the seven repeater activity registers answers
*"does a re-armed PPM drive a link to the repeater"* — a clean probe of whether
the PPM *can* route the data path when re-armed, independent of the ABL
environment. It is a probe, not the fix.

## Refined hypothesis — the ABL USB-boot session leaves the eUSB2 data path unrouted

The one environment factor specific to `linux usb` mode that **touches this
port before the kernel** is the ABL's own closed USB host session (it reads
`\KERNEL` from the drive) plus the ABL's port/PHY/TCPC configuration for USB
boot (the `dr_mode=host` overlay is part of this but has been demoted by 1400
and shown not to be the cause). The refined model:

1. In `linux usb` mode the ABL drives the port as a host for its own boot
   session and leaves the PPM/TCPC/PHY in a data-path state that does **not**
   route the connector D+/D− to the SoC's eUSB2 PHY/repeater.
2. At kernel handoff there is **no fresh CC edge** (the stick is pre-plugged)
   and the PPM data-path state is **sticky** — nothing re-routes D+/D− to
   eUSB2 for the kernel's xHCI. (UCSI is active in both environments, so this
   is not an actor-presence issue.)
3. The PPM still drives **VBUS** (5.06 V, `otg source = 1`) and reaches the
   same unclassified `ncp_stby` steady state as the working boot — so power and
   classification look healthy, but **D+/D− is not routed** and xHCI never
   detects a connect.
4. In the full system the ABL never runs a host session on the port, so the
   data path is routed cleanly and the pre-plugged stick enumerates on the
   first post-PDR scan.

This is consistent with every measured result: pre-plug fails in `linux usb`
for **both** a direct stick and a PD dock (the ABL host session runs in both),
while the same dock pre-plugs fine in the full system (no ABL host session).

It is a sharpening of the original "ABL host session blocks initial
classification" hypothesis ([KERNEL_PATCH_1400.md](KERNEL_PATCH_1400.md)): the
ABL session's residue is now localized to the **D+/D− data-path routing**, not
the charger classification.

## Next experiment — EXP-042: localize the closed routing element

To turn the hypothesis into a fix, find **which** routing element stays closed
in the failing mode. Instrument a failing (`linux usb`, pre-plug) boot and a
working (full-system, pre-plug) boot and read, in both:

- **TCPC data-routing registers** (PMIC) — is the connector D+/D− routed to
  eUSB2? (orientation is reported `normal` in both, so this is the suspect.)
- **eUSB2 repeater** registers (PMIC SPMI window `0xfd00–0xfd5b`) — already
  captured by [EXP-037/038](LEVER_C_IMPLEMENTATION.md); re-read in the same run
  for a paired comparison.
- **SNPS eUSB2 PHY** registers (SoC, `qcom,sm8550-snps-eusb2-phy` @ `0x88e3000`)
  — is the PHY powered up / in the correct state?
- **PMIC eUSB2 switch/mux** (if present) — is a PMIC-level data switch closed?
- **xHCI / SS-PHY** power + clock state.

The element that is "open/enabled" in the working boot but "closed/disabled"
in the failing boot is the fix target (drive it open early in the initramfs, or
re-route the data path after the ABL handoff).

Capture: extend
[`scripts/lever-c/exp038-repeater-dump.sh`](../scripts/lever-c/exp038-repeater-dump.sh)
into a routing dump (repeater window + TCPC + SNPS eUSB2 PHY + switch) that runs
as root in **both** environments and is diffable. Registered as
[EXP-042](EXPERIMENTS.md).

## References

- Clean working reference: [FULL_SYSTEM_PREPLUG_SOURCE_ROLE.md](FULL_SYSTEM_PREPLUG_SOURCE_ROLE.md)
- ABL `dr_mode=host` overlay + fix options: [ABL_DR_MODE_HOST.md](ABL_DR_MODE_HOST.md)
- Patch-1400 (OTG demotion) + the original ABL-host-session hypothesis:
  [KERNEL_PATCH_1400.md](KERNEL_PATCH_1400.md)
- Repeater register dumps + lever-C narrative: [LEVER_C_IMPLEMENTATION.md](LEVER_C_IMPLEMENTATION.md)
- `apsd-rerun-cfg` patch recipe + timer/replug correlation: [ADSP_CONFIG.md](ADSP_CONFIG.md)
- PPM/ADSP RE (wedge state, re-trigger paths): [ADSP_RE.md](ADSP_RE.md)
- Living investigation: [INVESTIGATION.md](INVESTIGATION.md); registry:
  [EXPERIMENTS.md](EXPERIMENTS.md)
