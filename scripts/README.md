# Scripts

## full-system-coldplug-test.sh

Run on full system (internal boot) after cold-plugging USB flash drive.

```bash
chmod +x full-system-coldplug-test.sh
./full-system-coldplug-test.sh > full-system-coldplug-test.log 2>&1
```

Collects:
- PM state of `a600000.usb` and `xhci-hcd.0.auto`
- `usb_type` from `qcom-battmgr-usb` (key)
- modules, typec/role paths
- dmesg/journalctl around enumeration
- RPM trace tail if available
- kernel config snippets

Attach the generated log to any report.
