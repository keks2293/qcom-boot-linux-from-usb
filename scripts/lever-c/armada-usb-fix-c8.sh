#!/bin/sh
# ARMADA-C8 (lever C v8, 2026-11-14): v5 logic + SCAN-BASED REPEATER
# REGISTER DUMP (v6 = the dump itself; v7 = step markers, console-noise
# suppression, bounded read, SPMI-timeout counters; v8 = the v6/v7
# RESOLVE chain -- which run 3 proved to hang -- is GONE: no platform-
# device glob, no cd/pwd on a sysfs symlink, no [ -e ]; the repeater
# regmap is identified by SCANNING the debugfs regmap dirs and its own
# fd08=80/fd46=80 signature)
# ESCALATION (user design decision after the run-4 finale photo):
#
#   Run 4 (dbgC3, 2026-11-12, first genuine lever-C run) ended with the
#   exact-dmesg finale: bind rc=0 x3 @3.820063/16.622653/29.269736 s;
#   TREE[NO-SCAN] @41.826-41.835 s with the controller ALIVE AND BOUND to
#   the end (a600000.usb: [... usb_role xhci-hcd.2.auto], role [host],
#   usb1+usb2 up, /sys/block without sdX); verdict
#   "FAIL-NO-SCAN: no USB disk after 3 tries (last up=41s, scan-events=0)"
#   @41.845720; no "Host halt failed, -110" at all.  The xhci-only path
#   "worked correctly" for 41.8 s (VBUS out, role host, PPM sees the
#   partner, scans ran) and found NOTHING: the residual blocker is in the
#   data path BELOW xhci.  The v4 strategy (3 xhci rebind tries, escalate
#   at ~36-38 s, fresh full-chain scan at ~39 s, verdict ~53 s) therefore
#   puts its only remaining chance (the full chain) OUTSIDE the ~30 s PPM
#   window: every historical replug success is consistent with an EARLY
#   re-attach (<=24.7 s, before the 30 s boundary), every failure is LATE
#   (38-102 s); the boundary is either the AP-side regulator cleanup
#   (regulator/core.c:6904, msecs_to_jiffies(30000)) or the PPM's own
#   attach->lockout timeout.  v5 therefore escalates IMMEDIATELY after the
#   FIRST post-partner scan failure (~8-10 s total, inside the window
#   under BOTH interpretations) -- strictly better than v4 under both.
#
#   v5 changes vs v4 (nothing else):
#     * the 3-try xhci rebind loop is DELETED: run 4 proved it useless
#       (scan-events=0 x3, two of them post-VBUS);
#     * the first post-partner scan gets a short bounded window
#       (_ac_wait_disk 6 = 3 s; the working full-system scan lands ~0.3 s
#       after the role flip, so 3 s is generous) with the same -110 guard;
#     * no disk in that window (or xhci never appeared: NO-DEV) => the
#       full-chain escalation runs NOW, not after 3 tries;
#     * the escalation itself (_ac_escalate) is byte-for-byte v4: unbind
#       UCSI -> xhci -> dwc3 (UCSI first: it holds the dwc3 role-switch
#       reference, ucsi.c:1837, and calls set_role on every connector
#       change, ucsi.c:1376,1958; on failed UCSI unbind the escalation
#       ABORTS and dwc3 is NOT touched -- use-after-free safety), rebind
#       dwc3 -> UCSI (the UCSI probe hard-fails without a registered
#       switch, ucsi.c:1838-1840, so dwc3 must come first), then UCSI
#       completes the chain by itself: GET_CONNECTOR_STATUS (ucsi.c:1916,
#       the PPM never de-plugged the stick -> CONNECTED) -> partner UFP ->
#       set_role(HOST) (ucsi.c:1958) -> dwc3 CORESOFTRESET +
#       dwc3_host_init (core.c:244) -> xhci RECREATED (possibly under a
#       NEW auto ID, xhci-hcd.3.auto: the hook looks it up by glob, never
#       hard-coded) -> fresh root hub -> fresh scan.
#   Verdicts (unchanged matrix): "ENUMERATION OK (first post-PDR scan)" /
#   "ENUMERATION OK (full-chain)" (beta-1: the residual blocker was state
#   left in dwc3/UCSI by the pre-PDR scan / ABL session) /
#   "FAIL-NO-SCAN-FULL" (beta-2: the blocker is below dwc3 -- PHY /
#   eUSB2 repeater / PPM data path / plug orientation) /
#   "FAIL: Host halt -110" (no retry, known qmp-combo defect) /
#   "FAIL-ESCALATE" / "NO-XHCI-ESC".
#
#   v5 RUN-5 CORRECTIONS (dbgC4 ran on 2026-11-13; three findings):
#   1) orientation=[normal] (TREE[t10]) -- the reverse-plug hypothesis is
#      CLOSED (the cheap check worked as designed).
#   2) The port0-partner gate is STILL pre-VBUS in reality: run 5 partner
#      @3.88 s while "otg enable: 1" (the real VBUS, lever-B ULog in
#      kmsg) @5.436 s.  The v4 assumption "partner ~5.4 s = post-VBUS
#      marker" was wrong -- UCSI registers the partner at port
#      registration, early, like the roles (3.74-3.88 s).  The gate is
#      therefore relabeled: it gates on "the PPM sees the stick
#      (CONNECTED + partner)" (which is what the full chain's re-query
#      needs), and the VBUS state is printed informationally from the
#      ULog line "otg enable: 1" (the only true VBUS proxy, with
#      voltage_now).
#   3) CRITICAL: the v4/v5 hard-coded UCSI driver path
#      /sys/bus/auxiliary/drivers/pmic_glink_ucsi DOES NOT EXIST in the
#      running kernel (run 5: ESCALATE aborted on the first step,
#      "No such file or directory", rc=1; the UAF abort-guard worked --
#      dwc3 was not touched -- but the full chain never ran, so beta-1/
#      beta-2 are still UNTESTED).  ucsi_glink is built-in
#      (CONFIG_UCSI_PMIC_GLINK=y) and the built-kernel sysfs layout
#      evidently differs from the source name (ucsi_glink.c .name =
#      "pmic_glink_ucsi"); the ground truth is sysfs, not the source.
#      v5 therefore RESOLVES THE DRIVER AT RUNTIME: the UCSI device is
#      found by glob (pmic_glink.ucsi.* on the auxiliary bus, fallback
#      *ucsi* on ALL buses), and its driver is resolved from the
#      device's own `driver` symlink (cd -P / pwd -P -- no readlink -f).
#      An ESCDIAG dump (aux devices/drivers, all *ucsi* candidates with
#      their resolved driver or UNBOUND) is printed right before the
#      unbind so the next photo shows the real layout.  If the device is
#      missing or has no bound driver, the escalation aborts (ESC-ABORT)
#      and dwc3 is NOT touched -- the full chain cannot complete
#      without a bindable UCSI (its rebind is what re-runs
#      GET_CONNECTOR_STATUS -> set_role(HOST) -> xhci recreation).
#
#   v6 changes (dbgC6, 2026-11-13; the DUMP image -- nothing else):
#     * REPEATER REGISTER DUMP (the decisive experiment of the
#       31bc94de-regression hypothesis): the pm8550b eUSB2 repeater
#       block 0xfd00-0xfd5b (92 x 16-bit registers) is read via the
#       regmap debugfs 'registers' file -- already built into the CI
#       kernel (regmap-debugfs.o builds under CONFIG_DEBUG_FS,
#       drivers/base/regmap/Makefile:7; there is no CONFIG_REGMAP_DEBUGFS
#       option in 7.2.6) -- and printed compactly (8 per line) plus the
#       RPT-KEY (the 8 never-kernel-written tuning registers: the
#       residue candidates) and RPT-WRN (the kernel-written / RO status
#       registers, with the expected values) summary lines.  In
#       'linux usb' the dump runs AFTER the full chain (the state the
#       chain left); in a normal boot it waits for the stick to
#       enumerate (<=45 s -- the repeater is initialized by then; the
#       boot is NOT blocked, the subshell is backgrounded).
#     * The PMIC regmap directory is RESOLVED AT RUNTIME (never
#       hard-coded -- the UCSI lesson): the repeater platform device
#       (glob *eusb2*; an of_platform child of the PMIC spmi device,
#       devm_of_platform_populate qcom-spmi-pmic.c:284) -> its parent
#       directory name = the spmi dev_name (spmi.c:67, "%d-%02x") = the
#       regmap debugfs dir name (regmap-debugfs.c:574-587,603).
#     * debugfs is mounted on demand (grep /proc/mounts).
#     * Read mechanics (7.2.6, code-verified): 9 B/line ("XXXX: XX\n":
#       reg_len 4 for max_register 0xffff, val_len 2 for val_bits 8,
#       regmap-debugfs.c:182-192); the reader walks to the ppos in
#       SOFTWARE before any HW read (regmap_debugfs_get_dump_start,
#       regmap-debugfs.c:96-180) -> the block is read with
#       `tail -c +582913 | sed -n 1,92p` (offset = 0xfd00 x 9, 1-based;
#       no dd/head in the initramfs, GNU tail on the Fedora image).
#       The 8 KEY registers are NOT in the regmap cache (the kernel
#       never read or wrote them -- 31bc94de removed the zero-out) ->
#       the dump returns live HW values.  The RPT-WRN values are
#       cache hits of the kernel's own writes (identical to HW).
#       The WRITE path (the later step A/B test) is the 1401 kernel
#       patch (REGMAP_ALLOW_WRITE_DEBUGFS) -- NOT in this image.
#
#   v7 changes (dbgC7, 2026-11-13; the INSTRUMENTED DUMP -- nothing else):
#     * Run 2 (dbgC6, 'linux usb'): the v5 chain re-confirmed the CLEAN
#       BETA-2 (rc=0 x3, TREE[NO-SCAN-FULL] @23 s, scan-events=0) and the
#       dump printed its FIRST line ("RPT-DUMP: linux-usb mode; dumping
#       after the chain" @23.629 s) and then nothing for 28 s (heartbeats
#       alive) -- i.e. the stall is between the mode line and the
#       resolution line (mount / glob / resolve) or in the read, and v6
#       had no marker to tell them apart.
#     * Diagnosed in the 7.2.6 sources: the 'registers' read from ppos
#       582912 covers 0xfd00..0xffff = 768 SPMI reads, and
#       regmap_readable() is TRUE for every one of them (the pm8550b
#       regmap: max_register 0xffff, no readable_reg callback), so the
#       676 registers 0xfd5c..0xffff are really sent to the PMIC, which
#       NAKs: each burns the arbiter poll loop (1000 x udelay(1) = 1 ms,
#       spmi-pmic-arb.c:102,:390,:401) AND prints a 'timeout' dev_err.
#       On the diag console those 676 lines are the plausible ~30 s.
#     * FIX: step markers RPT-S0..S5 (before AND after every step that
#       can block) so the next run pinpoints the blocking step even if it
#       stalls again; the console is set to loglevel 1 (dmesg -n 1) for
#       the read and restored afterwards (our <0> markers still print);
#       the SPMI timeout counter is printed before/after (dmesg |
#       grep -c pmic_arb_wait_for_done) as direct evidence; the read runs
#       under `timeout 55` PLUS a kill watchdog (50 s + 5 s grace) and
#       reports its byte count every 5/10/20/40/50 s, so the hook can
#       never hang.
#     * The initramfs turned out to be a FULL Fedora one: beside awk/cat/
#       grep/ls/mount/sed/stat/tail/tr it HAS mkdir, dmesg, timeout,
#       sleep, cut, kill (builtin), ps -- the earlier 'no timeout/dd'
#       note was wrong (the earlier filter just did not look for them).
#   v8 changes (dbgC8, 2026-11-14; the SCAN-BASED dump -- nothing else):
#     * RUN 3 (dbgC7, 'linux usb') PINPOINTED the v6/v7 stall: the log is
#         RPT-S0 enter -> RPT-S1 mkdir rc=0 -> RPT-S1 mount rc=0 ->
#         RPT-S2 globbing platform devices @23.394604 -> (nothing; only
#         heartbeats to 60 s)
#       i.e. debugfs mounts fine and the hang is in the RESOLVE chain
#       (glob `*eusb2*` / [ -e ] on the platform-device symlink / cd -P /
#       pwd -P / stat).  The v5 chain itself was again perfect
#       (ESCALATE @7 s, rc=0 x3, TREE[NO-SCAN-FULL] @23 s, scan-events=0)
#       -- beta-2 for the third time.
#     * v8 removes the whole resolve chain (never a hard-coded path
#       either): it LISTS /sys/kernel/debug/regmap/ (plain debugfs
#       readdir), intersects it with /sys/bus/spmi/devices/ (the PMIC
#       regmaps; spmi.c:67 "%d-%02x"), and reads the fd00 window of every
#       candidate, identifying the repeater by its own signature:
#       fd08 = RPTR_OK (0x80) and fd46 = RPTR_EN (0x80).  Candidates are
#       printed (RPT-S2), each read is bounded by `timeout 55` + a kill
#       watchdog and summarised by one RPT-SCAN line (lines/WRN/KEY), so
#       a non-repeater map costs one cheap empty read and the answer is
#       still visible even if the signature does not match (RPT-NOHIT).
#     * Every external command in the dump is under timeout(1) (ls 5 s,
#       stat implicit, read 55 s): the hook can no longer hang in here.
#
# Everything else is v5 (which in turn is v4, = v3 = v2 + the one-shot
# device-tree dump): the dracut-initqueue lifetime contract (sourced
# every ~0.5 s: idempotent via pidfile AND done-marker, no top-level
# exit, no set -e/-u, _ac_-prefixed variables, sequence in a background
# subshell), the normal-boot gate (act only if the live FDT has
# dr_mode="host", which ABL injects only in `linux usb` mode; patch 1400
# ignores the value but leaves the property in the FDT), the
# already-enumerated short-circuit, the forced-host xhci unbind (discard
# the pre-PDR scan), the PDR wait (<=30 s), the xhci wait (<=15 s), the
# PARTNER gate (port0-partner <=20 s -- "the PPM sees the stick" marker,
# CONNECTED + partner UFP; NOT a VBUS marker: run 5 measured partner
# @3.88 s PRE-VBUS, "otg enable: 1" @5.436 s; the roles are even earlier;
# bounded WARN-nopartner on forced-host kernels where UCSI never
# registers a port; the real VBUS state is printed via _ac_vbus = the
# ULog "otg enable: 1" line), the USB-backed sd* disk detection (the
# internal UFS is sd* too),
# the -110 hard stop on a NEW "Host halt failed, -110" (baseline captured
# before the first unbind, checked inside every wait loop), the heartbeat
# (last step re-printed at most every 5 s), the xhci-only verdicts, no
# readlink -f (cd -P / pwd -P builtins), no lsusb (initramfs: fallback
# `ls /sys/bus/usb/devices/`), and the v3/v4 tree dump (t10 /
# WARN-nopdr / WARN-nopartner / NO-DEV / halt-110 / NO-SCAN / ESC /
# NO-XHCI-ESC / ESC-ABORT / NO-SCAN-FULL / OK / OK-FULL, with
# orientation=, partner=yes/no and the xhci -> usbN mapping) -- all via
# /dev/kmsg <0>, grep "ARMADA-C:".
#
# Firmware assumptions (NOT verifiable in the open sources; the PPM/ADSP
# side is closed): (a) the PPM-side UCSI/Type-C state (the stick is still
# CONNECTED, partner UFP) survives the UCSI driver unbind/rebind --
# ucsi_unregister (ucsi_glink.c:470-472) only stops the Linux-side
# read/write, the hardware/PPM is untouched, and the rebind's
# GET_CONNECTOR_STATUS re-queries the PPM; (b) the plug orientation and
# the SBU/repeater routing are correct (that is what the orientation dump
# line checks at runtime; "reverse" => flip the plug and re-run the SAME
# image).

_ac_pidfile=/tmp/armada-c.pid
_ac_done=/tmp/armada-c.done
_ac_seen=/tmp/armada-c.seen
_ac_state=/tmp/armada-c.state
_ac_hb=/tmp/armada-c.hb
_ac_dev=a600000.usb
_ac_dt=/sys/bus/platform/devices/$_ac_dev/of_node
_ac_xdrv=/sys/bus/platform/drivers/xhci-hcd
_ac_ddrv=/sys/bus/platform/drivers/dwc3-qcom
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

    # the REAL VBUS proxy: the lever-B ULog hook prints the PPM's
    # "otg enable: 1" line into kmsg (run 5: @5.436 s; the port0-partner
    # and the roles appear EARLIER, pre-VBUS -- run 5: partner @3.88 s)
    _ac_vbus() { dmesg 2>/dev/null | grep -q "otg enable: 1"; }

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

    # --- v5 run-5 fix: resolve the UCSI device AND its driver at runtime.
    # The hard-coded /sys/bus/auxiliary/drivers/pmic_glink_ucsi does NOT
    # exist in the running kernel (run 5: ESCALATE died on "No such file
    # or directory" at that path; ucsi_glink is built-in,
    # CONFIG_UCSI_PMIC_GLINK=y -- the built-kernel sysfs name evidently
    # differs from the source .name; ground truth = sysfs).  Device: glob
    # pmic_glink.ucsi.* on the auxiliary bus, fallback *ucsi* on ALL
    # buses.  Driver: the device's own `driver` symlink (cd -P / pwd -P,
    # no readlink -f).  Sets _ac_ucsi_d (device name) and _ac_ucsi_drv
    # (driver dir; empty = device absent or unbound).
    _ac_ucsi_resolve() {
      _ac_ucsi_d=""; _ac_ucsi_drv=""
      for _u in /sys/bus/auxiliary/devices/pmic_glink.ucsi.*; do
        [ -e "$_u" ] && { _ac_ucsi_d="${_u##*/}"; break; }; done
      if [ -z "$_ac_ucsi_d" ]; then
        for _u in /sys/bus/*/devices/*ucsi*; do
          [ -e "$_u" ] && { _ac_ucsi_d="${_u##*/}"; break; }; done
      fi
      if [ -n "$_ac_ucsi_d" ]; then
        for _p in /sys/bus/*/devices/"$_ac_ucsi_d"; do
          [ -e "$_p" ] || continue
          _ac_ucsi_drv=$( cd -P "$_p/driver" 2>/dev/null && pwd -P )
          [ -n "$_ac_ucsi_drv" ] && break
        done
      fi
    }

    # v4 gate: UCSI has registered the partner = the PPM sees the stick
    # (CONNECTED + partner UFP) -- that is what the full-chain re-query
    # needs.  NOT a VBUS marker: run 5 proved the partner appears
    # PRE-VBUS (@3.88 s vs "otg enable: 1" @5.436 s; like the roles, it
    # is set at port registration, ucsi.c:1944/1837).  The real VBUS
    # proxy is _ac_vbus (the ULog "otg enable: 1" line in kmsg).
    _ac_partner() { [ -e "$_ac_tc-partner" ]; }

    # v3/v4: device-tree snapshot -------------------------------------
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

    # ESCDIAG: the real UCSI/aux layout in the running kernel (run 5:
    # the hard-coded driver path was wrong -- print what sysfs actually
    # has, so the next photo answers it definitively)
    _ac_escdiag() {
      _ac_k "ESCDIAG aux-devs: [$(ls /sys/bus/auxiliary/devices/ 2>/dev/null | tr '\n' ' ')]"
      _ac_k "ESCDIAG aux-drvs: [$(ls /sys/bus/auxiliary/drivers/ 2>/dev/null | tr '\n' ' ')]"
      for _u in /sys/bus/*/devices/*ucsi*; do
        [ -e "$_u" ] || continue
        _dd=$( cd -P "$_u/driver" 2>/dev/null && pwd -P )
        _ac_k "ESCDIAG ucsi-cand ${_u##*/}: drv=${_dd:-UNBOUND}"
      done
    }

    # --- v4: the full-chain escalation (see the header for the code
    # provenance and WHY each order is what it is) ------------------------
    # v5: the UCSI driver is RESOLVED AT RUNTIME (_ac_ucsi_resolve) --
    # never the hard-coded sysfs path (run 5: it does not exist in the
    # built-in kernel).
    _ac_escalate() {
      _ac_ucsi_resolve
      _n=$(_ac_xhci)
      _dd=${_ac_ucsi_drv##*/}
      [ -n "$_ac_ucsi_drv" ] || _dd=NONE
      _ac_st "ESCALATE at $(_ac_now)s: full-chain reset (ucsi=${_ac_ucsi_d:-ABSENT} ucsi-drv=$_dd xhci=${_n:-ABSENT} dwc3=$_ac_dev vbus=$(_ac_vbus && echo out || echo pending))"
      _ac_k "ESCALATE: unbind order ucsi -> xhci -> dwc3, rebind order dwc3 -> ucsi (UCSI holds the role-switch ref: ucsi.c:1837)"
      _ac_tree ESC
      _ac_escdiag
      # unbind: UCSI first (safety: if it stays bound, dwc3 removal would
      # unregister the role switch under a live UCSI reference -- abort
      # instead of risking the UAF).  rc: 127 = no UCSI device at all,
      # 128 = device present but unbound (the full chain cannot complete
      # without a bindable UCSI -- its rebind is what re-runs
      # GET_CONNECTOR_STATUS -> set_role(HOST) -> xhci recreation).
      if [ -n "$_ac_ucsi_d" ] && [ -n "$_ac_ucsi_drv" ]; then
        echo "$_ac_ucsi_d" > "$_ac_ucsi_drv/unbind" 2>/dev/null; _r1=$?
      elif [ -n "$_ac_ucsi_d" ]; then
        _r1=128
      else
        _r1=127
      fi
      if [ "$_r1" -ne 0 ]; then
        _ac_tree ESC-ABORT
        _ac_st "FAIL-ESCALATE: ucsi unbind rc=$_r1 (ucsi=${_ac_ucsi_d:-ABSENT} drv=${_ac_ucsi_drv:-NONE}); dwc3 NOT touched (role-switch ref safety)"
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
      if [ -n "$_ac_ucsi_d" ]; then
        echo "$_ac_ucsi_d" > "$_ac_ucsi_drv/bind" 2>/dev/null; _r2=$?
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

    # --- v8: the eUSB2 repeater register dump, SCAN-BASED (see header).
    # Run 3 (dbgC7) proved the v6/v7 RESOLVE chain is what hangs: the log
    # ends at "RPT-S2: globbing platform devices" with mount rc=0, so the
    # stall is in glob/[ -e ]/cd -P/pwd -P/stat -- the platform-device
    # symlink walk.  v8 therefore drops that chain completely:
    #   * NO shell glob on /sys/bus/platform/devices/,
    #   * NO cd/pwd on a sysfs symlink,
    #   * NO [ -e ] on a device symlink,
    # and instead lists the debugfs regmap dirs (plain readdir of a
    # debugfs directory) and reads the fd00 window of every CANDIDATE,
    # identifying the repeater by its own signature (fd08 = RPTR_OK 0x80,
    # fd46 = RPTR_EN 0x80).  Candidates = regmap dirs whose name is also
    # an spmi bus device name (the PMIC regmaps; spmi.c:67 "%d-%02x"),
    # falling back to every regmap dir.  Every external step is bounded by
    # timeout(1), so nothing in here can hang the hook.
    #   RPT-S0:    enter (mode + uptime)
    #   RPT-S1:    debugfs check / mkdir / mount (rc of each)
    #   RPT-S2:    spmi list, regmap list, candidate list
    #   RPT-S3:    console quieted (dmesg -n 1) + SPMI timeout counter
    #   RPT-S4:    per-candidate read (started / progress / done)
    #   RPT-SCAN:  per-candidate one-liner (lines, WRN, KEY)
    #   RPT-S5:    console restored + SPMI timeout counter after
    #   RPT-DUMP:  the identified repeater regmap
    #   RPT-B:     the 92-register block, 8 per line
    #   RPT-KEY:   the 8 never-kernel-written tuning registers
    #   RPT-WRN:   the kernel-written / RO registers with expectations
    #   RPT-DONE / RPT-ABSENT / RPT-NOHIT / RPT-FAIL
    _ac_repdump() {
      _ac_k "RPT-S0: enter (mode=$(_ac_usbmode && echo linux-usb || echo normal)) at $(_ac_now)s"
      if ! _ac_usbmode; then
        _ac_k "RPT-S0: normal boot; waiting for a USB disk (<=45s) before the dump (boot not blocked)"
        _w=0
        while ! _ac_usbdisk > /dev/null && [ "$_w" -lt 90 ]; do
          sleep 0.5; _w=$((_w + 1))
        done
        if ! _ac_usbdisk > /dev/null; then
          _ac_k "RPT-NOTE: no USB disk in 45s; dumping the current state anyway"
        fi
      fi
      # 1) debugfs (not mounted by default in the initramfs)
      if grep -qs " debugfs " /proc/mounts 2>/dev/null; then
        _ac_k "RPT-S1: debugfs already mounted at $(_ac_now)s"
      else
        _ac_k "RPT-S1: mounting debugfs (mkdir first) at $(_ac_now)s"
        mkdir -p /sys/kernel/debug 2>/dev/null; _rc=$?
        _ac_k "RPT-S1: mkdir rc=$_rc at $(_ac_now)s"
        mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null; _rc=$?
        _ac_k "RPT-S1: mount rc=$_rc at $(_ac_now)s"
        grep -qs " debugfs " /proc/mounts 2>/dev/null || \
          _ac_k "RPT-S1: debugfs still NOT mounted (mount unavailable?)"
      fi
      # 2) candidates: debugfs regmap dirs x spmi bus device names
      _ac_k "RPT-S2: listing spmi + regmap at $(_ac_now)s"
      _spmi=$(timeout 5 ls /sys/bus/spmi/devices/ 2>/dev/null)
      _ac_k "RPT-S2: spmi=[$(printf '%s' "$_spmi" | tr '\n' ' ')] at $(_ac_now)s"
      _rdirs=$(timeout 5 ls /sys/kernel/debug/regmap/ 2>/dev/null)
      _ac_k "RPT-S2: regmap=[$(printf '%s' "$_rdirs" | tr '\n' ' ')] at $(_ac_now)s"
      if [ -z "$_rdirs" ]; then
        _ac_k "RPT-ABSENT: no regmap debugfs dirs (debugfs: [$(timeout 5 ls /sys/kernel/debug/ 2>/dev/null | tr '\n' ' ')])"
        return 0
      fi
      _cand=""
      for _d in $_rdirs; do
        for _s in $_spmi; do
          if [ "$_d" = "$_s" ]; then
            _cand="$_cand $_d"
            break
          fi
        done
      done
      if [ -z "$_cand" ]; then
        _cand="$_rdirs"
        _ac_k "RPT-S2: no spmi-name match; trying every regmap dir"
      fi
      _ac_k "RPT-S2: candidates=[${_cand# }] at $(_ac_now)s"
      # 3) quiet the console for the reads: every PMIC-sized map has 676
      # unimplemented registers above 0xfd5b, and each one prints a
      # spmi-pmic-arb 'timeout' dev_err (1 ms udelay + console cost)
      _front=$(sed -n '1p' /proc/sys/kernel/printk 2>/dev/null)
      _cons=${_front%% *}
      _ac_k "RPT-S3: console=${_cons:-?}; timeouts before=$(dmesg 2>/dev/null | grep -c pmic_arb_wait_for_done); suppressing to 1"
      dmesg -n 1 2>/dev/null
      _ac_k "RPT-S3: console now=$(sed -n '1p' /proc/sys/kernel/printk 2>/dev/null | cut -d' ' -f1)"
      # 4) read the fd00 window of every candidate, identify by signature
      # 9 B/line ("XXXX: XX\n"), 0xfd00 is line 582912 (0-based) ->
      # tail -c +582913 (1-based), 92 lines
      _hit=""
      _hblk=""
      for _d in $_cand; do
        _f="/sys/kernel/debug/regmap/$_d/registers"
        if [ ! -r "$_f" ]; then
          _ac_k "RPT-S4: $_d: no readable registers file"
          continue
        fi
        _t=/tmp/armada-rpt.txt
        : > "$_t" 2>/dev/null
        _ac_k "RPT-S4: $_d: read started (bounded 55s) at $(_ac_now)s"
        timeout 55 tail -c +582913 "$_f" 2>/dev/null | \
          sed -n '1,92p' > "$_t" 2>/dev/null &
        _brp=$!
        _w=0
        while kill -0 "$_brp" 2>/dev/null && [ "$_w" -lt 100 ]; do
          sleep 0.5; _w=$((_w + 1))
          case $_w in
            10|20|40|80|100)
              _ac_k "RPT-S4: $_d: t=$((_w / 2))s size=$(stat -c %s "$_t" 2>/dev/null)" ;;
          esac
        done
        if kill -0 "$_brp" 2>/dev/null; then
          # timeout(55) kills tail; sed then flushes and exits.  A single
          # big read() means "nothing" in the worst case -- but the hook
          # must never hang, so give it 5 s and move on.
          _g=0
          while kill -0 "$_brp" 2>/dev/null && [ "$_g" -lt 10 ]; do
            sleep 0.5; _g=$((_g + 1))
          done
          kill -9 "$_brp" 2>/dev/null
          _ac_k "RPT-SLOW: $_d: still running after 50s (size=$(stat -c %s "$_t" 2>/dev/null)); killed"
        fi
        _tb=$(stat -c %s "$_t" 2>/dev/null)
        _ac_k "RPT-S5: $_d: read done size=${_tb:-?} at $(_ac_now)s"
        if [ ! -s "$_t" ]; then
          _ac_k "RPT-SCAN: $_d empty (window beyond this map, or the read failed)"
          continue
        fi
        _i=0
        _line=""
        _blk=""
        _key=""
        _wrn=""
        while read -r _l; do
          [ -n "$_l" ] || continue
          _reg=${_l%%:*}
          _val=${_l#*: }
          _i=$((_i + 1))
          _line="${_line} ${_reg}=${_val}"
          if [ $((_i % 8)) -eq 0 ]; then
            _blk="${_blk}${_line# }|"
            _line=""
          fi
          case $_reg in
            fd50|fd52|fd55|fd56|fd58|fd59|fd5a|fd5b)
              _key="${_key} ${_reg#fd}=$_val" ;;
            fd08|fd46|fd51|fd53|fd54|fd57)
              _wrn="${_wrn} ${_reg#fd}=$_val" ;;
          esac
        done < "$_t"
        [ -n "$_line" ] && _blk="${_blk}${_line# }|"
        _ac_k "RPT-SCAN: $_d lines=$_i WRN:${_wrn} KEY:${_key}"
        case $_wrn in
          *" 08=80 46=80 "*)
            _hit=$_d; _hblk=$_blk; _hkey=$_key; _hwrn=$_wrn ;;
        esac
        [ -n "$_hit" ] && break
      done
      dmesg -n "${_cons:-7}" 2>/dev/null
      _ac_k "RPT-S5: console restored to ${_cons:-7}; timeouts after=$(dmesg 2>/dev/null | grep -c pmic_arb_wait_for_done) at $(_ac_now)s"
      if [ -z "$_hit" ]; then
        _ac_k "RPT-NOHIT: no candidate showed fd08=80/fd46=80 (see the RPT-SCAN lines)"
        return 0
      fi
      _ac_k "RPT-DUMP: repeater regmap=$_hit (92 regs fd00-fd5b, 9 B/line, offset 582912)"
      _ac_oifs=$IFS
      IFS='|'
      for _l in $_hblk; do
        [ -n "$_l" ] && _ac_k "RPT-B: $_l"
      done
      IFS=$_ac_oifs
      _ac_k "RPT-KEY (never kernel-written; residue candidates): ${_hkey# }"
      # host-mode expectations: 08 = RPTR_OK status, 46 = RPTR_EN,
      # 51/53/57 from the DT (qcs8550-ayn-common.dtsi: 0b/06/03), 54 from
      # the pm8550b init table (03); fde8/fded (the set_mode force regs)
      # are outside the window and always kernel-overwritten
      _ac_k "RPT-WRN (expect 08=80 46=80 51=0b 53=06 54=03 57=03): ${_hwrn# }"
      _ac_k "RPT-DONE: dump complete at $(_ac_now)s"
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
      # 4) v4 GATE: wait for port0-partner (<=20 s) -- "the PPM sees the
      #    stick" marker (CONNECTED + partner UFP).  v5 relabel: NOT a
      #    VBUS marker (run 5: partner @3.88 s, PRE-VBUS; "otg enable: 1"
      #    @5.436 s -- the partner, like the roles, is set at port
      #    registration).  The VBUS state is printed via _ac_vbus.
      _w=0
      while ! _ac_partner && [ "$_w" -lt 40 ]; do
        _ac_maybedump
        sleep 0.5; _w=$((_w + 1))
      done
      _ac_pr=$(cat "$_ac_tc/power_role" 2>/dev/null)
      _ac_dr=$(cat "$_ac_tc/data_role" 2>/dev/null)
      if _ac_partner; then
        _ac_st "partner at $(_ac_now)s (port0-partner; power='$_ac_pr' data='$_ac_dr'; vbus=$(_ac_vbus && echo out || echo pending))"
      else
        _ac_tree WARN-nopartner
        _ac_st "WARN: no port0-partner in 20 s (power='$_ac_pr' data='$_ac_dr'); continuing (bounded)"
      fi
      # 5) v5 EARLY ESCALATION: the first post-flip scan gets a short
      #    bounded window (3 s) to produce the disk (the working
      #    full-system scan lands ~0.3 s after the role flip; 3 s is
      #    generous).  Run 4 proved the v4 3-try xhci rebind loop useless
      #    (scan-events=0 x3, two post-VBUS) and its late escalation
      #    (~36-38 s start, ~39 s fresh scan) falls OUTSIDE the ~30 s PPM
      #    window (all replug successes <=24.7 s, all failures >=38 s).
      #    No disk in 3 s -> escalate NOW (~8-10 s total); a new -110
      #    stops immediately (no retry, known qmp-combo defect).
      if [ -n "$_n" ]; then
        if _ac_wait_disk 6; then
          _sd=$(_ac_usbdisk | tr '\n' ' ')
          _ac_st "ENUMERATION OK (first post-PDR scan) at $(_ac_now)s: $_sd (scan-events=$(_ac_nev))"
          _ac_tree OK
          return 0
        fi
        if [ "$(_ac_110)" -gt "$_c110a" ]; then
          _ac_tree halt-110
          _ac_st "FAIL: Host halt -110 after the first post-flip scan at $(_ac_now)s; no retry"
          return 0
        fi
        _ac_tree NO-SCAN
        _ac_st "FAIL-NO-SCAN: no USB disk after the first post-flip scan (last up=$(_ac_now)s, scan-events=$(_ac_nev)); escalating to the full chain"
      else
        _ac_tree NO-DEV
        _ac_st "FAIL-NO-DEV: xhci-hcd never appeared after PDR (last up=$(_ac_now)s); escalating to the full chain"
      fi
      # 6) the full-chain escalation (UCSI -> xhci -> dwc3 unbind,
      #    dwc3 -> UCSI rebind; the chain then completes itself).  Only
      #    the NO-SCAN / NO-DEV branches reach here; the -110 path
      #    returned above (a retry cannot recover that defect).
      _ac_escalate
      return 0
    }

    _ac_dumped=0
    _ac_run
    _ac_repdump
    : > "$_ac_done" 2>/dev/null
  ) &
  echo $! > "$_ac_pidfile" 2>/dev/null
fi
