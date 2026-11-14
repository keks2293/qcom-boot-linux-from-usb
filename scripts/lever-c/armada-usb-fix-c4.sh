#!/bin/sh
# ARMADA-C4 (lever C v4, 2026-11-12): v3 logic + the run-4 corrections:
#
#   1) PARTNER GATE (run 4, 2026-11-12, the first genuine dbgC3 run): the
#      v2/v3 assumption "typec port0 [source]+[host] = PPM enabled the OTG
#      VBUS" is WRONG.  Run 4: the roles were set at 3.66 s (UCSI sets them
#      when it registers the port, ucsi.c:1837,1958) while the PPM actually
#      enabled the OTG VBUS ("otg enable: 1") at 5.44 s, ~1.8 s LATER; the
#      xhci-hcd device appeared at 3.67 s right after the role set, i.e. it
#      is created by the ROLE FLIP, not by the VBUS.  The reliable
#      post-VBUS marker is the appearance of port0-partner (~5.4 s in the
#      run; ucsi_register_partner() at ucsi.c:1944, called from the port
#      registration after GET_CONNECTOR_STATUS, ucsi.c:1916).  v4 therefore
#      gates the first rebind on /sys/class/typec/port0-partner (<=20 s);
#      the roles are still logged (informational).  On a forced-host kernel
#      (no patch 1400: dwc3 in HOST mode, no role switch, the UCSI probe
#      hard-fails at ucsi.c:1838-1840 -> no port0 at all) the partner never
#      appears: the gate is a bounded WARN, not fatal.
#   2) RUN-4 VERDICT: FAIL-NO-SCAN with a LIVE controller (scan-events=0 in
#      all three rebinds, two of them post-VBUS; controller alive, both root
#      hubs up, role host, PPM sees the partner, VBUS out).  "Scan ordering
#      is the whole bug" is refuted in the strong form.  The next lever is
#      the FULL CHAIN reset, now automated here (item 4).
#   3) DUMP additions: port0/orientation (values unknown|normal|reverse,
#      drivers/usb/typec/class.c:1678-1682, RO attr :2031 -- a "reverse"
#      reading means: flip the plug and re-run the SAME image, the data
#      path can stay unrouted otherwise; test D), partner yes/no, and the
#      xhci -> usbN mapping (the usb bus is a child of the xhci platform
#      device, so `ls` of each xhci child dir shows which root hub, usb1 /
#      usb2, belongs to it).
#   4) FULL-CHAIN ESCALATION (the next lever, code-verified; runs only on
#      the FAIL-NO-SCAN / FAIL-NO-DEV branches, never on the success or
#      -110 paths, so the primary verdict is untouched):
#         unbind: UCSI -> xhci -> dwc3
#           * UCSI is an AUXILIARY driver: /sys/bus/auxiliary/drivers/
#             pmic_glink_ucsi, device pmic_glink.ucsi.0 (ucsi_glink.c:480-
#             487, auxiliary.c:325, pmic_glink.c:329).  It MUST go first:
#             UCSI holds a reference to the dwc3 usb-role-switch
#             (ucsi.c:1837) and calls usb_role_switch_set_role() on every
#             connector change (ucsi.c:1376,1958); unbinding dwc3 under a
#             live UCSI reference would unregister the switch out from
#             under it (use-after-free).  If the UCSI unbind FAILS the
#             escalation aborts and dwc3 is NOT touched (safety).
#           * dwc3 unbind = dwc3_core_remove (drivers/usb/dwc3/core.c:
#             2409-2436) -> dwc3_core_exit_mode (:2413) -> OTG:
#             dwc3_drd_exit (drd.c:596-624): role-switch unregister
#             (:600-601) + dwc3_host_exit while current_dr_role==HOST
#             (:610-612, destroys the xhci platform device) ->
#             dwc3_core_exit (:2416).
#         rebind: dwc3 -> UCSI
#           * dwc3 FIRST: dwc3_drd_init (drd.c:546-552) re-registers the
#             role switch (drd.c:504-540), initial mode DEVICE (no
#             default-role in the image DTB).  The UCSI probe HARD-FAILS
#             without a registered switch (ucsi.c:1838-1840), so dwc3
#             must be rebound before UCSI.
#           * UCSI then COMPLETES THE CHAIN BY ITSELF (no further action):
#             port registration -> GET_CONNECTOR_STATUS (ucsi.c:1916; the
#             PPM never de-plugged the stick -> CONNECTED) -> partner UFP
#             -> u_role = USB_ROLE_HOST (ucsi.c:1925-1928) +
#             ucsi_register_partner (ucsi.c:1944) + ucsi_orientation
#             (ucsi.c:1946) -> usb_role_switch_set_role(HOST) (ucsi.c:1958)
#             -> dwc3_usb_role_switch_set (drd.c:450-474) ->
#             dwc3_set_mode(HOST) -> CORESOFTRESET + dwc3_host_init
#             (core.c:244) -> xhci-hcd.* RECREATED -> auto-bind -> fresh
#             root hub -> fresh scan.
#         The new xhci device may get a DIFFERENT auto ID (xhci-hcd.2.auto
#         -> xhci-hcd.3.auto etc.; the platform auto-ID pool re-allocates),
#         so the hook looks it up dynamically (glob xhci-hcd.* under
#         a600000.usb) and never hard-codes a number.
#         Verdicts: "ENUMERATION OK (full-chain)" (beta-1: the residual
#         blocker was state left in dwc3/UCSI) or
#         "FAIL-NO-SCAN-FULL" (beta-2: the blocker is below dwc3 -- PHY /
#         eUSB2 repeater / PPM data path / plug orientation).
#   5) wait_disk OPTIMIZATION (run 4: "10 s" cost ~12.7 s of wall clock):
#      the UFS LUNs (sda..sdf, also sd*) are resolved once and cached;
#      later iterations only resolve NEW sd* entries; sleep 0.5 instead of
#      0.1; the "Host halt failed, -110" dmesg check runs every 2nd
#      iteration (1 s granularity for the safety stop is fine -- the event
#      persists in the ring buffer).
#
# Everything else is v3 (dbgC3, which ran on hardware for the first time in
# run 4 and behaved exactly as designed): v2 logic (xhci-absent-at-start is
# not an error on the patch-1400 kernel; forced-host xhci is unbound to
# discard the pre-PDR scan; PDR wait <=30 s; disk from the first post-flip
# scan is accepted without a rebind; <=3 rebind tries with a hard stop on a
# NEW "Host halt failed, -110" -- known qmp-combo defect, a retry cannot
# recover), the dracut-initqueue lifetime contract (sourced every ~0.5 s:
# idempotent via pidfile AND done-marker, no top-level exit, no set -e/-u,
# _ac_-prefixed variables, sequence in a background subshell), the
# normal-boot gate (act only if the live FDT has dr_mode="host", which ABL
# injects only in `linux usb` mode; patch 1400 ignores the value but leaves
# the property in the FDT), the USB-backed sd* disk detection (the internal
# UFS is sd* too), no readlink -f (cd -P / pwd -P builtins), and the
# v3 one-shot device-tree dump (t10 / WARN-nopdr / WARN-nopartner /
# NO-DEV / halt-110 / NO-SCAN / ESC / NO-XHCI-ESC / ESC-ABORT /
# NO-SCAN-FULL / OK / OK-FULL) -- all via /dev/kmsg <0>, grep "ARMADA-C:".
#
# Firmware assumptions (NOT verifiable in the open sources; the PPM/ADSP
# side is closed): (a) the PPM-side UCSI/Type-C state (the stick is still
# CONNECTED, partner UFP) survives the UCSI driver unbind/rebind --
# ucsi_unregister (ucsi_glink.c:470-472) only stops the Linux-side
# read/write, the hardware/PPM is untouched, and the rebind's
# GET_CONNECTOR_STATUS re-queries the PPM; (b) the plug orientation and
# the SBU/repeater routing are correct (that is what the orientation dump
# line checks at runtime).

_ac_pidfile=/tmp/armada-c.pid
_ac_done=/tmp/armada-c.done
_ac_seen=/tmp/armada-c.seen
_ac_state=/tmp/armada-c.state
_ac_hb=/tmp/armada-c.hb
_ac_dev=a600000.usb
_ac_dt=/sys/bus/platform/devices/$_ac_dev/of_node
_ac_xdrv=/sys/bus/platform/drivers/xhci-hcd
_ac_ddrv=/sys/bus/platform/drivers/dwc3-qcom
_ac_udrv=/sys/bus/auxiliary/drivers/pmic_glink_ucsi
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

    # a USB-backed block disk (NOT the internal UFS, which also appears as
    # sd*).  The non-USB sd* names (the UFS LUNs) are resolved ONCE and
    # cached in _ac_ufs; later calls only resolve NEW entries (v4: run-4
    # wall-clock cost was ~12.7 s for a "10 s" wait, mostly the six LUN
    # cd -P/pwd -P resolutions per iteration).
    _ac_ufs=""
    _ac_usbdisk() {
      for _d in /sys/block/sd*; do
        [ -e "$_d" ] || continue
        _dn=${_d##*/}
        case " $_ac_ufs " in *" $_dn "*) continue ;; esac
        _r=$( cd -P "$_d" 2>/dev/null && pwd -P )
        case "$_r" in
          *"/usb"*) echo "${_d##*/}"; return 0 ;;
          *) _ac_ufs="$_ac_ufs $_dn" ;;
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
    # NEVER hard-code the auto ID: after a full-chain reset the recreated
    # device may be xhci-hcd.3.auto etc. (the platform auto-ID pool).
    _ac_xhci() {
      for _x in /sys/bus/platform/devices/$_ac_dev/xhci-hcd.*; do
        [ -e "$_x" ] && { echo "${_x##*/}"; return 0; }; done
      return 1
    }

    # UCSI auxiliary device (auxiliary.c:325: <modname>.<name>.<id>;
    # pmic_glink.c:329 adds the "ucsi" aux device; ucsi_glink.c:480-487
    # binds it).  Empty when the driver is not registered.
    _ac_ucsi_dev() {
      for _u in /sys/bus/auxiliary/devices/pmic_glink.ucsi.*; do
        [ -e "$_u" ] && { echo "${_u##*/}"; return 0; }; done
      return 1
    }

    # v4 gate: the PPM has enabled the OTG VBUS and UCSI registered the
    # partner (port0-partner appears at ~5.4 s in run 4, right at the
    # "otg enable: 1" moment; ucsi_register_partner, ucsi.c:1944).  The
    # bare roles are NOT a proxy (run 4: roles at 3.66 s, pre-VBUS).
    _ac_partner() { [ -e "$_ac_tc-partner" ]; }

    # --- v3/v4: device-tree snapshot -------------------------------------
    # the discriminator the quiet console hides: "xhci was created, a scan
    # ran, found nothing" vs "xhci was never created at all".  Read-only
    # sysfs; every line tagged so grep "ARMADA-C: TREE[<tag>]" works.
    # v4 adds: the port orientation (unknown|normal|reverse -- "reverse"
    # means flip the plug and re-run the same image) and the xhci -> usbN
    # root-hub mapping (the usb bus is a child of the xhci platform device).
    _ac_tree() {   # $1 = tag
      _tu=$(_ac_now)
      _ac_k "TREE[$1] up=${_tu}s a600000.usb: [$(ls /sys/bus/platform/devices/$_ac_dev/ 2>/dev/null | tr '\n' ' ')]"
      for _r in /sys/class/usb_role/*/role; do
        [ -e "$_r" ] || continue
        _ac_k "TREE[$1] up=${_tu}s role ${_r%%/role}: [$(cat "$_r" 2>/dev/null)]"
      done
      _ac_k "TREE[$1] up=${_tu}s typec: orientation=[$(cat "$_ac_tc/orientation" 2>/dev/null)] partner=$([ -e "$_ac_tc-partner" ] && echo yes || echo no)"
      for _x in /sys/bus/platform/devices/$_ac_dev/xhci-hcd.*; do
        [ -e "$_x" ] || continue
        _ac_k "TREE[$1] up=${_tu}s xhci ${_x##*/} -> [$(ls "$_x" 2>/dev/null | grep '^usb' | tr '\n' ' ')]"
      done
      _ac_k "TREE[$1] up=${_tu}s /sys/block: [$(ls /sys/block/ 2>/dev/null | tr '\n' ' ')]"
      if command -v lsusb >/dev/null 2>&1; then
        _ac_k "TREE[$1] up=${_tu}s lsusb: [$(lsusb 2>/dev/null | tr '\n' ' ')]"
      else
        _ac_k "TREE[$1] up=${_tu}s usb: [$(ls /sys/bus/usb/devices/ 2>/dev/null | tr '\n' ' ')]"
      fi
    }

    # one-shot: print the tree at up=10 s while the sequence is still
    # running (called from every wait loop; fires at most once)
    _ac_maybedump() {
      [ "$_ac_dumped" -eq 1 ] && return 0
      _up=$(_ac_now)
      [ -n "$_up" ] || return 0
      if [ "$_up" -ge 10 ] 2>/dev/null; then
        _ac_dumped=1
        _ac_tree t10
      fi
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

    # wait (bounded, 0.5 s steps) for the post-PDR scan to produce a USB
    # disk; returns 1 early on a NEW "Host halt failed, -110" (the known
    # qmp-combo defect: a retry cannot recover, stop immediately).  v4:
    # the -110 dmesg check runs every 2nd iteration (the event persists in
    # the ring buffer; 1 s stop granularity is fine).
    _ac_wait_disk() {   # $1 = max half-seconds
      _w=0
      while [ "$_w" -lt "$1" ]; do
        _ac_usbdisk > /dev/null && return 0
        if [ $((_w % 2)) -eq 0 ] && [ "$(_ac_110)" -gt "$_c110a" ]; then
          return 1
        fi
        _ac_maybedump
        sleep 0.5; _w=$((_w + 1))
      done
      _ac_usbdisk > /dev/null
    }

    # --- v4: the full-chain escalation (see the header for the code
    # provenance and WHY each order is what it is) ------------------------
    _ac_escalate() {
      _u=$(_ac_ucsi_dev)
      _n=$(_ac_xhci)
      _ac_st "ESCALATE at $(_ac_now)s: full-chain reset (ucsi=${_u:-ABSENT} xhci=${_n:-ABSENT} dwc3=$_ac_dev)"
      _ac_k "ESCALATE: unbind order ucsi -> xhci -> dwc3, rebind order dwc3 -> ucsi (UCSI holds the role-switch ref: ucsi.c:1837)"
      _ac_tree ESC
      # unbind: UCSI first (safety: if it stays bound, dwc3 removal would
      # unregister the role switch under a live UCSI reference -- abort
      # instead of risking the UAF)
      if [ -n "$_u" ]; then
        echo "$_u" > "$_ac_udrv/unbind" 2>/dev/null; _r1=$?
      else
        _r1=127
      fi
      if [ "$_r1" -ne 0 ]; then
        _ac_tree ESC-ABORT
        _ac_st "FAIL-ESCALATE: ucsi unbind rc=$_r1 (ucsi=${_u:-ABSENT}); dwc3 NOT touched (role-switch ref safety)"
        return 0
      fi
      echo "$_n" > "$_ac_xdrv/unbind" 2>/dev/null; _r2=$?
      echo "$_ac_dev" > "$_ac_ddrv/unbind" 2>/dev/null; _r3=$?
      _ac_st "ESCALATE: unbind done ucsi rc=$_r1 xhci rc=${_r2:-127} dwc3 rc=$_r3 up=$(_ac_now)s"
      if [ "$_r3" -ne 0 ]; then
        _ac_st "FAIL-ESCALATE: dwc3 unbind rc=$_r3; cannot continue"
        return 0
      fi
      # rebind: dwc3 first (re-registers the role switch; the UCSI probe
      # hard-fails without it, ucsi.c:1838-1840), then UCSI
      echo "$_ac_dev" > "$_ac_ddrv/bind" 2>/dev/null; _r1=$?
      _ac_st "ESCALATE: rebind dwc3 rc=$_r1 up=$(_ac_now)s"
      if [ "$_r1" -ne 0 ]; then
        _ac_st "FAIL-ESCALATE: dwc3 rebind rc=$_r1; cannot continue"
        return 0
      fi
      _ac_settle
      if [ -n "$_u" ]; then
        echo "$_u" > "$_ac_udrv/bind" 2>/dev/null; _r2=$?
      else
        _r2=127
      fi
      _ac_st "ESCALATE: rebind ucsi rc=${_r2:-127} up=$(_ac_now)s (UCSI now completes the chain by itself: GET_CONNECTOR_STATUS -> partner -> set_role(HOST) -> xhci recreated)"
      # wait for the (re)created xhci child -- possibly under a NEW auto ID
      _w=0; _n=""
      while [ "$_w" -lt 30 ]; do
        _n=$(_ac_xhci) && break
        _ac_maybedump
        sleep 0.5; _w=$((_w + 1))
      done
      if [ -z "$_n" ]; then
        _ac_tree NO-XHCI-ESC
        _ac_st "FAIL-ESCALATE: no xhci device after full-chain reset (up=$(_ac_now)s)"
        return 0
      fi
      _ac_st "ESCALATE: xhci=$_n at $(_ac_now)s; waiting for the fresh full-chain scan"
      _ac_settle
      if _ac_wait_disk 30; then
        _sd=$(_ac_usbdisk | tr '\n' ' ')
        _ac_st "ENUMERATION OK (full-chain) at $(_ac_now)s: $_sd (scan-events=$(_ac_nev))"
        _ac_tree OK-FULL
        return 0
      fi
      if [ "$(_ac_110)" -gt "$_c110a" ]; then
        _ac_tree halt-110-full
        _ac_st "FAIL: Host halt -110 after full-chain reset at $(_ac_now)s; no retry"
        return 0
      fi
      _ac_tree NO-SCAN-FULL
      _ac_st "FAIL-NO-SCAN-FULL: no USB disk after full-chain reset (last up=$(_ac_now)s, scan-events=$(_ac_nev))"
      return 0
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
      #    flip) that is NOT an error -- step 3 waits for it.
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
      while ! _ac_pdr && [ "$_w" -lt 60 ]; do
        _ac_maybedump
        sleep 0.5; _w=$((_w + 1))
      done
      if _ac_pdr; then
        _ac_st "PDR seen at $(_ac_now)s"
      else
        _ac_tree WARN-nopdr
        _ac_st "WARN: no charger_pd PDR in 30 s; continuing (bounded)"
      fi
      # 3) wait for the xhci device to appear (created by the role flip;
      #    run 4: 3.67 s, right after the role set -- NOT after the VBUS)
      _ac_settle
      _w=0; _n=""
      while [ "$_w" -lt 30 ]; do
        _n=$(_ac_xhci) && break
        _ac_maybedump
        sleep 0.5; _w=$((_w + 1))
      done
      if [ -n "$_n" ]; then
        _ac_st "xhci=$_n at $(_ac_now)s"
      else
        _ac_st "xhci-hcd still absent at $(_ac_now)s (role flip pending?)"
      fi
      # 4) v4 GATE: wait for port0-partner (<=20 s) -- the real post-VBUS
      #    marker (run 4: partner ~5.4 s == "otg enable: 1" 5.44 s; the
      #    bare roles at 3.66 s were PRE-VBUS and useless as a gate).
      _w=0
      while ! _ac_partner && [ "$_w" -lt 40 ]; do
        _ac_maybedump
        sleep 0.5; _w=$((_w + 1))
      done
      _ac_pr=$(cat "$_ac_tc/power_role" 2>/dev/null)
      _ac_dr=$(cat "$_ac_tc/data_role" 2>/dev/null)
      if _ac_partner; then
        _ac_st "partner at $(_ac_now)s (port0-partner; power='$_ac_pr' data='$_ac_dr') -- OTG VBUS is out"
      else
        _ac_tree WARN-nopartner
        _ac_st "WARN: no port0-partner in 20 s (power='$_ac_pr' data='$_ac_dr'); continuing (bounded)"
      fi
      # 5) if the first post-flip scan already produced the disk, done
      if [ -n "$_n" ]; then
        _sd=$(_ac_usbdisk)
        if [ -n "$_sd" ]; then
          _ac_st "ENUMERATION OK (first post-PDR scan) at $(_ac_now)s: $_sd"
          _ac_tree OK
          return 0
        fi
      fi
      # 6) guarantee a fresh scan: unbind+bind (fresh HCRST + new root-hub
      #    scan), verify <=10 s, up to 3 tries, hard stop on a new
      #    "Host halt failed, -110" (known qmp-combo defect, no retry)
      if [ -n "$_n" ]; then
        _try=0
        while [ "$_try" -lt 3 ]; do
          _try=$((_try + 1))
          _ac_xunbind
          _ac_settle
          _ac_xbind
          if _ac_wait_disk 20; then
            _sd=$(_ac_usbdisk | tr '\n' ' ')
            _ac_st "ENUMERATION OK at $(_ac_now)s (try $_try, scan-events=$(_ac_nev)): $_sd"
            _ac_tree OK
            return 0
          fi
          if [ "$(_ac_110)" -gt "$_c110a" ]; then
            _ac_tree halt-110
            _ac_st "FAIL: Host halt -110 after rebind at $(_ac_now)s; no retry"
            return 0
          fi
          if [ "$_try" -ge 3 ]; then
            break
          fi
          _ac_st "no disk after try $_try at $(_ac_now)s; rebind retry (scan-events=$(_ac_nev))"
        done
        _ac_tree NO-SCAN
        _ac_st "FAIL-NO-SCAN: no USB disk after $_try tries (last up=$(_ac_now)s, scan-events=$(_ac_nev)); escalating to the full chain"
      else
        _ac_tree NO-DEV
        _ac_st "FAIL-NO-DEV: xhci-hcd never appeared after PDR (last up=$(_ac_now)s); escalating to the full chain"
      fi
      # 7) v4: the full-chain escalation (UCSI -> xhci -> dwc3 unbind,
      #    dwc3 -> UCSI rebind; the chain then completes itself).  Only
      #    the NO-SCAN / NO-DEV branches reach here; the -110 path
      #    returned above (a retry cannot recover that defect).
      _ac_escalate
      return 0
    }

    _ac_dumped=0
    _ac_run
    : > "$_ac_done" 2>/dev/null
  ) &
  echo $! > "$_ac_pidfile" 2>/dev/null
fi
