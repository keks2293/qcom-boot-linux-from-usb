# Full-system pre-plug result (Cell II)

Measured: **2026-11-05 22:13–22:17 (+08)**, Retroid Pocket 6 (QCS8550 / SM8550),
Armada full system, kernel `7.2.6 #1 SMP PREEMPT aarch64`, booted from internal
storage (`composefs overlay`). Repo commit `5f6440d`.

Raw logs:

- [`logs/full-system/preplug-capture-20261105-221345.log`](../logs/full-system/preplug-capture-20261105-221345.log) — full evidence capture
- [`logs/full-system/preplug-script-20261105-221734.log`](../logs/full-system/preplug-script-20261105-221734.log) — `scripts/full-system-coldplug-test.sh` output

Setup: USB-C hub/dock (214b:7250 hub; Microchip hub controller + Steam
Controller + keyboard) connected **before power-on**, with the Netac
`MobileDataStar` flash drive behind it (`1-1.2`) and mounted as `Slim`.
This is the primary pre-plug variant.

## The drive was really pre-plugged

There is exactly **one** attach of the dock (`usb 1-1: new high-speed USB
device` at **15.065 s**) and **no** `USB disconnect` / re-enumeration event
after it. The drive follows the dock:

| T (s) | event |
|---:|---|
| 15.065 | `usb 1-1` dock/hub enumerated |
| 15.967 | `usb-storage 1-1.2` (Netac drive) detected |
| 16.990 | `scsi 1:0:0:0` Netac MobileDataStar |
| 16.991 | `sd 1:0:0:0: [sdg]` 500 GB |
| 17.030 | `sdg: sdg1 sdg2`, attached |

The graphical session only starts at ~18.1 s, so the drive was enumerated
during boot, not plugged by the user afterwards.

## Boot timeline

| T (s) | event |
|---:|---|
| 0.30–3.14 | `qcom_pmic_glink pmic-glink` probes (`/pmic-glink/connector@0`) |
| 3.53 | `sysroot.mount` mounted |
| 4.03 | initramfs `initrd-switch-root` |
| 9.97 | `remoteproc0: powering up adsp` |
| 10.35 | `remoteproc0: remote processor adsp is now up` |
| **10.41** | **`PDR: Indication received from msm/adsp/charger_pd`** (`0x1fffffff`) |
| **14.81** | **`xhci-hcd.2.auto`: xHCI host registered** (bus 1 and 2) |
| 15.07 | dock `1-1` enumerated |
| 15.97 | usb-storage `1-1.2` detected |
| **16.99** | **drive `sdg` enumerated** |
| 17.71 | `user@1000` starts; 18.10 graphical session |

So in the full system the host controller comes up **4.4 s after** the
`charger_pd` PDR (on this boot; the gap varies — 2.7–4.4 s across boots, it is
a UCSI ↔ ADSP round trip, see
[FULL_SYSTEM_MECHANISM_CAPTURE.md](FULL_SYSTEM_MECHANISM_CAPTURE.md)), and the
drive enumerates 2.2 s after the host controller.

## State at capture

### Classification / roles

| item | full system (pre-plug) | initramfs (repo, dbg49/dbg50/dbg51) |
|---|---|---|
| `qcom-battmgr-usb/usb_type` | `Unknown **[SDP]** DCP CDP ACA C PD PD_DRP PD_PPS BrickID` → current **SDP** | `[Unknown]` |
| `ucsi-source-psy…/usb_type` | `C **[PD]** PD_PPS` → current **PD** | no PD contract |
| Type-C port | `port0` + `port0-partner` present | `port0` present in spliced runs |
| `data_role` | `[host] device` | `[host] device` (dbg49) |
| `power_role` | `source [sink]` → current **sink** | `[source] sink` (dbg49) |
| `power_operation_mode` | `usb_power_delivery` | — |
| PD partner | `supports_usb_power_delivery: yes` | role commands refused/`-ECOMM` (dbg31) |
| PD contract | 9.03 V, input limit 2.44 A | 5.06 V (dbg49) |
| `usb_role` | `host` | host |

Bracketed values are the current ones (`[SDP]`, `[PD]`, `[host]`, `[sink]`).
The full-system port is therefore **classified and PD-negotiated with the
dock**; the initramfs port reported `Unknown` and stayed in `icm_ncp_stby`.

### PM / L2 (still closed)

| device | control | runtime_status | autosuspend_delay_ms |
|---|---|---|---|
| `soc@0/a600000.usb` (glue) | `auto` | `active` | `5000` |
| `…/xhci-hcd.2.auto` | `on` | `active` | `0` |
| `…/xhci-hcd.2.auto/usb1` (HS bus, drive here) | `auto` | `active` | `0` |
| `…/xhci-hcd.2.auto/usb2` (SS bus) | `auto` | `suspended` | `0` |

This matches the predicted working-environment values (`glue=auto/active/5000`,
`xhci=on/active/0`) and keeps the L2/runtime-PM class closed. The full-system
cmdline does **not** contain `usbcore.autosuspend=-1` (the dbg51 diagnostic
image did), so the root-hub delays differ from dbg51, but the HS bus carrying
the drive is active.

### Modules / kernel

`qcom_battmgr`, `qcom_q6v5_pas` and the `qcom_q6v5*` dependencies are loaded.
`CONFIG_TYPEC=y`, `CONFIG_TYPEC_UCSI=y`, `CONFIG_UCSI_PMIC_GLINK=y`,
`CONFIG_USB_ROLE_SWITCH=y`, `CONFIG_USB_DWC3_DUAL_ROLE=y`. RPM tracing was not
mounted.

## What this changes

1. **The full-system pre-plug port is classified (`SDP`, PD-capable), while the
   initramfs port is `Unknown`.** This is the fork-test outcome that the test
   doc maps to "early BC1.2 classification / PPM nudge in initramfs".
2. **Two predictions in the repo are contradicted and need syncing:**
   - `qcom_battmgr` is *not* dead in the full system — the module is loaded and
     the USB power supply is present (`usb_type=SDP`, `online=1`).
   - UCSI is *not* deferred in the full system — `port0`, `port0-partner`, the
     UCSI source power supply and a PD contract all exist. UCSI active vs
     deferred is therefore not the discriminator (consistent with the dbg31/dbg32
     spliced-run result: active UCSI alone did not fix the wedge).
3. **The ordering of host-controller bring-up vs the charger-PDR differs.**
   - Full system: `charger_pd` PDR **10.41 s** → xHCI host **14.81 s** → dock
     **15.07 s** → drive **16.99 s**.
   - Initramfs (dbg49): USB port-change events at **2.716 / 3.182 s**, xHCI/root
     hubs already up from ~0.5 s, `charger_pd` PDR **3.498 s** — i.e. the host
     events happen **before** the charger service is ready, and there are no new
     bus events afterwards.
   This unifies the observations: a fresh port/CC event **after** the PPM/charger
   service is ready works (the replug window ≤ ~30 s), and the full system's late
   xHCI/dwc3 bring-up is such an event; in the initramfs the only boot-time host
   events happen too early and are lost, so nothing re-arms classification.

### Candidate mechanism (needs the targeted test)

The full system does not need a user replug because its USB host controller is
initialised **after** the ADSP `charger_pd` service is up; the host bring-up
(role/VBUS transition) is processed by the PPM, the pre-plugged dock is
classified (`SDP`, PD-capable), the data path opens and the drive enumerates.
In the initramfs the controller is initialised first; the PPM misses that
transition, no later event re-arms detection, and the ICM stays in
`icm_ncp_stby`.

This is a timing correlation, not yet a causal proof: the full system has no
per-event PPM/CC log, and the exact `usb_type` transition time was not recorded
(steady state was read at 22:13, 22 min after boot with no disconnect). The
full-system and initramfs DTBs also differ in details (full system names the
controller `xhci-hcd.2.auto`, the dbg images use `xhci-hcd.0.auto`; the
full-system cmdline lacks `usbcore.autosuspend=-1`), so verify the DT/build
before treating the ordering alone as the only variable.

## Next experiment (falsifiable, no user replug)

1. **Re-probe the host inside the window.** In the initramfs, after the
   `charger_pd` PDR (~3.5 s) and before the ~30 s window closes, force a
   host-controller/role re-probe (unbind/bind `dwc3-qcom` + `xhci-hcd`, or a
   role/VBUS cycle) at ~4–6 s. dbg49's driver re-probe ran at >32 s — outside
   the window — and produced no new bus events. If enumeration appears, the
   ordering hypothesis is confirmed.
2. **Log the transition.** Add an early boot logger (systemd service or udev
   rule) sampling `qcom-battmgr-usb/usb_type`, `typec/port0/{data,power}_role`
   and `usb_role` at high frequency, then repeat the pre-plug full-system boot
   to capture the exact `Unknown → SDP` transition time relative to xHCI.
3. **Match the topology.** The full-system capture had the drive behind a
   USB-C dock with PD; confirm the failing initramfs runs used the same dock
   (not a directly attached stick). If they differed, repeat the full-system
   capture with a direct stick as well.
4. If (1) works, the fix direction is to delay or re-trigger host-controller
   initialisation until after the ADSP charger service is ready; the
   `apsd-rerun-cfg` 0→1 patch remains the firmware-side alternative.
