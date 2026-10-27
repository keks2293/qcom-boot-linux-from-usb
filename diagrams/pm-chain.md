# PM chain and RPM blockers

## Topology
```
[USB flash cold-plug]
        ↓
PMIC/PPM (BC1.2/PD) — ADSP in icm_ncp_stby until charger type updated (P-06)
        ↓ (CC/port state)
HS-PHY (snps-eusb2 / pm8550b repeater)
        ↓
a600000.usb (glue + DWC3) — platform device, OF node usb@a600000
  - children: xhci-hcd.0.auto, a600000.usb-role-switch
  - probe: pm_runtime_forbid + get_noresume, delay 5000ms
        ↓
xhci-hcd.0.auto (xhci-plat)
  - children: usb1, usb2 (root hubs)
  - probe: pm_runtime_forbid + get_noresume, delay 0
        ↓
usb1 / usb2 (root hubs, HCD root hubs)
  - parent = HCD controller
  - autosuspend_delay = -1000 (usbcore.autosuspend=-1)
  - always active (never autosuspend)
```

## Runtime PM rules (relevant)
- `rpm_check_suspend_allowed`: -EACCES (disable_depth), -EAGAIN (usage_count>0), -EBUSY (child_count>0 and !ignore_children)
- `pm_runtime_forbid`: auto=0, usage_count++, rpm_resume
- `pm_runtime_allow`: auto=1, rpm_drop_usage_count -> if 0 rpm_idle(AUTO|ASYNC)
- Root hubs: `hub_probe` sets active + get_noresume + use_autosuspend + enable, delay set by usbcore

## dbg51 trace (example)
```
rpm_resume  a600000.usb   ret=1        (force resume, was not suspended)
rpm_idle    a600000.usb   ... child=2 -> ret=-11  (-EAGAIN, usage)
rpm_idle    xhci-hcd.0.auto ... child=1 -> ret=-11
rpm_idle    a600000.usb   ... child=1 -> ret=-16  (-EBUSY)
rpm_idle    xhci-hcd.0.auto ... child=2 -> ret=-16
```

## Why it cannot suspend
- `usb1/usb2` delay -1000 => `update_autosuspend` prevents suspend, keeps usage
- `xhci` has children `usb1/usb2` => child_count>=2 => -EBUSY
- `glue` has children `xhci` + `role-switch` => child_count>=2 => -EBUSY even if usage drops
- All states tested (hubs asleep/active, glue/xhci cycled) still resulted in no enumeration and `trace-suspended=0`

**Conclusion:** L2/runtime-PM not the wedge. Look at PPM/BC1.2 classification and early port bring-up.
