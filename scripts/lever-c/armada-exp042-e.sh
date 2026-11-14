#!/bin/sh
# ARMADA-E (EXP-042, 2026-11-14): READ-ONLY capture of the eUSB2 data-path
# state in the failing `linux usb` pre-plug boot, diffed against the working
# baseline.  Sits in the 91 initqueue slot (REPLACES the lever-C hook in this
# image): the lever-C chain work is DELETED because it would perturb exactly
# the state EXP-042 must measure untouched -- the ABL handoff state of the
# data path (H2: ULOG_DIFF_DATA_PATH.md).
#
# What this hook does (and ONLY does):
#   1. gates on `linux usb` mode (dr_mode on the live FDT; ABL injects it
#      only in that mode -- the proven c8 gate); a normal boot is left
#      completely alone (safe recovery boot with this image);
#   2. at up=15/30/60 s (the settled broken state of the failing boot:
#      PDR ~3.5 s, xhci ~3.9 s, VBUS ~5.4 s, no enumeration ever) it
#      captures:
#        * data-path context (block devices, new sd* vs the t0 UFS set,
#          USB device list, typec port0/partner, usb_role, runtime_status,
#          xHCI port-event counts),
#        * the repeater summary lines (ACT = the 7 activity registers
#          fd00 fd02 fd04 fd05 fd09 fd0a fd42; WRN = the 6 kernel-written
#          fd08 fd46 fd51 fd53 fd54 fd57; KEY = the 8 never-kernel-written
#          fd50 fd52 fd55 fd56 fd58 fd59 fd5a fd5b),
#        * the FULL SPMI 0-07 (repeater PMIC) regmap window diffed against
#          the shipped working baseline (/etc/armada/
#          exp042-baseline-0-07.regmap, 65536 lines; captured 2026-11-14 in
#          the working full-system dock+PD boot -- the same topology as
#          this run), printing every differing register (members of the
#          volatile set marked V; the 8 self-drifting registers 260f 28eb
#          28ee 3ae2 3ae4 4f90 4fa0 4fc0, from the same-boot self-diff of
#          the working mode, are counted separately),
#   3. the 15 s capture prints the full differing-register list (capped
#      100); the 30/60 s captures print the summary + the non-volatile
#      address list (capped 60) -- drift between the three captures is
#      visible as a changing non-volatile set.
#
# The fix target (per ULOG_DIFF_DATA_PATH.md): the register that is set in
# the working baseline and clear here, outside the volatile set and outside
# the 7 activity registers (which are EXPECTED 00 in this mode -- they are
# the "link never reached the repeater" confirmation, not the routing
# switch).
#
# Safety (the hook must never hang the boot or change any state):
#   * every read is bounded: debugfs mount under timeout 5, the candidate
#     fd00-window reads under timeout 55, the full-window read under
#     timeout 55, every ls under timeout 5; a failed or partial read is
#     reported (E042-READFAIL) and the next capture retries from scratch;
#   * the console is quieted (printk level 1) only for the duration of each
#     full-window read and restored afterwards (the NAKed registers among
#     the 50688 unimplemented SPMI slots print dev_err lines);
#   * the regmap is identified by the v8 SCAN (debugfs regmap dirs
#     intersected with /sys/bus/spmi/devices/, signature fd08=80/fd46=80
#     read from the fd00 window) -- never a hard-coded path;
#   * no platform-device symlink resolution (the v6/v7 hang), no USB state
#     change of any kind, no register writes: the SPMI window is read via
#     the debugfs regmap file only;
#   * dracut-initqueue lifetime contract: sourced every ~0.5 s, idempotent
#     via pidfile + done-marker, _ae_-prefixed variables, sequence in a
#     background subshell, no top-level exit, no set -e/-u;
#   * output is /dev/kmsg at <0> ("ARMADA-E:" prefix) so it survives the CI
#     kernel's quiet cmdline; ~60-90 lines total (photo-OCR oriented).
#
# The lever-B hook (90 initqueue slot) is untouched and still prints the
# PPM ULog lines to kmsg; "otg enable: 1" (the VBUS proxy) is grepped from
# there for the timeline anchors.

_ae_pidfile=/tmp/armada-e.pid
_ae_done=/tmp/armada-e.done
_ae_seen=/tmp/armada-e.seen
_ae_state=/tmp/armada-e.state
_ae_hb=/tmp/armada-e.hb
_ae_dev=a600000.usb
_ae_dt=/sys/bus/platform/devices/$_ae_dev/of_node
_ae_tc=/sys/class/typec/port0
_ae_base=/etc/armada/exp042-baseline-0-07.regmap
# self-drifting registers (same working boot, ~8 min apart; counters/status)
_ae_vol="260f 28eb 28ee 3ae2 3ae4 4f90 4fa0 4fc0"

_ae_k() { echo "<0>ARMADA-E: $*" > /dev/kmsg 2>/dev/null; }
_ae_now() { cut -d. -f1 /proc/uptime 2>/dev/null; }

# current step text (kept for the heartbeat)
_ae_st() {
  printf '%s' "$*" > "$_ae_state" 2>/dev/null
  _ae_k "$*"
}

# --- heartbeat: re-print the last step at most every 5 s -----------------
if [ -f "$_ae_state" ]; then
  _ae_n=$(_ae_now)
  _ae_l=$(cat "$_ae_hb" 2>/dev/null)
  if [ -z "$_ae_l" ] || [ "$((_ae_n - _ae_l))" -ge 5 ] 2>/dev/null; then
    _ae_k "hb up=${_ae_n}s :: $(cat "$_ae_state" 2>/dev/null)"
    printf '%s' "$_ae_n" > "$_ae_hb" 2>/dev/null
  fi
fi

# --- first sourcing: prove the hook is alive, whatever happens next ------
if [ ! -f "$_ae_seen" ]; then
  : > "$_ae_seen" 2>/dev/null
  _ae_k "hook loaded up=$(_ae_now)s (EXP-042 read-only capture; no chain work)"
fi

# --- guards: run the sequence exactly once -------------------------------
_ae_running=0
[ -f "$_ae_done" ] && _ae_running=1
if [ "$_ae_running" -eq 0 ] && [ -f "$_ae_pidfile" ]; then
  _ae_pid=$(cat "$_ae_pidfile" 2>/dev/null)
  if [ -n "$_ae_pid" ] && [ -d "/proc/$_ae_pid" ]; then
    _ae_running=1
  fi
fi

if [ "$_ae_running" -eq 0 ]; then
  (
    _ae_pdr() { dmesg 2>/dev/null | grep -q "PDR: Indication received from msm/adsp/charger_pd"; }

    # the REAL VBUS proxy: the lever-B hook prints the PPM's "otg enable: 1"
    # line into kmsg (EXP-037: @5.436 s)
    _ae_vbus() { dmesg 2>/dev/null | grep -q "otg enable: 1"; }

    # xhci-hcd platform device of our controller (child of a600000.usb);
    # the narrow glob (2 entries at most) is the proven c8 form -- it is
    # NOT the v6/v7 all-platform-devices glob that hung
    _ae_xhci() {
      for _x in /sys/bus/platform/devices/$_ae_dev/xhci-hcd.*; do
        [ -e "$_x" ] && { echo "${_x##*/}"; return 0; }; done
      return 1
    }

    _ae_partner() { [ -e "$_ae_tc-partner" ]; }

    # whole-disk sd* names from /proc/partitions (no sysfs resolution:
    # the cd -P/pwd -P chain costs ~2 s per LUN in this boot, v4 lesson)
    _ae_sddisks() { awk '$2 ~ /^sd[a-z]$/ {print $2}' /proc/partitions 2>/dev/null | tr '\n' ' '; }

    # new whole-disk sd* since t0 (= a USB disk appeared, if any)
    _ae_newsd() {
      _ae_out=""
      for _d in $(_ae_sddisks); do
        case " $_ae_t0sd " in
          *" $_d "*) ;;
          *) _ae_out="$_ae_out $_d" ;;
        esac
      done
      printf '%s' "${_ae_out# }"
    }

    # --- regmap resolution (the proven v8 scan; never a hard-coded path) --
    _ae_rmap=""
    _ae_resolve() {
      [ -n "$_ae_rmap" ] && return 0
      grep -qs " debugfs " /proc/mounts || {
        mkdir -p /sys/kernel/debug 2>/dev/null
        timeout 5 mount -t debugfs none /sys/kernel/debug 2>/dev/null || {
          _ae_k "DBGFS-FAIL: debugfs mount failed"; return 1; }
      }
      _cand=""
      for _r in $(timeout 5 ls /sys/kernel/debug/regmap/ 2>/dev/null); do
        for _s in /sys/bus/spmi/devices/$_r; do
          [ -d "$_s" ] && { _cand="$_cand $_r"; break; }
        done
      done
      [ -n "$_cand" ] || _cand=" $(timeout 5 ls /sys/kernel/debug/regmap/ 2>/dev/null)"
      _ae_k "E042-SCAN: candidates=[${_cand# }] up=$(_ae_now)s"
      for _d in ${_cand# }; do
        _f="/sys/kernel/debug/regmap/$_d/registers"
        [ -r "$_f" ] || continue
        _t=/tmp/ae-win.txt
        # 9 B/line ("XXXX: XX\n"), 0xfd00 is byte offset 0xfd00*9 ->
        # tail -c +582913 (1-based), 92 lines (fd00-fd5b)
        timeout 55 tail -c +582913 "$_f" 2>/dev/null | sed -n '1,92p' > "$_t" 2>/dev/null
        _w8=""; _w46=""
        while IFS= read -r _l; do
          case $_l in
            fd08:*) _w8=${_l#*: } ;;
            fd46:*) _w46=${_l#*: } ;;
          esac
        done < "$_t"
        _ae_k "E042-SCAN: $_d fd08=${_w8:-?} fd46=${_w46:-?}"
        if [ "$_w8" = "80" ] && [ "$_w46" = "80" ]; then
          _ae_rmap=$_f
          break
        fi
      done
      if [ -n "$_ae_rmap" ]; then
        _ae_k "E042-SCAN: repeater PMIC regmap=$_ae_rmap"
        return 0
      fi
      _ae_k "E042-NOHIT: no spmi regmap showed fd08=80/fd46=80"
      return 1
    }

    # --- one capture: context + repeater summary + full-window diff ------
    # $1 = full (print the differing-register list) | compact (summary only)
    _ae_capture() {
      _mode=$1
      _t=$(_ae_now)
      _ns=$(_ae_newsd)
      _ae_k "E042-CTX t=${_t}s block=[$(_ae_sddisks)] newsd=[${_ns}] usbdevs=[$(timeout 5 ls /sys/bus/usb/devices 2>/dev/null | tr '\n' ' ')]"
      _o=$(cat "$_ae_tc/orientation" 2>/dev/null)
      _pr=$(cat "$_ae_tc/power_role" 2>/dev/null)
      _dr=$(cat "$_ae_tc/data_role" 2>/dev/null)
      _pm=$(cat "$_ae_tc/power_operation_mode" 2>/dev/null)
      _pt=$(_ae_partner && echo yes || echo no)
      _pd=$(cat "$_ae_tc-partner/supports_usb_power_delivery" 2>/dev/null)
      _ae_k "E042-CTX typec o=[$_o] p=[$_pr] d=[$_dr] op=[$_pm] partner=$_pt pd=[${_pd:-?}]"
      _rl=""
      for _r in /sys/class/usb_role/*/role; do
        [ -e "$_r" ] || continue
        _rl="$_rl $(cat "$_r" 2>/dev/null)"
      done
      _ra=$(cat /sys/devices/platform/soc@0/$_ae_dev/power/runtime_status 2>/dev/null)
      _rx=$(cat /sys/devices/platform/soc@0/$_ae_dev/xhci-hcd.*/power/runtime_status 2>/dev/null | head -1)
      _pc=$(dmesg 2>/dev/null | grep -c "Port change event")
      _ne=$(dmesg 2>/dev/null | grep -c "new .*-speed USB device")
      _ae_k "E042-CTX role=[$_rl] runtime a600000.usb=[${_ra:-?}] xhci=[${_rx:-?}] portchg=$_pc newspeeddevs=$_ne"
      if [ -n "$_ns" ]; then
        # a USB disk APPEARED: one bounded resolution per new disk to
        # confirm the bus (the ~2 s/cd -P cost is acceptable here -- it
        # only runs when enumeration happened, which is the good-news case)
        for _d in $_ns; do
          _p=$(timeout 10 sh -c "cd -P /sys/block/$_d 2>/dev/null && pwd -P")
          case "$_p" in
            *usb*) _ae_k "E042-NEWSD $_d -> $_p (ENUMERATION HAPPENED)" ;;
            *) _ae_k "E042-NEWSD $_d -> ${_p:-?} (not usb-backed)" ;;
          esac
        done
      fi
      [ -n "$_ae_rmap" ] || _ae_resolve
      if [ -z "$_ae_rmap" ]; then
        _ae_k "E042-NOREGMAP t=${_t}s: no readable repeater regmap (context above stands)"
        return 1
      fi
      # quiet the console for the read (v7 pattern): restore after
      _front=$(sed -n '1p' /proc/sys/kernel/printk 2>/dev/null)
      _cons=${_front%% *}
      dmesg -n 1 2>/dev/null
      _f=/tmp/ae-full.txt
      timeout 55 cat "$_ae_rmap" > "$_f" 2>/dev/null
      _rc=$?
      dmesg -n "${_cons:-7}" 2>/dev/null
      _nl=$(awk 'END {print NR}' "$_f" 2>/dev/null)
      if [ "$_rc" -ne 0 ] || [ "$_nl" != "65536" ]; then
        _ae_k "E042-READFAIL t=${_t}s: rc=$_rc lines=${_nl:-?} (expected 65536); retry at next capture"
        _ae_rmap=""   # force re-resolve at the next capture
        return 1
      fi
      # repeater summary lines (one awk pass over the window file)
      awk '
        BEGIN {
          split("fd00 fd02 fd04 fd05 fd09 fd0a fd42", A, " ")
          for (i = 1; i <= 7; i++) act[A[i]] = 1
          split("fd08 fd46 fd51 fd53 fd54 fd57", W, " ")
          for (i = 1; i <= 6; i++) wrn[W[i]] = 1
          split("fd50 fd52 fd55 fd56 fd58 fd59 fd5a fd5b", K, " ")
          for (i = 1; i <= 8; i++) key[K[i]] = 1
        }
        {
          r = substr($1, 1, 4)
          v = $2
          if (r in act) a = a " " r "=" v
          else if (r in wrn) w = w " " r "=" v
          else if (r in key) k = k " " r "=" v
        }
        END {
          print "E042-ACT" a
          print "E042-WRN" w
          print "E042-KEY" k
        }
      ' "$_f" > /tmp/ae-rpt.txt 2>/dev/null
      while IFS= read -r _l; do _ae_k "$_l"; done < /tmp/ae-rpt.txt
      # the diff against the working baseline
      if [ -r "$_ae_base" ]; then
        _bnl=$(awk 'END {print NR}' "$_ae_base" 2>/dev/null)
        if [ "$_bnl" = "65536" ]; then
          awk -v mode="$_mode" -v cap=100 -v tstamp="$_t" -v volset="$_ae_vol" '
            BEGIN {
              n = split(volset, _v, " ")
              for (i = 1; i <= n; i++) vol[_v[i]] = 1
            }
            NR == FNR { b[FNR] = $0; next }
            {
              if (b[FNR] != $0) {
                reg = substr($0, 1, 4)
                bv = b[FNR]; cv = $0
                sub(/^[0-9a-f][0-9a-f][0-9a-f][0-9a-f]: /, "", bv)
                sub(/^[0-9a-f][0-9a-f][0-9a-f][0-9a-f]: /, "", cv)
                tot++
                if (reg in vol) { vc++; vlist = vlist " " reg }
                else { nv++; if (nv <= 60) nvlist = nvlist " " reg }
                if (mode == "full" && tot <= cap)
                  printf "E042-DIFF 0x%s base=%s cur=%s%s\n", reg, bv, cv, (reg in vol ? " V" : "")
              }
            }
            END {
              printf "E042-SUM t=%s total=%d volatile=%d nonvolatile=%d\n", tstamp, tot+0, vc+0, nv+0
              if (nv+0 > 0)
                printf "E042-NONVOL%s:%s\n", (nv+0 > 60 ? "(capped)" : ""), nvlist
              else
                printf "E042-NONVOL: (none beyond the volatile set)\n"
            }
          ' "$_ae_base" "$_f" > /tmp/ae-diff.txt 2>/dev/null
          while IFS= read -r _l; do _ae_k "$_l"; done < /tmp/ae-diff.txt
        else
          _ae_k "E042-BASEBAD: baseline has ${_bnl:-?} lines (expected 65536)"
        fi
      else
        _ae_k "E042-NOBASE: $_ae_base not readable"
      fi
      rm -f /tmp/ae-full.txt /tmp/ae-win.txt /tmp/ae-rpt.txt /tmp/ae-diff.txt 2>/dev/null
      _ae_k "E042-CAP-DONE t=${_t}s mode=$_mode"
      return 0
    }

    # wait until up >= $1 s (hard stop: 100 s), then print the anchors
    _ae_wait() {
      _tgt=$1
      _i=0
      while :; do
        _w=$(_ae_now)
        [ "$_w" -ge "$_tgt" ] 2>/dev/null && break
        _i=$((_i + 1))
        [ "$_i" -ge 200 ] && { _ae_k "E042-WARN: wait ${_tgt}s gave up (up=${_w:-?})"; break; }
        sleep 0.5
      done
      _p=$(_ae_pdr && echo yes || echo no)
      _v=$(_ae_vbus && echo yes || echo no)
      _x=$(_ae_xhci)
      _pt=$(_ae_partner && echo yes || echo no)
      _ae_k "E042-T t=${_w}s: pdr=$_p vbus=$_v xhci=[${_x:-absent}] partner=$_pt"
    }

    _ae_run() {
      # 0) mode gate (the proven c8 gate: ABL injects dr_mode into the
      #    live FDT only in `linux usb` mode; patch 1400 ignores the
      #    value but leaves the property in the tree)
      if [ ! -e "$_ae_dt/dr_mode" ]; then
        _ae_st "not linux-usb mode (no dr_mode on $_ae_dev) at $(_ae_now)s; no capture; boot left alone"
        return 0
      fi
      _m=$(tr -d '\000' < "$_ae_dt/dr_mode" 2>/dev/null)
      _ae_st "linux-usb mode (dr_mode='$_m') at $(_ae_now)s; EXP-042 capture armed (read-only)"
      # 0b) baseline sanity (it is shipped in the image; fail soft)
      _bnl=$(awk 'END {print NR}' "$_ae_base" 2>/dev/null)
      if [ "$_bnl" != "65536" ]; then
        _ae_k "BASE-WARN: baseline has ${_bnl:-?} lines (expected 65536); the diff will say so"
      fi
      # 1) t0: the UFS whole-disk set (a new sd* later = a USB disk)
      _ae_t0sd=$(_ae_sddisks)
      _ae_k "E042-T0 up=$(_ae_now)s block-sd=[${_ae_t0sd}] (UFS set at subshell start)"
      # 2) the capture schedule: 15/30/60 s (the settled broken state)
      _ae_wait 15
      _ae_capture full
      _ae_wait 30
      _ae_capture compact
      _ae_wait 60
      _ae_capture compact
      _ae_k "E042-DONE: all captures complete at up=$(_ae_now)s"
    }

    _ae_run
    : > "$_ae_done" 2>/dev/null
  ) &
  echo $! > "$_ae_pidfile" 2>/dev/null
fi
