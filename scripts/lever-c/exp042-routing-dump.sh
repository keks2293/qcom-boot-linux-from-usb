#!/bin/sh
# EXP-042 routing capture: the eUSB2 data-path state, in BOTH modes
#   - working  (full-system pre-plug)  -> generates the baseline
#   - failing  (linux usb initramfs)   -> diffs against the baseline
#
# What it reads (all read-only, every read time-bounded, nothing hangs):
#   * the FULL SPMI 0-07 (pmic@7 = the eUSB2-repeater PMIC) regmap window
#     (/sys/kernel/debug/regmap/0-07/registers, 65536 x 9 B). This PMIC is the
#     only PMIC-side element of the data path (no PMIC USB-switch node exists;
#     the TCPC is ADSP-side, not AP-visible). Value "XX" = unimplemented SPMI
#     register (constant across modes -> washes out in the diff).
#   * the repeater window fd00-fd5b (the EXP-037/038 window) for immediate
#     visual comparison.
#   * data-path context: typec port0 (orientation/roles/partner/opmode),
#     usb_role switch, /sys/class/phy power states, the data-path regulators,
#     block + usb device lists.
#
# Subcommands:
#   baseline [OUT]   dump context + the full window to OUT (default
#                    /tmp/exp042-baseline.regmap). Run once in the WORKING
#                    mode to make the baseline; ship it in the failing image.
#   diff BASE [OUT]  dump context + repeater window, then diff the CURRENT
#                    full window against BASE (a clean 65536-line "addr: val"
#                    file) and print every differing register (capped). Run in
#                    the FAILING mode with BASE = the shipped baseline.
#
# Run as root. In the failing (initramfs) mode the baseline is shipped in the
# image at /etc/armada/exp042-baseline-0-07.regmap and the hook calls
#   sh <this> diff /etc/armada/exp042-baseline-0-07.regmap
# The output is console-oriented (photo OCR): the differing-register list is
# capped and the context is a fixed small number of lines.

RMAP=/sys/kernel/debug/regmap/0-07/registers
BLK_DEFAULT_OUT=/tmp/exp042-baseline.regmap
DIFF_CAP=300          # max differing registers printed before the cap note
RPT_LO=0xfd00         # repeater window (EXP-037/038)
RPT_HI=0xfd5b

die() { echo "FATAL: $*"; return 1; }

ensure_debugfs() {
  mountpoint -q /sys/kernel/debug 2>/dev/null || {
    mkdir -p /sys/kernel/debug
    mount -t debugfs none /sys/kernel/debug || die "debugfs mount failed"
  }
  [ -r "$RMAP" ] || die "$RMAP not readable (regmap debugfs built? 0-07 present?)"
}

# Fixed, OCR-able context block.
print_context() {
  echo "=== EXP-042 routing context $(date -u '+%F %R:%S UTC') ==="
  echo "kernel: $(uname -r)  uptime: $(cut -d' ' -f1 /proc/uptime)s"
  echo "cmdline: [$(tr '\n' ' ' < /proc/cmdline | cut -c1-200)]"
  echo "block: [$(ls /sys/block 2>/dev/null | tr '\n' ' ')]"
  for d in /sys/block/sd*; do
    [ -e "$d" ] || continue
    r=$(cd -P "$d" 2>/dev/null && pwd -P)
    case "$r" in *usb*) echo "usb-disk: ${d##*/} -> $r" ;; esac
  done
  echo "usb: [$(ls /sys/bus/usb/devices 2>/dev/null | tr '\n' ' ')]"
  p=/sys/class/typec/port0
  if [ -d "$p" ]; then
    echo "typec: orientation=[$(cat $p/orientation 2>/dev/null)] power=[$(cat $p/power_role 2>/dev/null)] data=[$(cat $p/data_role 2>/dev/null)] opmode=[$(cat $p/power_operation_mode 2>/dev/null)] partner=$([ -e $p-partner ] && echo yes || echo no)"
    if [ -e "$p-partner" ]; then
      echo "partner: pd=[$(cat $p-partner/supports_usb_power_delivery 2>/dev/null)] acc=[$(cat $p-partner/accessory_mode 2>/dev/null)]"
    fi
  else
    echo "typec: (no port0)"
  fi
  for d in /sys/class/usb_role/*/; do
    [ -d "$d" ] || continue
    echo "usb_role: ${d%/usb_role/} = [$(cat ${d}role 2>/dev/null)]"
  done
  echo "phy: [$(ls /sys/class/phy 2>/dev/null | tr '\n' ' ')]"
  echo "usb-chain runtime_status:"
  for x in /sys/devices/platform/soc@0/a600000.usb \
           /sys/devices/platform/soc@0/a600000.usb/xhci-hcd.*.auto; do
    [ -e "$x/power/runtime_status" ] || continue
    echo "  ${x##*/} = [$(cat "$x/power/runtime_status" 2>/dev/null)]"
  done
  # xHCI root-hub port status is not in sysfs; the port-change history is in dmesg.
  echo "xhci-port-events: [$(dmesg 2>/dev/null | grep -aE 'xhci.*Port change|usb [0-9]+-[0-9]+.*new .* USB device' | sed -E 's/^\[[0-9.]+\] //' | tail -6 | tr '\n' '|')]"
  echo "=== context end ==="
}

# The EXP-037/038 repeater window, 8 values per line.
repeater_window() {
  off=$(( RPT_LO * 9 + 1 ))
  cnt=$(( RPT_HI - RPT_LO + 1 ))
  echo "RPT-WIN fd00-fd5b:"
  timeout 30 tail -c +"$off" "$RMAP" 2>/dev/null | sed -n "1,${cnt}p" | \
    awk -F': ' '{printf "%s%s", $2, (NR%8==0? "\n":" ")}'
  echo
}

# Dump the full window to OUT; verify geometry; echo the line count on success.
dump_window() {
  out=$1
  timeout 60 cat "$RMAP" > "$out" 2>/dev/null || die "read of $RMAP failed"
  n=$(wc -l < "$out")
  first=$(sed -n '1p' "$out")
  case "$first" in
    "0000: "*) ;;
    *) die "geometry: first line is '$first' (expected '0000: ..')" ;;
  esac
  [ "$n" -eq 65536 ] || die "geometry: $n lines (expected 65536)"
  echo "$n"
}

cmd_baseline() {
  out=${1:-$BLK_DEFAULT_OUT}
  ensure_debugfs || return 1
  print_context
  repeater_window
  dump_window "$out" || return 1
  echo "=== EXP-042 BASELINE written: $out (65536 lines) ==="
  echo "ship this file in the failing image at /etc/armada/exp042-baseline-0-07.regmap"
}

cmd_diff() {
  base=${1:-}
  out=${2:-/tmp/exp042-cur.regmap}
  [ -n "$base" ] && [ -r "$base" ] || die "baseline not readable: '${base:-<none>}' (pass the clean 65536-line regmap file)"
  ensure_debugfs || return 1
  print_context
  repeater_window
  dump_window "$out" || return 1
  bn=$(wc -l < "$base")
  [ "$bn" -eq 65536 ] || die "baseline geometry: $bn lines (expected 65536)"
  echo "=== EXP-042 DIFF current vs $base ==="
  # exact register-level diff: print every line that differs (line N = reg N-1).
  awk -v cap="$DIFF_CAP" '
    NR==FNR { b[FNR]=$0; next }
    {
      if (b[FNR] != $0) {
        tot++
        if (tot <= cap) printf "DIFF reg 0x%04x  base=[%s]  cur=[%s]\n", FNR-1, b[FNR], $0
      }
    }
    END {
      printf "=== EXP-042 DIFF complete: %d registers differ (printing up to %d) ===\n", tot+0, cap
      if (tot+0 > cap) printf "(capped at %d; the remaining %d differing registers are not printed)\n", cap, tot+0-cap
    }
  ' "$base" "$out"
  rm -f "$out"
}

case "${1:-}" in
  baseline) cmd_baseline "${2:-}" ;;
  diff)     cmd_diff "${2:-}" "${3:-}" ;;
  *)
    echo "usage: $0 {baseline [OUT] | diff BASE [OUT]}"
    echo "  baseline [OUT]  working mode: dump context + full 0-07 window to OUT"
    echo "  diff BASE [OUT] failing mode: diff current window against BASE, print the differing registers"
    exit 2 ;;
esac
