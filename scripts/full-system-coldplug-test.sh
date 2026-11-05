#!/usr/bin/env bash
# full-system-coldplug-test.sh - Full system check for RP6 USB cold-plug investigation
# Run on a full system boot. Pre-plug is the primary variant; post-plug is the fork.
#
# Usage:
#   ./scripts/full-system-coldplug-test.sh
#   OUTDIR=/path/to/out ./scripts/full-system-coldplug-test.sh
#
# The sysfs paths are discovered dynamically: on kernel 7.2.6 the controller is
#   /sys/devices/platform/soc@0/a600000.usb
#   /sys/devices/platform/soc@0/a600000.usb/xhci-hcd.<N>.auto
# (the old hard-coded /sys/devices/platform/a600000.usb/xhci-hcd.0.auto paths
#  do not exist on this kernel).

set -u

OUTDIR="${OUTDIR:-$PWD/full-system-coldplug-test-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUTDIR" || { echo "cannot create OUTDIR=$OUTDIR" >&2; exit 1; }
SUM="$OUTDIR/summary.txt"
echo "[INFO] Output dir: $OUTDIR"

say() { echo "$@" | tee -a "$SUM"; }
show_file() {
  local f="$1" label="${2:-$1}"
  if [ -e "$f" ]; then
    printf "  %-30s %s\n" "$label:" "$(cat "$f" 2>&1)"
  else
    printf "  %-30s MISSING\n" "$label:"
  fi
}

say "=== FULL-SYSTEM-COLDPLUG-TEST START $(date) ==="

say -e "\n### (0) Environment / boot"
say "model:      $(tr -d '\0' </proc/device-tree/model 2>/dev/null)"
say "kernel:     $(uname -a)"
say "boot:       $(uptime -s 2>/dev/null)  (up $(uptime -p 2>/dev/null))"
say "cmdline:    $(cat /proc/cmdline)"
say "root:       $(findmnt -n -o SOURCE,FSTYPE / 2>/dev/null)"

say -e "\n### (1) PM state of USB chain (paths discovered dynamically)"
GLUE="$(find /sys/devices/platform -maxdepth 3 -type d -name 'a600000.usb' 2>/dev/null | head -1)"
[ -z "$GLUE" ] && GLUE="/sys/devices/platform/a600000.usb"
XHCI="$(find "$GLUE" -maxdepth 1 -type d -name 'xhci-hcd.*.auto' 2>/dev/null | head -1)"
say "glue: $GLUE"
say "xhci: ${XHCI:-MISSING}"
for d in "$GLUE" "$XHCI"; do
  [ -n "$d" ] || continue
  if [ -d "$d" ]; then
    say "== $d"
    for f in power/control power/runtime_status power/autosuspend_delay_ms power/wakeup; do
      say "$(show_file "$d/$f" "$f")"
    done
    for h in usb1 usb2; do
      [ -d "$d/$h" ] || continue
      say "== $d/$h"
      for f in power/control power/runtime_status power/autosuspend_delay_ms; do
        say "$(show_file "$d/$h/$f" "$f")"
      done
    done
  else
    say "== $d MISSING"
  fi
done

say -e "\n### (2) USB type (key; the bracketed value is the current one)"
found_type=0
for p in /sys/class/power_supply/*; do
  [ -e "$p/usb_type" ] || continue
  found_type=1
  say "$(basename "$p"): $(cat "$p/usb_type")"
done
[ "$found_type" -eq 0 ] && say "no usb_type attribute under /sys/class/power_supply/"

say -e "\n### (3) Power supplies / role"
say "$(ls /sys/class/power_supply/ 2>&1)"
for p in /sys/class/power_supply/*; do
  [ -d "$p" ] || continue
  say "== $(basename "$p")"
  for f in type online usb_type voltage_now current_now input_current_limit; do
    [ -e "$p/$f" ] && say "$(show_file "$p/$f" "$f")"
  done
done
for f in /sys/class/typec/port*/data_role /sys/class/typec/port*/power_role \
         /sys/class/typec/port*/power_operation_mode /sys/class/typec/port*/vconn_source \
         /sys/class/usb_role/*/role; do
  [ -e "$f" ] && say "$(show_file "$f" "$f")"
done

say -e "\n### (4) Loaded modules"
say "$(lsmod | grep -iE 'battmgr|ulog|tcpm|ucsi|q6v5|dwc3|xhci|typec|role' || true)"

say -e "\n### (5) Boot / enumeration timeline"
say "$(dmesg 2>/dev/null | grep -nE 'qcom_pmic_glink|PDR: Indication.*charger_pd|powering up adsp|adsp is now up|xhci-hcd xhci-hcd|new high-speed|new SuperSpeed|usb-storage|Attached SCSI disk|USB disconnect' | head -80 || true)"

say -e "\n### (6) journalctl kernel (classification-relevant)"
say "$(journalctl -k -b --no-pager 2>/dev/null | grep -nE 'new high-speed|new SuperSpeed|ccs|ucsi|typec|rpm_suspend|rpm_idle|PPM|charger|battmgr' | tail -60 || true)"

say -e "\n### (7) TypeC / usb_role / typec_mux"
for d in /sys/class/typec /sys/class/usb_role /sys/class/typec_mux; do
  say "== $d"
  say "$(ls -l "$d" 2>&1)"
done

say -e "\n### (8) USB devices"
if command -v lsusb >/dev/null 2>&1; then
  say "$(lsusb 2>&1)"
else
  say "lsusb not installed; sysfs list:"
fi
say "$(ls /sys/bus/usb/devices/ 2>&1)"
for d in /sys/bus/usb/devices/*; do
  [ -f "$d/idVendor" ] || continue
  say "$(printf '%s  %s:%s  %s  %s' "$(basename "$d")" "$(cat "$d/idVendor")" "$(cat "$d/idProduct")" "$(cat "$d/speed" 2>/dev/null)" "$(cat "$d/product" 2>/dev/null)")"
done

say -e "\n### (9) RPM trace (if available)"
TR=""
[ -e /sys/kernel/tracing/trace ] && TR=/sys/kernel/tracing/trace
[ -z "$TR" ] && [ -e /sys/kernel/debug/tracing/trace ] && TR=/sys/kernel/debug/tracing/trace
if [ -n "$TR" ]; then
  say "rpm_suspend count: $(grep -cE 'rpm_suspend' "$TR" 2>/dev/null || echo 0)"
  grep -E 'rpm_(idle|suspend|resume|usage|return_int|status)' "$TR" 2>/dev/null | tail -40 | tee -a "$SUM"
else
  say "tracing not mounted"
fi

say -e "\n### (10) Kernel config"
if [ -e /proc/config.gz ]; then
  say "$(zcat /proc/config.gz | grep -E 'TYPEC|UCSI|ROLE_SWITCH|QRTR|USB_ROLE|USB_DWC3' || true)"
else
  say "no /proc/config.gz"
fi

say -e "\n=== FULL-SYSTEM-COLDPLUG-TEST END $(date) ==="
echo "[INFO] All output in $OUTDIR"
