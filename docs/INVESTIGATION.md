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
| P-06 | ADSP/PPM BC1.2 classification blocks data path until charger type updated | **Strong candidate** | `icm_ncp_stby_main: keeps in icm_ncp_stby until charger type updated`, `chgr_stat=7`, `charger_present=0` |
| L2/PM | Glue/XHCI enter runtime suspend/L2 and block enumeration | **Closed (dbg51)** | Observed in all tested PM states; blocked by root-hub autosuspend policy and child counts |
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
