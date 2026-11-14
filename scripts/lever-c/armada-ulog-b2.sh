#!/bin/sh
# ARMADA-B (lightweight lever B): capture the FAILING-side PPM ULog +
# usb_type state to the console. The screen is the only sink in the
# pre-plug failing env (the stick never enumerates there).
#
# LIFETIME: this file is SOURCED by dracut-initqueue (`job=$job . "$job"`)
# on EVERY initqueue main-loop iteration (~0.5 s). Therefore:
#   - idempotent: a pidfile guard starts the capture loop exactly once;
#   - NEVER `exit` (would kill dracut-initqueue); no `set -e/-u`
#     (options would leak into the caller); variables prefixed _ab_.
#
# OUTPUT (all via /dev/kmsg <0> so they print despite console=tty0 quiet):
#   ARMADA-B ULOG: <fn>: <msg>  new PPM ULog lines matching the
#                               charger-detection key patterns (deduped)
#   ARMADA-B USB:  <state>      every change of usb_type/online/roles/partner
#   ARMADA-B status ...         liveness heartbeat every ~16 s
#
# Decision-rule use (docs/INITRAMFS_CHANGES.md):
#   no PartnerType= line at all           -> FAIL-NO-DETECTION
#   PartnerType= seen but usb_type!=SDP   -> FAIL-NO-CLASSIFY
#   PartnerType=2 + usb_type=SDP          -> PASS
#
# TIMING: pmic_pdcharger_ulog polls the ADSP 8 KB ULog drain buffer once a
# second; the first GET returns everything since channel open, so the
# detection burst (~PDR+5..8 s) is caught even though this starts at
# initqueue (~4 s). ncp_stby / sm_state_loop lines repeat, so the stuck
# state is catchable regardless. Cap: 450 iters x 2 s = 15 min.
#
# v2 (dbgC2, 2026-11-12): the dbgC run printed
#   90-armada-ulog-b.sh: line 82: read: 0: read error: Resource temporarily
#   unavailable
# on the console/dmesg tail.  Cause (code): qcom_battmgr's
# qcom_battmgr_usb_get_property() returns -EAGAIN while !service_up
# (drivers/power/supply/qcom_battmgr.c:1006-1007; service_up is set only
# after the ADSP/BattMngr service is up, i.e. ~PDR @3.5 s), and this hook
# starts polling qcom-battmgr-usb/* in initqueue (~2.7-4 s), i.e. before
# that.  The value already falls back to '?' via `|| _ab_v='?'`; the only
# harm was the shell error line.  Fix: suppress the read's stderr
# (line 82: `2>/dev/null`), nothing else changes.

_ab_pidfile=/tmp/armada-b.pid
_ab_seen=/tmp/armada-b.seen
_ab_T=/sys/kernel/tracing
_ab_E="$_ab_T/events/pmic_pdcharger_ulog/pmic_pdcharger_ulog_msg"
_ab_INC='PartnerType|charger_detection|sm_state_loop|ncp_stby|ICM run state|typec_detect_partner|chg_cable_state|check_state_change|wlstx_otg|bLpdEn|BattMngrStateMachine_Main|ChgIcmCfg'
_ab_EXC='QBG_R1_Calculate|battman_adc_read|GetBatteryTemperature|validate_and_load_sdam|battman_pmio_spmi|Get_TimeToFull|Get_IBatt'

_ab_running=0
if [ -f "$_ab_pidfile" ]; then
  _ab_pid=$(cat "$_ab_pidfile" 2>/dev/null)
  if [ -n "$_ab_pid" ] && [ -d "/proc/$_ab_pid" ]; then
    _ab_running=1
  fi
fi

if [ "$_ab_running" -eq 0 ]; then
  # tracefs (idempotent mount)
  grep -qs " /sys/kernel/tracing tracefs" /proc/mounts 2>/dev/null || \
    mount -t tracefs tracefs "$_ab_T" 2>/dev/null
  # PPM ULog reader: no deps; binds PMIC_LOGS_ADSP_APPS when ADSP announces it
  modprobe pmic_pdcharger_ulog 2>/dev/null || \
    insmod "/usr/lib/modules/$(uname -r)/kernel/drivers/soc/qcom/pmic_pdcharger_ulog.ko" 2>/dev/null

  (
    : > "$_ab_seen"
    # wait for the tracepoint dir (appears once the module is loaded)
    _w=0
    while [ ! -d "$_ab_E" ] && [ "$_w" -lt 120 ]; do sleep 0.5; _w=$((_w + 1)); done
    _ulog_ok=0
    if [ -d "$_ab_E" ]; then
      echo 1 > "$_ab_E/enable" 2>/dev/null
      # glink transport view of the same channel (request/response timing)
      _g="$_ab_T/events/qcom_glink/qcom_glink_cmd_tx_data"
      if [ -d "$_g" ]; then
        echo 1 > "$_g/enable" 2>/dev/null
        echo 'channel ~ "PMIC_LOGS*"' > "$_g/filter" 2>/dev/null
      fi
      echo 4096 > "$_ab_T/buffer_size_kb" 2>/dev/null
      echo > "$_ab_T/trace" 2>/dev/null
      echo 1 > "$_ab_T/tracing_on" 2>/dev/null
      _ulog_ok=1
      echo "<0>ARMADA-B: ULog capture ON (pmic_pdcharger_ulog tracepoint)" > /dev/kmsg 2>/dev/null
    else
      echo "<0>ARMADA-B: WARN ULog tracepoint missing; usb_type poller only" > /dev/kmsg 2>/dev/null
    fi

    _ab_ps=/sys/class/power_supply
    _ab_b="$_ab_ps/qcom-battmgr-usb"
    _ab_s="$_ab_ps/ucsi-source-psy-pmic_glink.ucsi.01"
    _ab_tc=/sys/class/typec/port0
    _ab_get() {
      _ab_v='?'
      [ -r "$1" ] || return 0
      IFS= read -r _ab_v < "$1" 2>/dev/null || _ab_v='?'
    }

    _n=0
    _ulog_n=0
    _prev=
    while [ "$_n" -lt 450 ]; do
      _n=$((_n + 1))
      # (a) new PPM ULog key lines (reading /trace clears the buffer)
      if [ "$_ulog_ok" -eq 1 ]; then
        grep -aE "$_ab_INC" "$_ab_T/trace" 2>/dev/null \
          | grep -avE "$_ab_EXC" 2>/dev/null \
          | sed -E 's/.*pmic_pdcharger_ulog_msg: 0x[0-9a-fA-F]+: [A-Za-z]+: //' \
          | while IFS= read -r _m; do
              [ -n "$_m" ] || continue
              case "$_m" in *pmic_pdcharger_ulog_msg*) continue ;; esac
              if ! grep -Fxq "$_m" "$_ab_seen" 2>/dev/null; then
                printf '%s\n' "$_m" >> "$_ab_seen"
                echo "<0>ARMADA-B ULOG: $_m" > /dev/kmsg 2>/dev/null
              fi
            done
        _ulog_n=$(( $(grep -ac . "$_ab_seen" 2>/dev/null) ))
      fi
      # (b) usb_type / typec / partner change
      _ab_get "$_ab_b/usb_type";    _bt=$_ab_v
      _ab_get "$_ab_b/online";      _bon=$_ab_v
      _ab_get "$_ab_b/voltage_now"; _bv=$_ab_v
      _ab_get "$_ab_s/usb_type";    _st=$_ab_v
      _ab_get "$_ab_s/online";      _son=$_ab_v
      _ab_get "$_ab_tc/power_role"; _pr=$_ab_v
      _ab_get "$_ab_tc/data_role";  _dr=$_ab_v
      if [ -e "$_ab_tc/port0-partner" ]; then _pt=yes; else _pt=no; fi
      _key="usb_type=$_bt online=$_bon V=$_bv src=$_st src_on=$_son power=$_pr data=$_dr partner=$_pt"
      if [ "$_key" != "$_prev" ]; then
        echo "<0>ARMADA-B USB: $_key" > /dev/kmsg 2>/dev/null
        _prev="$_key"
      fi
      # (c) liveness heartbeat every ~16 s
      if [ $((_n % 8)) -eq 0 ]; then
        _up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
        echo "<0>ARMADA-B status: up=${_up}s ulog_ok=$_ulog_ok seen=$_ulog_n usb_type=$_bt online=$_bon" > /dev/kmsg 2>/dev/null
      fi
      sleep 2
    done
    echo "<0>ARMADA-B: capture stopped (15 min cap)" > /dev/kmsg 2>/dev/null
  ) &
  echo $! > "$_ab_pidfile" 2>/dev/null
fi
