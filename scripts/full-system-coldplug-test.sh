#!/usr/bin/env bash
# full-system-coldplug-test.sh - Full system check for RP6 USB cold-plug investigation
# Run on full system boot with cold-plugged USB flash drive

set -e

OUTDIR="/run/full-system-coldplug-test-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUTDIR"
echo "[INFO] Output dir: $OUTDIR"

echo "=== FULL-SYSTEM-COLDPLUG-TEST START $(date) ===" | tee "$OUTDIR/summary.txt"

echo -e "\n### (1) PM state of USB chain" | tee -a "$OUTDIR/summary.txt"
for d in /sys/devices/platform/a600000.usb /sys/devices/platform/a600000.usb/xhci-hcd.0.auto; do
  if [ -d "$d" ]; then
    echo "== $d" | tee -a "$OUTDIR/summary.txt"
    for f in power/control power/runtime_status power/autosuspend_delay_ms power/wakeup; do
      if [ -e "$d/$f" ]; then
        printf "  %-24s %s\n" "$f:" "$(cat "$d/$f" 2>&1)" | tee -a "$OUTDIR/summary.txt"
      else
        printf "  %-24s MISSING\n" "$f:" | tee -a "$OUTDIR/summary.txt"
      fi
    done
  else
    echo "== $d MISSING" | tee -a "$OUTDIR/summary.txt"
  fi
done

echo -e "\n### (2) USB type (key)" | tee -a "$OUTDIR/summary.txt"
if [ -e /sys/class/power_supply/qcom-battmgr-usb/usb_type ]; then
  cat /sys/class/power_supply/qcom-battmgr-usb/usb_type | tee -a "$OUTDIR/summary.txt"
else
  echo "MISSING /sys/class/power_supply/qcom-battmgr-usb/usb_type" | tee -a "$OUTDIR/summary.txt"
fi

echo -e "\n### (3) Power supplies" | tee -a "$OUTDIR/summary.txt"
ls /sys/class/power_supply/ 2>&1 | tee -a "$OUTDIR/summary.txt"

echo -e "\n### (4) Loaded modules" | tee -a "$OUTDIR/summary.txt"
lsmod | grep -iE 'battmgr|ulog|tcpm|ucsi|q6v5|dwc3|xhci' | tee -a "$OUTDIR/summary.txt"

echo -e "\n### (5) dmesg window (recent)" | tee -a "$OUTDIR/summary.txt"
dmesg | grep -nE 'new high-speed|new SuperSpeed|ccs|ucsi|typec|rpm_suspend|rpm_idle|dwc3|xhci|PPM|charger' | tail -60 | tee -a "$OUTDIR/summary.txt"

echo -e "\n### (6) journalctl kernel" | tee -a "$OUTDIR/summary.txt"
journalctl -k -b --no-pager | grep -nE 'new high-speed|new SuperSpeed|ccs|ucsi|typec|rpm_suspend|rpm_idle|PPM|charger' | tail -60 | tee -a "$OUTDIR/summary.txt"

echo -e "\n### (7) TypeC/role/usb_role" | tee -a "$OUTDIR/summary.txt"
ls /sys/class/typec/ /sys/class/usb_role/ /sys/class/typec_mux/ 2>&1 | tee -a "$OUTDIR/summary.txt"

echo -e "\n### (8) USB devices" | tee -a "$OUTDIR/summary.txt"
lsusb 2>&1 | tee -a "$OUTDIR/summary.txt"
ls /sys/bus/usb/devices/ 2>&1 | tee -a "$OUTDIR/summary.txt"

echo -e "\n### (9) RPM trace (if available)" | tee -a "$OUTDIR/summary.txt"
if [ -e /sys/kernel/tracing/trace ]; then
  echo "rpm_suspend count: $(grep -cE 'rpm_suspend' /sys/kernel/tracing/trace 2>/dev/null || echo 0)" | tee -a "$OUTDIR/summary.txt"
  grep -E 'rpm_(idle|suspend|resume|usage|return_int|status)' /sys/kernel/tracing/trace 2>/dev/null | tail -40 | tee -a "$OUTDIR/summary.txt"
elif [ -e /sys/kernel/debug/tracing/trace ]; then
  echo "rpm_suspend count: $(grep -cE 'rpm_suspend' /sys/kernel/debug/tracing/trace 2>/dev/null || echo 0)" | tee -a "$OUTDIR/summary.txt"
  grep -E 'rpm_(idle|suspend|resume|usage|return_int|status)' /sys/kernel/debug/tracing/trace 2>/dev/null | tail -40 | tee -a "$OUTDIR/summary.txt"
else
  echo "tracing not mounted" | tee -a "$OUTDIR/summary.txt"
fi

echo -e "\n### (10) Kernel config" | tee -a "$OUTDIR/summary.txt"
if [ -e /proc/config.gz ]; then
  zcat /proc/config.gz | grep -E 'TYPEC|UCSI|ROLE_SWITCH|QRTR|USB_ROLE|USB_DWC3' | tee -a "$OUTDIR/summary.txt"
else
  echo "no /proc/config.gz" | tee -a "$OUTDIR/summary.txt"
fi

echo -e "\n=== FULL-SYSTEM-COLDPLUG-TEST END $(date) ===" | tee -a "$OUTDIR/summary.txt"
echo "[INFO] All output in $OUTDIR"
