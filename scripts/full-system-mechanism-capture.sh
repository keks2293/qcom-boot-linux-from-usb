#!/usr/bin/env bash
# full-system-mechanism-capture.sh — capture the EXACT pre-plug enumeration
# mechanism from the WORKING full system (the reference environment).
#
# Goal: diff "full-system boot timeline" against the initramfs (dbg) timeline
# and name the exact element the initramfs is missing. Questions this answers:
#   Q1: why is the xhci-hcd probe at ~14.8 s (vs ~0.5 s in dbg images)?
#       What holds it (devlink EPROBE_DEFER? supplier? clocks? role?) and
#       what releases it?
#   Q2: what happens in the PDR(charger_pd) -> xhci-hcd window (~4.4 s)?
#   Q3: what is the FIRST kernel line before "usb 1-1: new high-speed"?
#       A xHCI port-change event with connect-status (CSC) — i.e. a fresh
#       CC edge — or nothing (attach = first scan of the pre-plugged device)?
#   Q4: which udev rule sets the dwc3 glue power/control=auto +
#       autosuspend_delay_ms=5000, and when?
#   Q5: what AP-side activity (UCSI/PDR/battmgr/PMIC) precedes the attach?
#
# Read-only, zero risk, no replug, no reboot. Run as root on the full system
# AFTER a pre-plug boot (dock/flash plugged in before power-on), before
# touching any USB device:
#
#   sudo OUTDIR=/tmp/mech-capture ./full-system-mechanism-capture.sh
#
# Root matters: /sys/kernel/debug/devices_deferred and the UCSI debugfs are
# 0700, and devices_deferred is the only file that names the supplier holding
# the USB controller (Q1). Without root the script still runs, but marks those
# two sections NEEDS ROOT instead of reporting a false result.
#
# Then transfer $OUTDIR (at least: timeline.txt quick-windows.txt
# full-kern-monotonic.log full-kern-iso.log udevd-iso.log devlink.txt
# ucsi-debugfs.txt udev-rules.txt).

set -u

OUTDIR="${OUTDIR:-$PWD/mechanism-capture-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUTDIR" || { echo "cannot create OUTDIR=$OUTDIR" >&2; exit 1; }
SUM="$OUTDIR/summary.txt"

# USB chain paths, discovered dynamically (kernel 7.2.6: soc@0/a600000.usb,
# xhci-hcd.<N>.auto). Defined early because the devlink section needs them.
GLUE="$(find /sys/devices/platform -maxdepth 3 -type d -name 'a600000.usb' 2>/dev/null | head -1)"
XHCI="$(find "$GLUE" -maxdepth 1 -type d -name 'xhci-hcd.*.auto' 2>/dev/null | head -1)"

say() { echo "$@" | tee -a "$SUM"; }

say "=== FULL-SYSTEM MECHANISM CAPTURE $(date) ==="
say "host:    $(uname -a)"
say "boot:    $(uptime -s 2>/dev/null)"
say "cmdline: $(cat /proc/cmdline)"
say "root:    $(findmnt -n -o SOURCE,FSTYPE / 2>/dev/null)"
say "user:    $(id -un) (journalctl/mount may need root)"

# ---------------------------------------------------------------- (1)
# The full UNFILTERED kernel log of this boot with ISO timestamps.
# This is the primary artifact: every probe, every devlink deferral,
# every PDR/UCSI line, with both absolute and kernel-relative time.
if journalctl -b -k -o short-iso > "$OUTDIR/full-kern-iso.log" 2>/dev/null \
   && [ -s "$OUTDIR/full-kern-iso.log" ]; then
  say "kern log: $(wc -l < "$OUTDIR/full-kern-iso.log") lines (journalctl -b -k)"
else
  dmesg -T > "$OUTDIR/full-kern-iso.log" 2>/dev/null
  say "kern log: $(wc -l < "$OUTDIR/full-kern-iso.log") lines (dmesg -T fallback)"
fi

# Kernel-RELATIVE log. The ISO log is unusable for boot timing on this device:
# the RTC reads a wrong date until the first NTP/RTC sync (~7 s into boot), so
# every early line is stamped with the bogus date (observed 2026-09-14T08:00:00)
# and the absolute timestamps cannot be compared with each other. The relative
# ([   12.345678]) clock is monotonic from boot and is the one to diff against
# the initramfs timeline.
if journalctl -b -k -o short-monotonic > "$OUTDIR/full-kern-monotonic.log" 2>/dev/null \
   && [ -s "$OUTDIR/full-kern-monotonic.log" ]; then
  say "kern log: $(wc -l < "$OUTDIR/full-kern-monotonic.log") lines (short-monotonic)"
else
  dmesg > "$OUTDIR/full-kern-monotonic.log" 2>/dev/null
  say "kern log: $(wc -l < "$OUTDIR/full-kern-monotonic.log") lines (dmesg fallback)"
fi

# The full journal (userspace too: udev, systemd units, modprobe).
journalctl -b -o short-iso > "$OUTDIR/full-journal-iso.log" 2>/dev/null \
  && say "journal: $(wc -l < "$OUTDIR/full-journal-iso.log") lines" \
  || say "journal: UNAVAILABLE (run as root?)"

# ---------------------------------------------------------------- (2)
# udev: installed rules that touch usb/dwc3/autosuspend + full udevd log.
{
  echo "--- rules mentioning autosuspend|dwc3 (content) ---"
  for f in /etc/udev/rules.d/* /usr/lib/udev/rules.d/*; do
    [ -f "$f" ] || continue
    grep -qiE "autosuspend|dwc3" "$f" || continue
    echo "== $f"
    cat "$f"
    echo
  done
  echo "--- all rule files (names only) ---"
  ls /etc/udev/rules.d/ /usr/lib/udev/rules.d/ 2>/dev/null
} > "$OUTDIR/udev-rules.txt" 2>&1
say "udev rules: $(wc -l < "$OUTDIR/udev-rules.txt") lines"

journalctl -b -u systemd-udevd -o short-iso > "$OUTDIR/udevd-iso.log" 2>/dev/null
say "udevd log: $(wc -l < "$OUTDIR/udevd-iso.log" 2>/dev/null || echo 0) lines"

# ---------------------------------------------------------------- (3)
# devlink: residual deferred list + per-node state aggregation.
# NOTE: /sys/kernel/devlink and /sys/kernel/debug/devices_deferred are
# root-only (and /sys/kernel/devlink does not even exist on kernel 7.2.6),
# so a non-root run reports the gap instead of a false "empty".
{
  if [ -e /sys/kernel/devlink/deferred ]; then
    echo "--- /sys/kernel/devlink/deferred ---"
    cat /sys/kernel/devlink/deferred 2>&1
  else
    echo "--- /sys/kernel/devlink/deferred: ABSENT (not exposed on this kernel) ---"
  fi
  if [ -r /sys/kernel/debug/devices_deferred ]; then
    echo "--- /sys/kernel/debug/devices_deferred (what is still waiting, on whom) ---"
    cat /sys/kernel/debug/devices_deferred 2>&1
  else
    echo "--- /sys/kernel/debug/devices_deferred: NEEDS ROOT ---"
    echo "    (this is the file that names the supplier holding a600000.usb;"
    echo "     re-run this script with sudo to answer Q1)"
  fi
  echo "--- supplier links of the USB chain (which suppliers can hold it) ---"
  for n in "$GLUE" "$XHCI"; do
    [ -d "$n" ] || continue
    echo "== $n"
    for l in "$n"/supplier:*; do
      [ -e "$l" ] || continue
      echo "  $(basename "$l") -> $(readlink -f "$l" 2>/dev/null)"
    done
    for l in "$n"/consumer:*; do
      [ -e "$l" ] || continue
    done
  done
  echo "--- usb-chain devlink nodes (status) ---"
  for n in /sys/devices/virtual/devlink/*a600000* /sys/devices/virtual/devlink/*typec* \
           /sys/devices/virtual/devlink/*usb0-sbu*; do
    [ -e "$n" ] || continue
    echo "== $(basename "$n")"
    for f in status runtime_pm sync_state_only auto_remove_on; do
      [ -e "$n/$f" ] && echo "  $f = $(cat "$n/$f" 2>&1)"
    done
  done
} > "$OUTDIR/devlink.txt" 2>&1
say "devlink: $(wc -l < "$OUTDIR/devlink.txt") lines"

# ---------------------------------------------------------------- (3b)
# The Q1/Q3 timeline in kernel-relative time, extracted mechanically so the
# deltas (PDR -> xhci -> first attach) do not have to be read off by hand.
{
  echo "--- key events (kernel-relative) ---"
  grep -nE 'adsp is now up|PDR: Indication received from msm/adsp/charger_pd|xhci-hcd xhci-hcd[^:]*: xHCI Host Controller|usb 1-1: new high-speed|usb-storage 1-1.2|scsi 1:0:0:0:|\[sdg\] Attached SCSI' \
    "$OUTDIR/full-kern-monotonic.log" | head -40
  echo
  echo "--- deltas (awk, seconds) ---"
  grep -nE 'PDR: Indication received from msm/adsp/charger_pd|xhci-hcd xhci-hcd[^:]*: xHCI Host Controller|usb 1-1: new high-speed' \
    "$OUTDIR/full-kern-monotonic.log" | head -5 | sed -E 's/^\s*([0-9]+):.*\[ *([0-9]+\.[0-9]+)\].*/\1 \2/'
} > "$OUTDIR/timeline.txt" 2>&1
say "timeline: $(wc -l < "$OUTDIR/timeline.txt") lines"

# ---------------------------------------------------------------- (4)
# ucsi debugfs (mount tracefs/debugfs if needed; read-only).
{
  mountpoint -q /sys/kernel/tracing 2>/dev/null \
    || mount -t tracefs none /sys/kernel/tracing 2>/dev/null
  mountpoint -q /sys/kernel/debug 2>/dev/null \
    || mount -t debugfs none /sys/kernel/debug 2>/dev/null
  if [ "$(id -u)" -ne 0 ]; then
    echo "ucsi debugfs: NOT READABLE AS ROOT: /sys/kernel/debug is 0700."
    echo "  This run cannot tell 'UCSI core inactive' from 'permission denied'."
    echo "  Re-run the script with sudo to answer this properly."
  elif [ -d /sys/kernel/debug/usb/ucsi ]; then
    echo "--- tree ---"
    ls -R /sys/kernel/debug/usb/ucsi/
    echo "--- contents ---"
    find /sys/kernel/debug/usb/ucsi/ -type f | while read -r f; do
      echo "== $f"
      head -40 "$f" 2>&1
    done
  else
    echo "ucsi debugfs ABSENT (UCSI core not active? check kern log)"
  fi
} > "$OUTDIR/ucsi-debugfs.txt" 2>&1
say "ucsi debugfs: $(wc -l < "$OUTDIR/ucsi-debugfs.txt") lines"

# ---------------------------------------------------------------- (5)
# Steady-state sysfs: PM state of the chain, roles, power supplies,
# usb_role (incl. the role-switch writability), typec mux.
# (GLUE/XHCI are discovered at the top of the script.)
{
  echo "--- PM state ---"
  for d in "$GLUE" "$XHCI"; do
    [ -d "$d" ] || { echo "$d MISSING"; continue; }
    echo "== $d"
    for f in power/control power/runtime_status power/autosuspend_delay_ms power/wakeup; do
      [ -e "$d/$f" ] && echo "  $f = $(cat "$d/$f" 2>&1)"
    done
  done
  echo "--- usb_role ---"
  ls -l /sys/class/usb_role/ 2>&1
  for r in /sys/class/usb_role/*/role; do
    [ -e "$r" ] && echo "$r = $(cat "$r" 2>&1) writable=$([ -w "$r" ] && echo yes || echo no)"
  done
  echo "--- typec ---"
  for f in /sys/class/typec/port*/data_role /sys/class/typec/port*/power_role \
           /sys/class/typec/port*/power_operation_mode; do
    [ -e "$f" ] && echo "$f = $(cat "$f" 2>&1)"
  done
  echo "--- power supplies ---"
  for p in /sys/class/power_supply/*; do
    [ -d "$p" ] || continue
    echo "== $(basename "$p")"
    for f in type online usb_type voltage_now current_now input_current_limit; do
      [ -e "$p/$f" ] && echo "  $f = $(cat "$p/$f" 2>&1)"
    done
  done
  echo "--- modules (usb/typec/charger) ---"
  lsmod | grep -iE 'battmgr|ulog|tcpm|ucsi|q6v5|dwc3|xhci|typec|role|eusb' || true
} > "$OUTDIR/steady-state.txt" 2>&1
say "steady state: $(wc -l < "$OUTDIR/steady-state.txt") lines"

# ---------------------------------------------------------------- (6)
# Quick windows — the extract that directly answers Q1..Q3, for a fast
# read without parsing the whole log. Uses the kernel-RELATIVE log: the ISO
# log's absolute stamps are wrong until the RTC/NTP sync (~7 s), which put
# every early boot line on the build date (2026-09-14T08:00:00).
K="$OUTDIR/full-kern-monotonic.log"
[ -s "$K" ] || K="$OUTDIR/full-kern-iso.log"
{
  echo "=== [W1] adsp-up .. xhci probe (what releases the xHCI?) ==="
  awk '/adsp is now up/{f=1} f{print} /xHCI Host Controller/{if (f) c++; if (c==1) exit}' "$K"

  echo
  echo "=== [W2] PDR(charger_pd) .. first xHCI line (THE ~4.4 s window) ==="
  awk '/PDR: Indication received from msm\/adsp\/charger_pd/{f=1} f{print}
       /xhci-hcd.*: xHCI Host Controller/{if (f) exit}' "$K"

  echo
  echo "=== [W3] 25 lines BEFORE the first 'new high-speed' (Q3: fresh edge or first scan?) ==="
  FIRST_LINE="$(grep -n 'new high-speed' "$K" | head -1 | cut -d: -f1)"
  if [ -n "$FIRST_LINE" ]; then
    START=$((FIRST_LINE > 25 ? FIRST_LINE - 25 : 1))
    sed -n "${START},$((FIRST_LINE + 2))p" "$K"
  else
    echo "no 'new high-speed' line found"
  fi

  echo
  echo "=== [W4] all devlink/deferral lines ==="
  grep -nE 'EPROBE_DEFER|deferred|Failed to create device link|devlink' "$K" || echo "(none)"

  echo
  echo "=== [W5] all UCSI/PDR/battmgr/typec/role lines (AP activity) ==="
  grep -nE 'ucsi|UCSI|PDR:|battmgr|BattMgr|typec|role|charger_pd' "$K" || echo "(none)"

  echo
  echo "=== [W6] xhci/dwc3/phy/eusb2 probe lines with relative time ==="
  grep -nE 'xhci-hcd|dwc3|eusb2|a600000' "$K" || echo "(none)"
} > "$OUTDIR/quick-windows.txt" 2>&1
say "quick windows: $(wc -l < "$OUTDIR/quick-windows.txt") lines"

say "=== END $(date) — send at least: quick-windows.txt full-kern-iso.log udevd-iso.log devlink.txt ucsi-debugfs.txt udev-rules.txt steady-state.txt ==="
echo "[INFO] all output in $OUTDIR"
