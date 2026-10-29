# Investigation

## Goal

Understand why a USB flash drive fails to enumerate on cold-plug when booting in `linux usb` mode into the initramfs on RP6/QCS8550, while enumerating fine from a full system boot with cold-plug.

## Methodology

1. **Reproduce in initramfs** using custom `KERNEL` images with diagnostics injected into `dracut-initqueue`
2. **Isolate variables**: PM policy, RPM tracing, UCSI/PPM probes, ADSP restart, role-switch, devlink
3. **Verify images**: match Android boot header, only `dracut-initqueue` changes, recalculate sha1 id, check DTB splices
4. **Read raw markers from screen photos** (cold-plug, zero user actions, `linux usb` mode)

## Hypotheses tested

| ID | Hypothesis | Status | Notes |
|---|---|---|---|
| P-01 | XBL/ABL handoff leaves controller/PHY in bad state | Mostly ruled out | ADSP restart showed re-attach events but no enumeration |
| P-06 | ADSP/PPM BC1.2 classification blocks data path until charger type updated | **Strong candidate** | `icm_ncp_stby_main: keeps in icm_ncp_stby until charger type updated`, `chgr_stat=7`, `charger_present=0`. PPM = "Platform Policy Manager" (UCSI 2.0 spec term); `icm_ncp_stby` is an ADSP-internal state (NCP = "No Charging Port", BC1.2) — not publicly documented anywhere else. Firmware RE (see below) pinned the re-trigger paths: a fresh CC edge, USB suspend→resume (dead, tied to ADSP restart), or a charger-detection SM event (event 0x25 broadcast; HW IRQ **or** AP glink). The ADSP side processes all of them unconditionally — the remaining gap is AP-side |
| H1 | HW CC arming / functional processing gated by an AP-ready runtime flag in the ADSP firmware | **Refuted (RE)** | The three "runtime flag globals" (ULog enable mask / level / verbosity counter) are **ULog logging controls**. Full write-site analysis: set at ADSP boot (`BattMngr_init` → ULog client init, mask `0x3FFFFFFF`, level 3) and reconfigurable by the AP over glink (ULOG type-0x19). Every "gate" site investigated is a log gate; the functional code (state writes, `callr` dispatch, glink intent processing) runs unconditionally |
| L2/PM | Glue/XHCI enter runtime suspend/L2 and block enumeration | **Closed (dbg51)** | Observed in all tested PM states; blocked by root-hub autosuspend policy and child counts |
| battmgr | Missing `qcom_battmgr` module in initramfs prevents BC1.2 classification | **Refuted (code + disk)** | `qcom_battmgr.ko` is already present in the CI initramfs (dracut `--no-hostonly`) and is auto-loaded by udev via `alias auxiliary:pmic_glink.power-supply qcom_battmgr`; battery psys are alive in every initramfs run (dbg48). Explicit `add_drivers` changes nothing |
| VBUS-reg | Cycling a connector VBUS regulator generates a fresh CC edge | **Refuted (code)** | No VBUS regulator node exists in the RP6 device tree; the `qcom_usb_vbus-regulator` driver matches only `qcom,pm8150b-vbus-reg` (RP5-family boards). The 5 V output is generated on the ADSP/PMIC side; no AP-side sysfs lever exists |
| devlink | `fw_devlink` strict/permissive affects probe order | Checked | No supplier waiting observed |
| role-switch | `usb-role-switch` missing/present affects UCSI/PPM | Tested | Not the sole gate |

## Attempts

| Attempt | Focus | Result |
|---|---|---|
| dbg10–dbg18 | Bus events, runtime PM, hub state | Probed topology; ruled out simple "hub flip" |
| dbg19–dbg29 | Cmdline, UCSI probes, port control | AP-side UCSI SETs mostly rejected or ineffective |
| dbg30–dbg33 | Type-C role swaps, CONNECTOR_RESET, baseline monitoring | No enumeration fix |
| dbg34–dbg38 | ADSP DTB patch attempts, dynamic debug, role-switch splice/revert | Hash/signature constraints blocked mbn patch; role-switch not sole gate |
| dbg39–dbg40 | Controlled replug window, `fw_devlink=permissive` test | No reliable enumeration fix |
| dbg41–dbg45 | ADSP remoteproc stop/start, stock-method replication | Re-attach observed but no enumeration in initramfs |
| dbg46–dbg49 | UCSI-active-gate, ADSP fingerprinting, block watchers | Confirmed BC1.2 stall fingerprint |
| dbg50 | L2 cycle attempt (harness had path bug) | Invalid due to `power/` path bug |
| dbg51 | L2 cycle with correct paths + `events/rpm` tracing | **L2/PM class closed** |

## The replug window (timing correlation)

With the stick pre-plugged at power-on the enumeration always fails. Unplugging
and re-plugging (a fresh CC edge) **works below ~30 s after power-on and fails
above ~38 s** — zero user actions otherwise, same stick, same image:

| run | image | replug delay after power-on | result |
|---|---|---|---|
| A | dbg24 | ~24.7 s | enumerates |
| U | dbg24 | ~24.7 s (or ~64 s, unverified) | enumerates |
| F′ | dbg27 | manual re-plug (early) | enumerates |
| T | dbg27 | early | enumerates |
| C | dbg24 | 24.7 s + 82 s | fails (unexplained early failure) |
| S | dbg40 | 38.12 → 43.15 s | fails |
| R | dbg39 | 52.35 → 59.39 s | fails |
| Q | dbg38 | 90.30 → 102.40 s | fails |
| V | dbg42 | ADSP restart ~11–22 s | no enumeration (EDGE=1, ENUM=0) |
| W/X/Y/Z | dbg43–46 | zero-action controls | no enumeration |

The ~30 s boundary numerically matches the PPM config
`chg-heartbeat-timer-ms = 30000` (and the ~40 s failure start matches
`poll-timer-ms = 40000`) — see
[ADSP_CONFIG.md](ADSP_CONFIG.md#timer--replug-correlation). This is a
correlation, not a proof: the mechanism is a PPM/BC1.2 classification window,
and the candidate fix is the `apsd-rerun-cfg` 0→1 config patch
([ADSP_CONFIG.md](ADSP_CONFIG.md#the-1-byte-patch-recipe-verified-by-trial-patch)).

## Actor hunt: statically negative in all 4 zones

The question "what actor re-triggers PPM in the working environment?" was
searched statically in all four zones that could contain one:

1. **AP kernel** (v7.2.6): no driver writes a "re-detect" trigger; the UCSI
   path only carries role/power commands (all refused or no-op on this device)
2. **initramfs userspace** (stock dracut cpio, fully extracted: 3092 records,
   655 modules, 62 udev rules, 140 systemd units): no actor touches
   `typec`/`usb_role`/glink for re-trigger; the `armada-adsp` dracut module is
   a passive firmware-file pack
3. **rootfs userspace** (armada): no actor writes `usb_role` for host
   enumeration (only the user-initiated MTP gadget), no QMI client, no
   `SUBSYSTEM=="typec"` udev rule; the charge-debug tool is read-only
4. **ADSP firmware** (RE): all re-trigger paths are event-driven (fresh CC
   edge, USB suspend→resume, event 0x25 broadcast) — no free-running/periodic
   mechanism in this build (the periodic APSD rerun is dead code, 0 refs)

Consequence: the difference between the working (full system, late replug)
and dead (initramfs) environments is most likely **what the AP sends over
glink** (charger-type intents, ULOG config, battmgr notifications) — an
unmeasured gap; the decisive experiment is the full-system pre-plug vs
post-plug fork ([FULL_SYSTEM_COLDPLUG_TEST.md](FULL_SYSTEM_COLDPLUG_TEST.md)).

## PPM/ADSP firmware reverse engineering

Full write-up: [ADSP_RE.md](ADSP_RE.md); config: [ADSP_CONFIG.md](ADSP_CONFIG.md);
raw evidence: [`logs/adsp-re/`](../logs/adsp-re/); tools:
[`scripts/adsp-re/`](../scripts/adsp-re/). Summary of the code facts:

- **The wedge state** `icm_ncp_stby_main` @0x601a1790 is an event dispatcher
  (state gate `field_c == 2`, jump table events 7..0x18, event 24 = periodic
  tick — matches the diag `curr=2 next=2` / `event_type=24`).
- **Detection chain** into `charger_detection_inital_detection` @0x60152970 is
  narrow and event-driven (one caller per level); entry = event 0x25
  broadcast with 9 subscribers; the broadcast is emitted from exactly 3 HW
  IRQ setup paths (scp_qchg/QBG_R1, Schg PDPhy R1, smb139x) — plus the AP
  glink RX entry.
- **glink RX is unconditional**: `pmic_glink_rx_intent_req` @0x60088cd0 queues
  the intent (QDI) without any flag check; `pmic_glink_ulog_process_rx_data`
  @0x600872f0 accepts ULOG config type-0x19 from the AP.
- **No functional flag gate exists** (H1 refuted): the three suspected
  "runtime flag globals" are ULog logging controls; every gate site is a log
  gate. Details in [ADSP_RE.md](ADSP_RE.md#headline-finding-the-runtime-flag-wall-is-ulog-logging-h1-refuted).
- **APSD re-run mechanism present but config-disabled**: `PmSchgUsb_SetRerunApsd`
  @0x600978e0 + "adsp rerun" virtual @0x6015b6a0; the periodic variant is dead
  code; `apsd-rerun-cfg = 0` in the PPM FDT (all public firmwares).

## Key code facts (v7.2.6)

| Fact | Reference | Notes |
|---|---|---|
| Root hubs get `autosuspend_delay = usb_autosuspend_delay*1000` | `drivers/usb/core/usb.c:68-69, 744-745` | `usbcore.autosuspend=-1` => `-1000` |
| Root hubs named `usb%d`, parent = HCD controller | `drivers/usb/core/usb.c:696-701` | `usb1/usb2` are root hubs |
| RPM blocks on `usage_count>0` (-EAGAIN) or `child_count>0` (-EBUSY) | `drivers/base/power/runtime.c:271-284` | `rpm_check_suspend_allowed` |
| `pm_runtime_forbid` sets `auto=0`, increments usage, calls `rpm_resume` | `drivers/base/power/runtime.c:1664-1676` | Probe accounting |
| `pm_runtime_allow` drops usage, calls `rpm_idle(RPM_AUTO\|RPM_ASYNC)` | `drivers/base/power/runtime.c:1691-1709` | Policy change |
| Glue has children: `xhci-hcd.0.auto` + `a600000.usb-role-switch` | `drivers/usb/dwc3/host.c:153`, `drivers/usb/roles/class.c:363-414` | Explains `child_count=2` |
| `power/wakeup` only if `device_can_wakeup` true | `drivers/base/power/sysfs.c:713-716` | No `wakeup-source` on `usb@a600000` in `sm8550.dtsi` |
| RPM trace events in `events/rpm/` | `kernel/trace/Makefile:114-115` | Use `events/rpm/filter` in 7.2.6 |
| `qcom_usb_vbus-regulator` matches only `qcom,pm8150b-vbus-reg` | `drivers/regulator/qcom_usb_vbus-regulator.c:93-96` | Node absent from the RP6 DTB => no AP-side VBUS lever |
| `charger_present`/`chgr_stat` are not kernel symbols | grep over `drivers/`+`include/` = 0 hits | ADSP-internal (scpqchg/QBG_R1); AP sees them only via `pmic_pdcharger_ulog` |

## USB driver scheme (Kconfig + DT + modules.dep)

The whole data path is **built-in**: `PHY_SNPS_EUSB2`, `PHY_QCOM_EUSB2_REPEATER`, `PHY_QCOM_QMP_USB`, `USB_DWC3`, `USB_XHCI_HCD`/`USB_XHCI_PLATFORM`, `TYPEC`, `TYPEC_UCSI`, `UCSI_PMIC_GLINK`, `QCOM_PMIC_GLINK` (all `=y`).

Only two modules exist in the USB chain, and both are present in the initramfs and active:

| Module | Dependencies (`modules.dep`) | How it lands in the initramfs |
|---|---|---|
| `qcom_q6v5_pas` | `qcom_pil_info`, `qcom_q6v5`, `qcom_sysmon`, `qcom_common` | `add_drivers+=" qcom_q6v5_pas "` (91-armada-adsp.conf) |
| `qcom_battmgr` | none | dracut `--no-hostonly` ships all modules; auto-loaded by udev via `alias auxiliary:pmic_glink.power-supply qcom_battmgr` in `modules.alias` |

Consequence: the "missing `qcom_battmgr` module" hypothesis is refuted — the module (35536 B) is already in the CI initramfs image before the explicit `add_drivers` was added, and battery power-supply attributes are readable in every initramfs run (dbg48, dbg49, dbg51).

## UCSI 2.0 spec findings (usb.org)

- **PPM = Platform Policy Manager**: "the combination of hardware and firmware and any vendor-provided OS software that provides the interface to all the USB Type-C connectors on the platform". On RP6 the PPM is the ADSP firmware behind the pmic-glink/UCSI-glink channel.
- **`CONNECTOR_RESET` reset type (bit 23): 0 = Hard Reset (default), 1 = Data Reset.** For a hard reset the spec says the connector "shall go through a disconnect-connect sequence". In dbg32 the plain reset command returned success with an all-zero response and produced **no** disconnect-connect, no VBUS dip, no re-attach — the PPM firmware deviates from the spec. The Data-Reset variant hung the PPM (timeout) with a PDR down/up cycle.
- **CC communication error = bit 4** of the `GET_ERROR_STATUS` data — exactly what the PPM reported when the role-swap commands of dbg31 were rejected (`-ECOMM`).
- **`icm_ncp_stby` is not publicly documented** (web search: only this repository matches). It is an ADSP-internal state; NCP ("No Charging Port") is a BC1.2 port-detection state. The fingerprint `keeps in icm_ncp_stby until charger type updated` is the PPM waiting for BC1.2 classification to complete.
