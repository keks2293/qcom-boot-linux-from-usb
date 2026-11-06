#!/usr/bin/env bash
# boot-deferred-sampler.sh — sample the deferred-probe state during BOOT.
#
# Why this exists:
#   On the full system the xhci-hcd probe is held a deterministic ~4.405 s
#   after the ADSP `charger_pd` PDR (measured 4.403966 s / 4.406008 s on two
#   pre-plug boots whose absolute times differ by 2.9 s), and the pre-plugged
#   drive is then enumerated on the first hub scan. Nothing in dmesg says who
#   holds the controller. /sys/kernel/debug/devices_deferred (root, mode 0700)
#   is the only file that answers "device X is waiting for supplier Y" — and it
#   is EMPTY once boot has finished, so it has to be sampled *during* boot.
#
# Read-only. Installed as boot-deferred-sampler.service (Type=simple, ordered
# before basic.target) it appends change-only records to /var/tmp/boot-deferred.log
# for the first DUR seconds of every boot. The unit and script live under
# /var/lib/boot-deferred-sampler/ + /etc/systemd/system/ because /usr/local is
# read-only on this ostree/immutable system.
#
#   OUT=/path DUR=45 INTERVAL_MS=50 ./boot-deferred-sampler.sh
#
# Best effort: it also switches on dynamic debug for the probe/deferral code,
# so the next boot may print the deferral itself (revert with
#   echo 'file drivers/base/dd.c -p' > /sys/kernel/debug/dynamic_debug/control).

set -u

OUT="${OUT:-/var/tmp/boot-deferred.log}"
DUR="${DUR:-45}"
INTERVAL_MS="${INTERVAL_MS:-50}"
DBG=/sys/kernel/debug
DEFERRED="$DBG/devices_deferred"

# best-effort: make driver_deferred_probe()/device-links print on this boot
{
  echo "# dynamic debug enables (best effort) at $(date -Is)"
  for expr in 'file drivers/base/dd.c +p' \
              'file drivers/base/core.c +p' \
              'module dwc3 +p' \
              'module dwc3_qcom +p' \
              'module xhci_hcd +p'; do
    printf '%s' "$expr" > "$DBG/dynamic_debug/control" 2>&1 \
      && echo "  ok:   $expr" || echo "  fail: $expr"
  done
} >> "$OUT" 2>&1

state() {
  # state WITHOUT the timestamp, so the change-only filter works
  local b x t r
  b=$([ -e /sys/bus/platform/drivers/dwc3-qcom/a600000.usb ] && echo 1 || echo 0)
  x=$(ls -d /sys/devices/platform/*/a600000.usb/xhci-hcd.*.auto 2>/dev/null | head -1)
  x=$([ -n "$x" ] && echo 1 || echo 0)
  t=$([ -d /sys/class/typec/port0 ] && echo 1 || echo 0)
  r=$([ -e /sys/class/usb_role/a600000.usb-role-switch ] && echo 1 || echo 0)
  printf 'dwc3_bound=%s xhci_present=%s typec_port0=%s role_switch=%s deferred=[%s]' \
    "$b" "$x" "$t" "$r" "$1"
}

{
  echo "=== boot-deferred sampler start=$(date -Is) dur=${DUR}s interval=${INTERVAL_MS}ms pid=$$ ==="
  echo "# dwc3_bound = a600000.usb bound to dwc3-qcom; xhci_present = xhci-hcd.*.auto child exists"
  echo "# deferred   = /sys/kernel/debug/devices_deferred (device -> supplier it waits for)"

  # make sure debugfs is there (systemd normally mounts it; this is a no-op then)
  mountpoint -q "$DBG" || mount -t debugfs none "$DBG" 2>/dev/null

  end=$(awk -v d="$DUR" '{printf "%.3f", $1 + d}' /proc/uptime)
  last=""
  first_dwc3="" first_xhci="" first_typec="" max_deferred=""
  while :; do
    now=$(cut -d' ' -f1 /proc/uptime)
    [ "$(awk -v n="$now" -v e="$end" 'BEGIN{print (n>=e)}')" = 1 ] && break

    def=""
    if [ -r "$DEFERRED" ]; then
      def="$(tr '\n' ';' < "$DEFERRED" 2>/dev/null)"
    else
      def="NOT-READABLE"
    fi
    st="$(state "$def")"
    if [ "$st" != "$last" ]; then
      printf 't=%-9s %s\n' "$now" "$st"
      last="$st"
      case "$st" in
        *dwc3_bound=1*) [ -z "$first_dwc3" ] && first_dwc3="$now" ;;
      esac
      case "$st" in
        *xhci_present=1*) [ -z "$first_xhci" ] && first_xhci="$now" ;;
      esac
      case "$st" in
        *typec_port0=1*) [ -z "$first_typec" ] && first_typec="$now" ;;
      esac
      if [ -n "$def" ] && [ "$def" != "NOT-READABLE" ]; then
        max_deferred="$now: $def"
      fi
    fi
    sleep "$(awk -v m="$INTERVAL_MS" 'BEGIN{printf "%.3f", m/1000}')"
  done

  echo "--- summary ---"
  echo "first_dwc3_bound=$first_dwc3"
  echo "first_xhci_present=$first_xhci"
  echo "first_typec_port0=$first_typec"
  echo "last_nonempty_deferred=${max_deferred:-<never non-empty>}"
  echo "=== end=$(date -Is) uptime=$(cut -d' ' -f1 /proc/uptime) ==="
} >> "$OUT" 2>&1
