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
| P-06 | ADSP/PPM BC1.2 classification blocks data path until charger type updated | **Strong candidate** | `icm_ncp_stby_main: keeps in icm_ncp_stby until charger type updated`, `chgr_stat=7`, `charger_present=0`. PPM = "Platform Policy Manager" (UCSI 2.0 spec term); `icm_ncp_stby` is an ADSP-internal state (NCP = "No Charging Port", BC1.2) — not publicly documented anywhere else |
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
