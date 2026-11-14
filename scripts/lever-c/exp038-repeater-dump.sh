#!/bin/sh
# EXP-038 capture: eUSB2 repeater 0xfd00-0xfd5b in the WORKING mode
# (normal/"sdcard" boot, USB stick enumerated). Read-only except an
# on-demand debugfs mount; every read is time-bounded, nothing can hang.
# Mirrors the v8 hook's verified mechanics (scan-based candidate
# selection, fd08=80/fd46=80 signature, RPT-* line format) with one
# extra guard: the line width is measured from the file itself instead
# of assuming the CI kernel's 9 B/line geometry.
#
# Run as root on the RP6:
#   sudo sh /var/home/armada/opencode/qcom-boot-linux-from-usb/scripts/lever-c/exp038-repeater-dump.sh
# Output is teed to /tmp/exp038-repeater.txt (world-readable).

main() {
  echo "=== EXP-038 repeater capture $(date -u '+%F %R:%S UTC') ==="
  echo "kernel: $(uname -r)"
  [ -r "/lib/modules/$(uname -r)/.armada-source" ] && \
    sed 's/^/  src: /' "/lib/modules/$(uname -r)/.armada-source"
  echo "uptime: $(cut -d' ' -f1 /proc/uptime)s"
  echo "cmdline: [$(tr '\n' ' ' < /proc/cmdline | cut -c1-240)]"

  echo "block: [$(ls /sys/block 2>/dev/null | tr '\n' ' ')]"
  for d in /sys/block/sd*; do
    [ -e "$d" ] || continue
    r=$(cd -P "$d" 2>/dev/null && pwd -P)
    case "$r" in *usb*) echo "usb-disk: ${d##*/} -> $r" ;; esac
  done
  echo "usb: [$(ls /sys/bus/usb/devices 2>/dev/null | tr '\n' ' ')]"
  p=/sys/class/typec/port0
  [ -d "$p" ] && echo "typec: orientation=[$(cat $p/orientation 2>/dev/null)] partner=$([ -e $p-partner ] && echo yes || echo no) power=[$(cat $p/power_role 2>/dev/null)] data=[$(cat $p/data_role 2>/dev/null)]"
  echo "stick-plug-history: [$(dmesg 2>/dev/null | grep -E 'usb 1-1\.[0-9]+: (new|USB disconnect)' | sed -E 's/^\[[0-9.]+\] //' | tail -6 | tr '\n' '|')]"

  mountpoint -q /sys/kernel/debug 2>/dev/null || {
    mkdir -p /sys/kernel/debug
    mount -t debugfs none /sys/kernel/debug || { echo "FATAL: debugfs mount failed"; return 1; }
  }
  [ -d /sys/kernel/debug/regmap ] || { echo "FATAL: no /sys/kernel/debug/regmap (CONFIG_REGMAP_DEBUGFS not built?)"; return 1; }

  spmi=$(ls /sys/bus/spmi/devices 2>/dev/null | grep -v '^spmi-')
  rdirs=$(ls /sys/kernel/debug/regmap 2>/dev/null)
  echo "spmi: [$(echo "$spmi" | tr '\n' ' ')]"
  echo "regmap: [$(echo "$rdirs" | tr '\n' ' ')]"
  cand=""
  for d in $rdirs; do
    for s in $spmi; do
      [ "$d" = "$s" ] && cand="$cand $d" && break
    done
  done
  [ -z "$cand" ] && cand=" $rdirs"
  echo "candidates: [$cand]"

  hit=0
  for d in $cand; do
    f="/sys/kernel/debug/regmap/$d/registers"
    [ -r "$f" ] || { echo "RPT-SCAN: $d (no readable registers file)"; continue; }
    # line geometry: first line, e.g. "0000: 00"; file width = line + \n
    fl=$(head -c 64 "$f" 2>/dev/null | sed -n '1p')
    lw=$(( ${#fl} + 1 ))
    off=$(( 64768 * lw + 1 ))            # fd00 = line 64768 (0-based) -> 1-based byte
    t=/tmp/exp038-$d.txt
    timeout 60 tail -c +"$off" "$f" 2>/dev/null | sed -n '1,92p' > "$t"
    first=$(sed -n '1p' "$t" 2>/dev/null)
    case "$first" in
      fd00:*) ;;
      *) echo "RPT-SCAN: $d GEOM-MISMATCH lw=$lw first='$first' (window not at fd00)"; continue ;;
    esac
    i=0; line=""; blk=""; key=""; wrn=""
    while read -r l; do
      [ -n "$l" ] || continue
      reg=${l%%:*}; val=${l#*: }
      i=$((i + 1)); line="$line ${reg}=${val}"
      [ $((i % 8)) -eq 0 ] && { blk="${blk}${line# }|"; line=""; }
      case $reg in
        fd50|fd52|fd55|fd56|fd58|fd59|fd5a|fd5b) key="$key ${reg#fd}=$val" ;;
        fd08|fd46|fd51|fd53|fd54|fd57)          wrn="$wrn ${reg#fd}=$val" ;;
      esac
    done < "$t"
    [ -n "$line" ] && blk="${blk}${line# }|"
    echo "RPT-SCAN: $d lines=$i WRN:${wrn} KEY:${key}"
    case "$wrn" in
      *" 08=80 46=80 "*)
        hit=1
        echo "RPT-DUMP: repeater regmap=$d (92 regs fd00-fd5b, lw=$lw)"
        oldifs=$IFS; IFS='|'
        for l in $blk; do [ -n "$l" ] && echo "RPT-B: $l"; done
        IFS=$oldifs
        echo "RPT-KEY (never kernel-written; residue candidates): ${key# }"
        echo "RPT-WRN (expect 08=80 46=80 51=0b 53=06 54=03 57=03): ${wrn# }"
        ;;
    esac
  done
  [ "$hit" -eq 1 ] || echo "RPT-NOHIT: no candidate showed fd08=80/fd46=80"
  echo "=== EXP-038 CAPTURE COMPLETE ==="
}

main 2>&1 | tee /tmp/exp038-repeater.txt
