#!/bin/sh
# ARMADA-C2 (lever C v2, 2026-11-12): post-PDR rescan of the USB host
# controller -- the fix of the dbgC-run race.
#
# WHY v2 (dbgC run, 2026-11-12): the dbgC image was built on kernel a699dd6
# WITH patch 1400 ("ignore dr_mode=host when usb-role-switch is present"):
# dwc3 probes in OTG, and the xhci-hcd platform device is created only when
# the UCSI role flip to HOST happens -- after the charger_pd PDR (in the
# run: PDR ~3.5 s, otg enable 5.47 s, data=[host] power=[source] 5.48 s).
# The v1 hook was written for a forced-host kernel, where xhci exists from
# ~2.7 s; it treated "no xhci device at start" as fatal (FAIL-NO-DEV) and
# gave up ~2 s before the controller existed, so the lever-C test never
# ran.  The rest of that run was identical to the successful full-system
# control E (PPM sees the partner, VBUS ~5.06 V, the "bad" fingerprint),
# so the mechanism is sound; only the hook's expectation was wrong.
#
# v2 changes vs v1:
#   1) NO xhci at start is NOT an error (patch-1400 kernel): it is created
#      by the post-PDR role flip and the hook waits for it (<=10 s).  If it
#      DOES exist at start (forced-host kernel) it is still unbound, to
#      discard the pre-PDR scan.
#   2) The rebind is deferred until (a) the charger_pd PDR (<=30 s) AND
#      (b) typec port0 power_role=[source] AND data_role=[host] -- the
#      proxy for "PPM has enabled the OTG VBUS" (<=15 s) AND (c) the xhci
#      device has appeared.  The scan must be post-VBUS, not only
#      post-PDR: in control E the first scan was 12.787 s, otg-enable
#      12.741 s; in the failing dbg1400 run the early scan likely outran
#      the otg-enable.
#   3) A disk produced by the first post-flip scan is accepted WITHOUT a
#      rebind ("ENUMERATION OK (first post-PDR scan)").
#
# Rationale (control boot 2026-11-11, docs/FULL_SYSTEM_PREPLUG_SOURCE_ROLE.md):
# the full system enumerates a pre-plugged direct stick with the failing-side
# PPM fingerprint (usb_type=[Unknown], skip-gate, ncp_stby).  The
# discriminator is ordering: its first xHCI port scan is POST-PDR/POST-VBUS;
# the initramfs scans PRE-PDR.  So: guarantee a fresh first scan after
# PDR+VBUS.
#
# SCOPE: only the xhci-hcd platform device (created by dwc3/host.c:147,
# parent = a600000.usb per host.c:153; quirk data lives on the platform
# device, platform_device_add_data host.c:199, and survives the unbind).
# dwc3-qcom is NOT touched: the dwc3 core registers the usb-role-switch
# device on dwc->dev, UCSI holds a reference to it (ucsi.c:1837) and calls
# usb_role_switch_set_role() on every connector change (ucsi.c:1376,1958);
# unbinding dwc3 would be a use-after-free on the next role change.
#
# NORMAL BOOTS ARE NOT AFFECTED: acts only in `linux usb` mode, detected by
# the live device tree, where ABL injects dr_mode="host" into usb@a600000
# (patch 1400 ignores the value but leaves the property in the FDT).  A
# normal boot has no such property -> no-op.  (Needed because the PDR only
# reaches the initramfs in `linux usb` mode; in a normal boot it arrives at
# ~12 s from the real root, long after switch_root.)
#
# LIFETIME: sourced by dracut-initqueue on EVERY loop iteration (~0.5 s):
# idempotent via pidfile AND done-marker, NEVER `exit` at the top level, no
# `set -e/-u`, variables prefixed _ac_; the sequence runs in a background
# subshell so the initqueue loop is never blocked.
#
# VISIBILITY (lesson of the dbgC photo): "hook loaded" is printed on the
# first sourcing (proves the hook runs at all), every step writes to
# /tmp/armada-c.state and is re-printed at most every 5 s (heartbeat), and
# each step is announced BEFORE the possibly-blocking sysfs write -- so the
# verdict stays on screen despite the lever-B ULog spam.
#
# OUTPUT (all via /dev/kmsg <0>, visible despite console=tty0 quiet):
#   ARMADA-C: <msg>     steps + "hb" heartbeat; the verdict is either
#                       "ENUMERATION OK ...: sdX" or "FAIL-..." (grep-able).

_ac_pidfile=/tmp/armada-c.pid
_ac_done=/tmp/armada-c.done
_ac_seen=/tmp/armada-c.seen
_ac_state=/tmp/armada-c.state
_ac_hb=/tmp/armada-c.hb
_ac_dev=a600000.usb
_ac_dt=/sys/bus/platform/devices/$_ac_dev/of_node
_ac_xdrv=/sys/bus/platform/drivers/xhci-hcd
_ac_tc=/sys/class/typec/port0

_ac_k() { echo "<0>ARMADA-C: $*" > /dev/kmsg 2>/dev/null; }
_ac_now() { cut -d. -f1 /proc/uptime 2>/dev/null; }

# current step text (kept for the heartbeat)
_ac_st() {
  printf '%s' "$*" > "$_ac_state" 2>/dev/null
  _ac_k "$*"
}

# --- heartbeat: re-print the last step at most every 5 s -----------------
if [ -f "$_ac_state" ]; then
  _ac_n=$(_ac_now)
  _ac_l=$(cat "$_ac_hb" 2>/dev/null)
  if [ -z "$_ac_l" ] || [ "$((_ac_n - _ac_l))" -ge 5 ] 2>/dev/null; then
    _ac_k "hb up=${_ac_n}s :: $(cat "$_ac_state" 2>/dev/null)"
    printf '%s' "$_ac_n" > "$_ac_hb" 2>/dev/null
  fi
fi

# --- first sourcing: prove the hook is alive, whatever happens next ------
if [ ! -f "$_ac_seen" ]; then
  : > "$_ac_seen" 2>/dev/null
  _ac_k "hook loaded up=$(_ac_now)s"
fi

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
    _ac_pdr() { dmesg 2>/dev/null | grep -q "PDR: Indication received from msm/adsp/charger_pd"; }
    _ac_110() { dmesg 2>/dev/null | grep -c "Host halt failed, -110"; }
    _ac_settle() { udevadm settle --timeout=10 2>/dev/null; }
    _ac_nev() { dmesg 2>/dev/null | grep -c "new .*-speed USB device"; }

    # a USB-backed block disk (NOT the internal UFS, which also appears as sd*)
    _ac_usbdisk() {
      for _d in /sys/block/sd*; do
        [ -e "$_d" ] || continue
        _r=$( cd -P "$_d" 2>/dev/null && pwd -P )
        case "$_r" in
          *"/usb"*) echo "${_d##*/}"; return 0 ;;
        esac
      done
      return 1
    }

    # `linux usb` mode test: ABL injects dr_mode="host" into the live FDT
    # (patch 1400 ignores the value but leaves the property in the tree)
    _ac_usbmode() {
      [ -e "$_ac_dt/dr_mode" ] || return 1
      _m=$(tr -d '\000' < "$_ac_dt/dr_mode" 2>/dev/null)
      [ "$_m" = host ]
    }

    # xhci-hcd platform device of our controller (child of a600000.usb,
    # dwc3/host.c:153).  The device dir exists whether bound or unbound.
    _ac_xhci() {
      for _x in /sys/bus/platform/devices/$_ac_dev/xhci-hcd.*; do
        [ -e "$_x" ] && { echo "${_x##*/}"; return 0; }; done
      return 1
    }

    # PPM has enabled the OTG VBUS: typec port0 in power=[source] data=[host]
    _ac_roles() {
      _pr=$(cat "$_ac_tc/power_role" 2>/dev/null)
      _dr=$(cat "$_ac_tc/data_role" 2>/dev/null)
      case "$_pr" in *"[source]"*) ;; *) return 1 ;; esac
      case "$_dr" in *"[host]"*) ;; *) return 1 ;; esac
      return 0
    }

    _ac_xunbind() {
      _n=$(_ac_xhci) || { _ac_st "unbind: no xhci device for $_ac_dev at $(_ac_now)s"; return 1; }
      _ac_st "unbinding $_n (phase, up=$(_ac_now)s)"
      echo "$_n" > "$_ac_xdrv/unbind" 2>/dev/null; _rc=$?
      _ac_st "unbind $_n rc=$_rc up=$(_ac_now)s"
      return 0
    }

    _ac_xbind() {
      _n=$(_ac_xhci) || { _ac_st "bind: no xhci device for $_ac_dev at $(_ac_now)s"; return 1; }
      _ac_st "binding $_n (phase, up=$(_ac_now)s)"
      echo "$_n" > "$_ac_xdrv/bind" 2>/dev/null; _rc=$?
      _ac_st "bind $_n rc=$_rc up=$(_ac_now)s"
      [ "$_rc" -eq 0 ]
    }

    # wait (bounded, 0.1 s steps) for the post-PDR scan to produce a USB
    # disk; returns 1 early on a NEW "Host halt failed, -110" (the known
    # qmp-combo defect: a retry cannot recover, stop immediately)
    _ac_wait_disk() {   # $1 = max deciseconds
      _w=0
      while [ "$_w" -lt "$1" ]; do
        _ac_usbdisk > /dev/null && return 0
        [ "$(_ac_110)" -gt "$_c110a" ] && return 1
        sleep 0.1; _w=$((_w + 1))
      done
      _ac_usbdisk > /dev/null
    }

    _ac_run() {
      # 0) normal boot?  no dr_mode=host in the live DT -> leave everything alone
      _ac_m=$(tr -d '\000' < "$_ac_dt/dr_mode" 2>/dev/null)
      if ! _ac_usbmode; then
        _ac_st "not linux-usb mode (dr_mode='$_ac_m' on $_ac_dev) at $(_ac_now)s; no rescan"
        return 0
      fi
      # 0b) if an early scan already found the drive, nothing to do
      _sd=$(_ac_usbdisk)
      if [ -n "$_sd" ]; then
        _ac_st "already enumerated ($_sd) at $(_ac_now)s; no rescan"
        return 0
      fi
      # 1) if the host controller already exists (forced-host kernel), drop
      #    it to discard the pre-PDR scan.  If it does NOT exist (kernel
      #    with patch 1400: OTG probe, xhci created by the post-PDR role
      #    flip) that is NOT an error -- step 4 waits for it.
      _ac_settle
      _c110a=$(_ac_110)
      _n=$(_ac_xhci)
      if [ -n "$_n" ]; then
        _ac_st "start up=$(_ac_now)s: dr_mode='$_ac_m' xhci=$_n (forced-host: unbind to discard pre-PDR scan) pdr=$(_ac_pdr && echo yes || echo no)"
        _ac_xunbind
      else
        _ac_st "start up=$(_ac_now)s: dr_mode='$_ac_m' xhci=ABSENT (patch-1400 kernel: xhci appears with the post-PDR role flip) pdr=$(_ac_pdr && echo yes || echo no)"
      fi
      # 2) wait for the charger_pd PDR (<=30 s, event-driven; the ADSP/
      #    typec bring-up event that precedes the working system's scan)
      _w=0
      while ! _ac_pdr && [ "$_w" -lt 300 ]; do
        sleep 0.1; _w=$((_w + 1))
      done
      if _ac_pdr; then
        _ac_st "PDR seen at $(_ac_now)s"
      else
        _ac_st "WARN: no charger_pd PDR in 30 s; continuing (bounded)"
      fi
      # 3) wait for PPM to enable the OTG VBUS: typec port0 source+host
      #    (<=15 s).  The scan must be post-VBUS, not only post-PDR.
      _w=0
      while ! _ac_roles && [ "$_w" -lt 150 ]; do
        sleep 0.1; _w=$((_w + 1))
      done
      _ac_pr=$(cat "$_ac_tc/power_role" 2>/dev/null)
      _ac_dr=$(cat "$_ac_tc/data_role" 2>/dev/null)
      if _ac_roles; then
        _ac_st "source+host at $(_ac_now)s (power='$_ac_pr' data='$_ac_dr')"
      else
        _ac_st "WARN: no source+host role in 15 s (power='$_ac_pr' data='$_ac_dr'); continuing (bounded)"
      fi
      # 4) wait for the xhci device to appear (created by the role flip)
      _ac_settle
      _w=0; _n=""
      while [ "$_w" -lt 100 ]; do
        _n=$(_ac_xhci) && break
        sleep 0.1; _w=$((_w + 1))
      done
      if [ -z "$_n" ]; then
        _ac_st "FAIL-NO-DEV: xhci-hcd never appeared after PDR (last up=$(_ac_now)s)"
        return 0
      fi
      _ac_st "xhci=$_n at $(_ac_now)s; checking the first post-flip scan"
      # 5) if the first post-flip scan already produced the disk, done
      _sd=$(_ac_usbdisk)
      if [ -n "$_sd" ]; then
        _ac_st "ENUMERATION OK (first post-PDR scan) at $(_ac_now)s: $_sd"
        return 0
      fi
      # 6) guarantee a fresh scan: unbind+bind (fresh HCRST + new root-hub
      #    scan), verify <=10 s, up to 3 tries, hard stop on a new
      #    "Host halt failed, -110" (known qmp-combo defect, no retry)
      _try=0
      while [ "$_try" -lt 3 ]; do
        _try=$((_try + 1))
        _ac_xunbind
        _ac_settle
        _ac_xbind
        if _ac_wait_disk 100; then
          _sd=$(_ac_usbdisk | tr '\n' ' ')
          _ac_st "ENUMERATION OK at $(_ac_now)s (try $_try, scan-events=$(_ac_nev)): $_sd"
          return 0
        fi
        if [ "$(_ac_110)" -gt "$_c110a" ]; then
          _ac_st "FAIL: Host halt -110 after rebind at $(_ac_now)s; no retry"
          return 0
        fi
        if [ "$_try" -ge 3 ]; then
          break
        fi
        _ac_st "no disk after try $_try at $(_ac_now)s; rebind retry (scan-events=$(_ac_nev))"
      done
      _ac_st "FAIL-NO-SCAN: no USB disk after $_try tries (last up=$(_ac_now)s, scan-events=$(_ac_nev))"
      return 0
    }

    _ac_run
    : > "$_ac_done" 2>/dev/null
  ) &
  echo $! > "$_ac_pidfile" 2>/dev/null
fi
