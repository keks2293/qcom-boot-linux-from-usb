#!/bin/sh
# ARMADA-C (lever C, 2026-11-12): post-PDR rescan of the USB host controller.
#
# Rationale (control boot 2026-11-11, docs/FULL_SYSTEM_PREPLUG_SOURCE_ROLE.md):
# the full system enumerates a pre-plugged direct stick with the *failing-side*
# PPM fingerprint (usb_type=[Unknown], skip-gate, ncp_stby).  The discriminator
# is ordering: its first xHCI port scan is POST-PDR (PDR 12.454 s -> scan
# 12.787 s -> device 13.05 s), while the initramfs scans PRE-PDR (2.7 s vs PDR
# 3.5 s).  So: drop the early (ABL dr_mode=host) host controller before the PDR,
# wait for the charger_pd PDR, re-probe -> fresh first scan now post-PDR.
#
# SCOPE: only the xhci-hcd platform device (created by dwc3/host.c, quirk data
# lives on the platform device so it survives the unbind).  dwc3-qcom is NOT
# touched: drivers/usb/dwc3/core.c registers the usb-role-switch device on
# dwc->dev, UCSI keeps a reference (ucsi.c:1837) and calls
# usb_role_switch_set_role() on every connector change (ucsi.c:1376,1958), so
# unbinding dwc3 would leave UCSI with a stale pointer into the freed struct
# dwc3 (use-after-free).  Not worth the risk in a one-shot boot test.
#
# Decision 1+3+4 (docs/SEQUENCER_TIMING_BEST_PRACTICE.md): no ADSP staging, no
# wall-clock delays -- udev settle + the PDR event + bounded verify/retry.
#
# NORMAL BOOTS ARE NOT AFFECTED: this only acts in `linux usb` mode, detected
# by the live device tree, where ABL injects dr_mode="host" into usb@a600000
# (docs/ABL_DR_MODE_HOST.md).  A normal boot has no such property -> no-op.
# (Needed because the PDR only reaches the initramfs in `linux usb` mode; in a
# normal boot it arrives at ~12 s from the real root, long after switch_root,
# so the script must stay inert rather than leave the controller unbound.)
#
# LIFETIME: sourced by dracut-initqueue (`job=$job . "$job"`) on EVERY loop
# iteration (~0.5 s), therefore: idempotent via pidfile AND a done-marker (the
# sequence must run once, not restart after it finishes), NEVER `exit` at the
# top level, no `set -e/-u`, variables prefixed _ac_.
#
# OUTPUT (all via /dev/kmsg <0>, visible despite console=tty0 quiet):
#   ARMADA-C: <msg>     every step with kernel uptime; final verdict is either
#                       "ENUMERATION OK ...: sdX" or "FAIL-..." (grep-able).

_ac_pidfile=/tmp/armada-c.pid
_ac_done=/tmp/armada-c.done
_ac_dev=a600000.usb
_ac_dt=/sys/bus/platform/devices/$_ac_dev/of_node
_ac_xdrv=/sys/bus/platform/drivers/xhci-hcd

_ac_k() { echo "<0>ARMADA-C: $*" > /dev/kmsg 2>/dev/null; }

# --- guards: run the sequence exactly once -------------------------------
_ac_running=0
[ -f "$_ac_done" ] && _ac_running=1
if [ "$_ac_running" -eq 0 ] && [ -f "$_ac_pidfile" ]; then
  _ac_pid=$(cat "$_ac_pidfile" 2>/dev/null)
  if [ -n "$_ac_pid" ] && [ -d "/proc/$_ac_pid" ]; then
    _ac_running=1
  fi
fi

if [ "$_ac_running" -eq 0 ]; then
  (
    _ac_up() { cut -d. -f1 /proc/uptime 2>/dev/null; }
    _ac_pdr() { dmesg 2>/dev/null | grep -q "PDR: Indication received from msm/adsp/charger_pd"; }
    _ac_110() { dmesg 2>/dev/null | grep -c "Host halt failed, -110"; }
    _ac_settle() { udevadm settle --timeout=10 2>/dev/null; }
    _ac_nev() { dmesg 2>/dev/null | grep -c "new .*-speed USB device"; }

    # a USB-backed block disk (NOT the internal UFS, which also appears as sd*)
    _ac_usbdisk() {
      for _d in /sys/block/sd*; do
        [ -e "$_d" ] || continue
        _r=$(_ac_path "$_d")
        case "$_r" in
          *"/usb"*) echo "${_d##*/}"; return 0 ;;
        esac
      done
      return 1
    }

    # `linux usb` mode test: ABL injects dr_mode="host" into the live FDT
    _ac_usbmode() {
      [ -e "$_ac_dt/dr_mode" ] || return 1
      _m=$(tr -d '\000' < "$_ac_dt/dr_mode" 2>/dev/null)
      [ "$_m" = host ]
    }

    # physical path of a sysfs link, without depending on `readlink -f`
    _ac_path() { ( cd -P "$1" 2>/dev/null && pwd -P ); }

    # resolve an xhci-hcd platform device that belongs to our controller
    _ac_xfind() {   # $1 = "bound" | "unbound"
      for _d in /sys/bus/platform/drivers/xhci-hcd/xhci-hcd.* /sys/bus/platform/devices/xhci-hcd.*; do
        [ -e "$_d" ] || continue
        _n=${_d##*/}
        _r=$(_ac_path "$_d")
        case "$_r" in
          *"$_ac_dev"*) ;;
          *) continue ;;
        esac
        _b=unbound
        [ -e "$_ac_xdrv/$_n" ] && _b=bound
        if [ "$_b" = "$1" ]; then
          echo "$_n"
          return 0
        fi
      done
      return 1
    }

    _ac_xunbind() {
      _n=$(_ac_xfind bound) || { _ac_k "unbind: no bound xhci-hcd device for $_ac_dev"; return 1; }
      echo "$_n" > "$_ac_xdrv/unbind" 2>/dev/null; _rc=$?
      _ac_k "unbind $_n rc=$_rc up=$( _ac_up )s"
      return 0
    }

    _ac_xbind() {
      _n=$(_ac_xfind unbound) || { _ac_k "bind: no unbound xhci-hcd device for $_ac_dev"; return 1; }
      echo "$_n" > "$_ac_xdrv/bind" 2>/dev/null; _rc=$?
      _ac_k "bind $_n rc=$_rc up=$( _ac_up )s"
      [ "$_rc" -eq 0 ]
    }

    # wait (bounded, 0.1 s steps) for the post-PDR scan to produce a USB disk
    _ac_wait_disk() {   # $1 = max deciseconds
      _w=0
      while [ "$_w" -lt "$1" ]; do
        _ac_usbdisk > /dev/null && return 0
        sleep 0.1; _w=$((_w + 1))
      done
      _ac_usbdisk > /dev/null
    }

    _ac_run() {
      # 0) normal boot?  no dr_mode=host in the live DT -> leave everything alone
      if ! _ac_usbmode; then
        _ac_k "not linux-usb mode (no dr_mode=host on $_ac_dev) at $( _ac_up )s; no rescan"
        return 0
      fi
      # 0b) if the early (pre-PDR) scan already found the drive, nothing to do
      _sd=$(_ac_usbdisk)
      if [ -n "$_sd" ]; then
        _ac_k "already enumerated ($_sd) at $( _ac_up )s; no rescan"
        return 0
      fi
      # the early host controller must exist (created by the ABL dr_mode=host probe)
      _w=0
      while [ ! -e "$_ac_xdrv" ] && [ "$_w" -lt 200 ]; do
        sleep 0.1; _w=$((_w + 1))
      done
      _n=$(_ac_xfind bound) || _n=""
      if [ -z "$_n" ]; then
        _ac_k "FAIL-NO-DEV: no xhci-hcd device for $_ac_dev at $( _ac_up )s"
        return 0
      fi
      _ac_k "start up=$( _ac_up )s: xhci=$_n pdr=$( _ac_pdr && echo yes || echo no ) scan-events=$( _ac_nev )"

      # 1) discard the pre-PDR scan; the controller stays down until the PDR
      _c110a=$(_ac_110)
      _ac_settle
      _ac_xunbind

      # 2) wait for the charger_pd PDR -- the ADSP/typec bring-up event that
      #    precedes the working system's first scan.  (Not /sys/class/typec/
      #    port0: that node exists early in this initramfs, before the PDR.)
      _w=0
      while ! _ac_pdr && [ "$_w" -lt 300 ]; do
        sleep 0.1; _w=$((_w + 1))
      done
      if _ac_pdr; then
        _ac_k "PDR seen at $( _ac_up )s; rebinding"
      else
        _ac_k "WARN: no charger_pd PDR in 30 s; binding anyway (bounded)"
      fi
      _ac_settle

      # 3) re-probe -> fresh host bring-up + first root-hub scan, now post-PDR
      _try=0
      while [ "$_try" -lt 3 ]; do
        _try=$((_try + 1))
        _ac_xbind
        if _ac_wait_disk 100; then
          _sd=$(_ac_usbdisk | tr '\n' ' ')
          _ac_k "ENUMERATION OK at $( _ac_up )s (try $_try, scan-events=$( _ac_nev )): $_sd"
          return 0
        fi
        if [ "$(_ac_110)" -gt "$_c110a" ]; then
          _ac_k "FAIL: Host halt -110 after rebind at $( _ac_up )s; no retry"
          return 0
        fi
        if [ "$_try" -ge 3 ]; then
          break
        fi
        _ac_k "no disk after try $_try at $( _ac_up )s; rebind retry (scan-events=$( _ac_nev ))"
        _ac_xunbind
        _ac_settle
      done
      _ac_k "FAIL-NO-SCAN: no USB disk after $_try tries (last up=$( _ac_up )s, scan-events=$( _ac_nev ))"
      return 0
    }

    _ac_run
    : > "$_ac_done" 2>/dev/null
  ) &
  echo $! > "$_ac_pidfile" 2>/dev/null
fi
