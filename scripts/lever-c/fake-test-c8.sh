#!/bin/sh
# Fake-sysfs smoke test for diag/armada-usb-fix-c8.sh (lever C v8, dbgC8).
#
# Emulates dracut-initqueue: SOURCES the path-redirected hook every ~0.5 s
# (like `job=$job . "$job"`) until the done-marker appears, so the pidfile
# guard, the heartbeat and the idempotency are exercised too.  A background
# "world" process drives the fake sysfs/dmesg timeline:
#   PDR @1 s, typec roles + partner @2 s, xhci @2.2 s.  Role files use the
#   real kernel formats (typec port attributes with only the CURRENT role
#   bracketed, class.c:1794-1804; the usb_role class attribute as a single
#   word, roles/class.c role_show).  The usb bus (usb1) is faked BOTH under
#   /sys/bus/usb/devices AND as a child of the xhci platform device dir (as
#   on the real system, for the xhci -> usbN mapping dump line).  The
#   partner is faked as /sys/class/typec/port0-partner (v4 gate).  The fake
#   `date` reports seconds elapsed since the harness start, so the hook's
#   absolute "up >= 10" tree-dump gate fires in fake time exactly like on
#   the device.
#
# v5 differences from the v4 harness:
#   - NO xhci rebind loop in the hook: the first post-partner scan gets a
#     3 s window, then the FULL-CHAIN ESCALATION runs immediately.  The
#     world's fake UCSI rebind (fake_ubind) is what recreates the xhci
#     device under a NEW auto ID (xhci-hcd.3.auto -- proves the hook's
#     dynamic glob, never a hard-coded number) and, in the success modes,
#     the stick.
#   - the UCSI DRIVER IS RESOLVED AT RUNTIME: the fake UCSI aux device dir
#     carries a `driver` symlink to the fake driver dir (the hook does
#     `cd -P <dev>/driver && pwd -P`), and the hook's
#     `echo "$_ac_ucsi_d" > "$_ac_ucsi_drv/unbind|bind"` lines are sed-
#     replaced by the fake ops.  Two abort branches are tested: okforced
#     (device present, NO driver symlink -> rc=128, dwc3 NOT touched) and
#     escfail (device ABSENT -> rc=127, dwc3 NOT touched) -- the exact
#     run-5 failure (hard-coded path missing) and its sibling.
#   - the -110 event is injected by the WORLD (after the first scan
#     started), because the hook no longer rebinds xhci on the main path.
#
# v6 differences from the v5 harness:
#   - the REPEATER DUMP is tested in EVERY mode (it runs after the v5
#     sequence): a fake repeater platform device (symlink in the bus
#     listing -> real dir under the fake PMIC spmi device 0-07, the
#     spmi.c:67 "%d-%02x" dev_name) and the fake regmap debugfs dir
#     regmap/0-07 with a full-size 'registers' file (65536 x 9 B lines,
#     "XXXX: XX\\n"; the 8 residue registers = 00, the written ones =
#     the kernel values).  The Mac's BSD tail has no "+N", so a fake GNU
#     tail (dd-based) is put on PATH; /proc/mounts pre-declares debugfs
#     (the hook's mount-on-demand path is therefore a no-op; a fake
#     `mount` is present as a fallback).
#   - mode norp: the repeater device is ABSENT -> "RPT-ABSENT: no
#     *eusb2* platform device", no RPT-B/KEY/WRN lines.
#   - mode normal: the WORLD now plugs the stick at 2 s, so the dump's
#     "wait for a USB disk (<=45s)" ends quickly and the known-good
#     blob is printed (RPT-NOTE must NOT appear).
#
# v7 differences from the v6 harness:
#   - the dump is INSTRUMENTED: every step prints a marker, so the harness
#     now also asserts the step markers (RPT-S0..S5) and the 92-line count.
#   - three new fake tools: `timeout` (the hook bounds the read with
#     `timeout 90`), `stat -c %s` (the hook prints byte counts; the Mac's
#     BSD stat has no -c) and a smarter `dmesg` (`-n N` sets the fake
#     /proc/sys/kernel/printk, plain `dmesg` cats the log -- the hook
#     counts spmi timeouts with `dmesg | grep -c`).
#
# v8 differences from the v7 harness:
#   - the dump no longer resolves the repeater through the platform-device
#     symlink (run 3 proved that chain hangs): it LISTS the debugfs regmap
#     dirs, intersects them with /sys/bus/spmi/devices/ and identifies the
#     repeater by fd08=80/fd46=80.  The fake tree therefore gains
#     sys/bus/spmi/devices/{0-07,0-08} and a DECOY regmap dir 0-08 (small
#     map -> empty window).  mode norp = EMPTY regmap dir -> RPT-ABSENT
#     "no regmap debugfs dirs".
#   - assertions follow the new markers (RPT-S2 spmi/regmap/candidates,
#     RPT-SCAN one-liner, RPT-DUMP repeater regmap=<dir>).
#
# Modes / expected verdicts (ARMADA-C: lines, <0> level):
#   ok1400    patch-1400 kernel: xhci ABSENT at start, appears with the
#             post-PDR flip + partner; disk from the first post-flip scan
#             (within the 3 s window) -> "ENUMERATION OK (first post-PDR
#             scan)" + TREE[OK], NO escalation
#   okfull    first post-flip scan finds nothing (3 s) -> immediate
#             escalation -> the full chain recreates xhci (as .3.auto) and
#             finds the stick -> "FAIL-NO-SCAN" (first scan) +
#             "ENUMERATION OK (full-chain)" + TREE[OK-FULL] (beta-1)
#   failall   first post-flip AND full-chain never find the disk ->
#             "FAIL-NO-SCAN" + "FAIL-NO-SCAN-FULL" + TREE[NO-SCAN-FULL]
#             (beta-2)
#   110       "Host halt failed, -110" during the first post-flip scan ->
#             immediate "FAIL: Host halt -110 after the first post-flip
#             scan; no retry" and NO escalation
#   nodev     xhci never appears (role flip did not happen; no partner)
#             -> "FAIL-NO-DEV" + WARN-nopartner -> escalation -> the full
#             chain recreates xhci (as .3.auto) and the disk appears ->
#             "ENUMERATION OK (full-chain)"
#   nopartner partner never appears (xhci does) -> WARN-nopartner, 3 s
#             window, escalation, the full chain still finds nothing ->
#             "FAIL-NO-SCAN-FULL"
#   okforced  forced-host kernel: xhci present+bound from t=0, NO port0 at
#             all (UCSI probe hard-fails -> the aux device is UNBOUND: no
#             `driver` symlink) -> start-unbind, WARN-nopartner, 3 s
#             window, escalation -> ucsi resolve rc=128 (device present,
#             unbound) -> "FAIL-ESCALATE ... dwc3 NOT touched" + ESC-ABORT
#   escfail   like failall but the UCSI aux device is ABSENT entirely ->
#             escalation -> ucsi resolve rc=127 -> "FAIL-ESCALATE ... dwc3
#             NOT touched" + ESC-ABORT
#   already   USB disk present at start -> "already enumerated (sdg) ..."
#   normal    no dr_mode=host in the DT -> "not linux-usb mode ...; no
#             rescan", xhci left bound; the WORLD plugs the stick at 2 s
#             -> the v6 dump waits ~2 s and prints the blob
#   norp      like failall but the repeater platform device is ABSENT ->
#             "RPT-ABSENT: no *eusb2* platform device" after the chain
#
# Each mode ends with PASS/FAIL assertions on the verdict, the TREE /
# escalation lines and the v6 dump lines; the exit status is non-zero
# if any assertion failed.
#
# Usage: sh fake-test-c6.sh <mode> [mode ...]   (default: all 11)
set -u
SRC=${SRC:-/Users/rmitkov/opencode/rp6/diag/armada-usb-fix-c8.sh}
[ -r "$SRC" ] || { echo "hook not readable: $SRC" >&2; exit 2; }
BASE=${C8BASE:-${TMPDIR:-/tmp}/armada-c8-test}
FAILURES=0

run_mode() {
  MODE=$1
  R="$BASE/$MODE"
  rm -rf "$R"; mkdir -p "$R/tmp" "$R/bin" "$R/proc" \
    "$R/sys/bus/platform/devices/a600000.usb/of_node" \
    "$R/sys/bus/platform/drivers/xhci-hcd" \
    "$R/sys/bus/platform/drivers/dwc3-qcom" \
    "$R/sys/bus/auxiliary/devices" "$R/sys/bus/auxiliary/drivers/pmic_glink_ucsi" \
    "$R/sys/class/typec" \
    "$R/sys/class/usb_role/a600000.usb-role-switch" \
    "$R/sys/block" \
    "$R/sys/bus/usb/devices" \
    "$R/sys/devices/platform/soc@0/1d84000.ufshc/host0/target0:0:0/0:0:0:0/block/sda" \
    "$R/sys/devices/platform/soc@0/a600000.usb/usb1/1-1/1-1:1.0/host0/target0:0:0/0:0:0:0/block/sdg" \
    "$R/sys/devices/platform/spmi-0/0-07/eusb2-repeater@fd00" \
    "$R/sys/kernel/debug/regmap/0-07" "$R/sys/kernel/debug/regmap/0-08" \
    "$R/sys/bus/spmi/devices/0-07" "$R/sys/bus/spmi/devices/0-08"
  TC=$R/sys/class/typec/port0
  PARTNERF=$R/sys/class/typec/port0-partner
  DRV=$R/sys/bus/platform/drivers/xhci-hcd
  USBD=$R/sys/bus/usb/devices
  ROLEF=$R/sys/class/usb_role/a600000.usb-role-switch/role
  XDEV0=$R/sys/bus/platform/devices/a600000.usb/xhci-hcd.0.auto
  XDEV3=$R/sys/bus/platform/devices/a600000.usb/xhci-hcd.3.auto
  UCDEV=$R/sys/bus/auxiliary/devices/pmic_glink.ucsi.0
  UDRV=$R/sys/bus/auxiliary/drivers/pmic_glink_ucsi
  SDG="$R/sys/devices/platform/soc@0/a600000.usb/usb1/1-1/1-1:1.0/host0/target0:0:0/0:0:0:0/block/sdg"
  SDG_LINK="../devices/platform/soc@0/a600000.usb/usb1/1-1/1-1:1.0/host0/target0:0:0/0:0:0:0/block/sdg"

  case $MODE in normal) : > "$R/sys/bus/platform/devices/a600000.usb/of_node/dr_mode" ;;
                  *)      printf 'host\0' > "$R/sys/bus/platform/devices/a600000.usb/of_node/dr_mode" ;; esac

  # UFS (also sd* -- must NOT be matched); in `already`, a USB disk at start
  ln -sfn ../devices/platform/soc@0/1d84000.ufshc/host0/target0:0:0/0:0:0:0/block/sda "$R/sys/block/sda"
  [ "$MODE" = already ] && ln -sfn "$SDG_LINK" "$R/sys/block/sdg"

  # UCSI aux device (present in all modes except escfail) and, in the
  # patch-1400 modes, the typec port (a forced-host kernel has NO port0:
  # the UCSI probe hard-fails without a role switch, ucsi.c:1838-1840)
  [ "$MODE" != escfail ] && mkdir -p "$UCDEV"
  if [ "$MODE" != okforced ]; then
    mkdir -p "$TC"
    printf 'source [sink]\n' > "$TC/power_role"
    printf 'host [device]\n'  > "$TC/data_role"
    printf 'normal\n' > "$TC/orientation"
    printf 'device\n' > "$ROLEF"
  fi

  # v5: the UCSI DRIVER is resolved from the device's `driver` symlink
  # (cd -P / pwd -P).  okforced models the forced-host reality: the aux
  # device exists but the UCSI probe hard-failed -> UNBOUND (no symlink).
  # escfail has no device at all.  Everyone else: bound.
  case $MODE in okforced|escfail) : ;; *) ln -sfn "$UDRV" "$UCDEV/driver" ;; esac

  # v6: the repeater platform device (of_platform child of the PMIC spmi
  # device; bus listing entry = symlink to the real device dir) and the
  # PMIC regmap debugfs dir with a full-size 'registers' file (65536 x
  # 9 B lines "XXXX: XX\\n"; the 8 residue registers = 00, the kernel-
  # written ones = the kernel values).  norp has NO repeater device.
  [ "$MODE" != norp ] && \
    ln -sfn ../../../devices/platform/spmi-0/0-07/eusb2-repeater@fd00 \
      "$R/sys/bus/platform/devices/eusb2-repeater@fd00"
  # values at ABSOLUTE PMIC addresses (block base 0xfd00 + the driver
  # offsets): host-mode kernel writes 0xfd08=80 (RPTR_OK status),
  # 0xfd46=80 (RPTR_EN), 0xfd51=0b / 0xfd53=06 / 0xfd57=03 (DT),
  # 0xfd54=03 (init table); 0xfde8/0xfded=40/40 (set_mode HOST, outside
  # the dumped window); the 8 residue regs = 00
  python3 - "$R/sys/kernel/debug/regmap/0-07/registers" <<'PYEOF'
import sys
vals = {0xfd08: '80', 0xfd46: '80', 0xfd51: '0b', 0xfd53: '06',
        0xfd54: '03', 0xfd57: '03', 0xfde8: '40', 0xfded: '40'}
with open(sys.argv[1], 'w') as f:
    for r in range(0x10000):
        f.write('%04x: %s\n' % (r, vals.get(r, '00')))
PYEOF
  # v8: a DECOY regmap dir (a small map: the fd00 window is beyond its
  # EOF -> empty read) and, for mode norp, NO regmap dirs at all
  python3 - "$R/sys/kernel/debug/regmap/0-08/registers" <<'PYEOF'
import sys
with open(sys.argv[1], 'w') as f:
    for r in range(16):
        f.write('%04x: 00\n' % r)
PYEOF
  [ "$MODE" = norp ] && rm -rf "$R/sys/kernel/debug/regmap/"*
  # /proc/mounts pre-declares debugfs (the hook's mount-on-demand is a
  # no-op; the fake `mount` is a fallback)
  printf 'debugfs /sys/kernel/debug debugfs rw,relatime 0 0\n' > "$R/proc/mounts"
  # v7: the console level file the dump reads/saves (real /proc in the
  # initramfs; dracut leaves 4 = quiet, the hook saves and restores it)
  mkdir -p "$R/proc/sys/kernel"
  printf '4 4 1 7\n' > "$R/proc/sys/kernel/printk"
  # fake GNU tail (the Mac's BSD tail has no "+N"): "tail -c +N file"
  # = bytes from 0-based offset N-1 to EOF (the hook's only tail form)
  printf '%s\n' \
    '#!/bin/sh' \
    '[ "$1" = "-c" ] || exit 1' \
    'n=${2#+}; f=$3' \
    'size=$(wc -c < "$f" | tr -d " ")' \
    'off=$((n - 1)); [ "$off" -lt 0 ] && off=0' \
    '[ "$off" -ge "$size" ] && exit 0' \
    'dd bs=1 skip="$off" count="$((size - off))" if="$f" 2>/dev/null' \
    > "$R/bin/tail"
  printf '#!/bin/sh\nexit 0\n' > "$R/bin/mount"
  # v7: `timeout N cmd ...` -> run cmd (the hook's read bound)
  printf '#!/bin/sh\nshift\nexec "$@"\n' > "$R/bin/timeout"
  # v7: `stat -c %s FILE` -> byte size (the Mac's BSD stat has no -c)
  printf '#!/bin/sh\n[ "$1" = "-c" ] && [ "$2" = "%%s" ] && { wc -c < "$3" | tr -d " "; exit 0; }\nexec /usr/bin/stat "$@"\n' > "$R/bin/stat"
  chmod +x "$R/bin/tail" "$R/bin/mount" "$R/bin/timeout" "$R/bin/stat"

  # host-side usb bus: usb1 appears when the xhci driver is bound, 1-1 /
  # 1-1:1.0 when a scan finds the stick; unbinding xhci tears usb1 down.
  # usb1 also appears INSIDE the current xhci device dir (the usb bus is a
  # child of the xhci platform device) for the mapping dump line.
  usb1_attach() { for _x in "$R"/sys/bus/platform/devices/a600000.usb/xhci-hcd.*; do [ -d "$_x" ] && mkdir -p "$_x/usb1" 2>/dev/null; done; }
  mk_usb1()  { mkdir -p "$USBD/usb1"; usb1_attach; }
  mk_stick() { mkdir -p "$USBD/usb1" "$USBD/1-1" "$USBD/1-1:1.0"; usb1_attach; ln -sfn "$SDG_LINK" "$R/sys/block/sdg"; }
  [ "$MODE" = already ] && mk_stick
  [ "$MODE" = okforced ] && mk_usb1
  [ "$MODE" = normal ]   && mk_usb1

  # fake dmesg (reads the world's log), udevadm (settle no-op), date
  # (seconds elapsed since T0 -- the hook's absolute up>=10 gate works in
  # fake time)
  # v7: dmesg -- `-n N` sets the fake console loglevel (the hook quiets
  # the console during the read: dmesg -n 1 ... dmesg -n 4), plain
  # `dmesg` prints the fake log (the hook counts spmi timeouts with it)
  printf '#!/bin/sh\nif [ "$1" = "-n" ]; then printf "%%s 4 1 7\\n" "$2" > "%s/proc/sys/kernel/printk"; exit 0; fi\ncat "%s/dmesg.txt" 2>/dev/null\n' "$R" "$R" > "$R/bin/dmesg"
  printf '#!/bin/sh\nexit 0\n' > "$R/bin/udevadm"
  T0=$(python3 -c 'import time; print(int(time.time()))' 2>/dev/null || echo 0)
  printf '#!/bin/sh\nv=$(python3 -c "import time; print(int(time.time()) - %s)" 2>/dev/null)\n[ -n "$v" ] && [ "$v" -ge 0 ] && echo "$v" || echo 0\n' "$T0" > "$R/bin/date"
  chmod +x "$R/bin/dmesg" "$R/bin/udevadm" "$R/bin/date"
  : > "$R/dmesg.txt"

  # xhci device dir + driver bind-link (link present == bound)
  mk_xhci() {
    mkdir -p "$XDEV0"
    ln -sfn ../../devices/a600000.usb/xhci-hcd.0.auto "$DRV/xhci-hcd.0.auto"
  }
  case $MODE in okforced|already|normal) mk_xhci ;; esac

  # fake driver ops (replace the sysfs writes via sed).  They model the
  # real lifecycle (RP6-NOTES, code-verified):
  #   xhci unbind: tears the root hub down (the device DIR survives --
  #     only the bind link goes).
  #   UCSI unbind (aux bus, resolved via the device's `driver` symlink):
  #     the partner goes down (port unregistered); UCSI rebind: partner
  #     back (the chain then completes itself).
  #   dwc3 unbind: DESTROYS the xhci device dir (dwc3_host_exit) and the
  #     role switch; dwc3 rebind: role switch back (initial mode DEVICE,
  #     no xhci yet -- the flip comes with the UCSI rebind).
  #   On full-chain completion the xhci device is RECREATED UNDER A NEW
  #   AUTO ID (xhci-hcd.3.auto) -- the hook must find it by glob.
  {
    printf 'usb1_attach() { for _x in %s/sys/bus/platform/devices/a600000.usb/xhci-hcd.*; do [ -d "$_x" ] && mkdir -p "$_x/usb1" 2>/dev/null; done; }\n' "$R"
    printf 'rm_usb1() { rm -rf %s/usb1 %s/1-1 %s/1-1:1.0; for _x in %s/sys/bus/platform/devices/a600000.usb/xhci-hcd.*; do [ -d "$_x" ] && rm -rf "$_x/usb1"; done; }\n' "$USBD" "$USBD" "$USBD" "$R"
    printf 'mk_usb1f() { mkdir -p %s/usb1; usb1_attach; }\n' "$USBD"
    printf 'mk_stickf() { mkdir -p %s/usb1 %s/1-1 %s/1-1:1.0; usb1_attach; ln -sfn %s %s/sys/block/sdg; }\n' "$USBD" "$USBD" "$USBD" "$SDG_LINK" "$R"
    printf 'mk_partner() { printf "Retroid stick\\n" > %s; }\n' "$PARTNERF"
    printf 'rm_partner() { rm -f %s; }\n' "$PARTNERF"
    printf 'mk_rolesw() { mkdir -p %s; printf "device\\n" > %s; }\n' "$R/sys/class/usb_role/a600000.usb-role-switch" "$ROLEF"
    printf 'mk_xhci3() { mkdir -p %s; ln -sfn ../../devices/a600000.usb/xhci-hcd.3.auto %s/xhci-hcd.3.auto; }\n' "$XDEV3" "$DRV"
    printf 'fake_xunbind() { [ -n "$1" ] && rm -f %s/"$1"; rm_usb1; return 0; }\n' "$DRV"
    printf 'fake_uunbind() { [ -n "$1" ] || return 1; rm -f %s/"$1"; rm_partner; return 0; }\n' "$UDRV"
    printf 'fake_ubind() {\n'
    printf '  [ -n "$1" ] || return 1\n'
    printf '  ln -sfn "../devices/$1" %s/"$1"\n' "$UDRV"
    printf '  case "$MODE" in\n'
    printf '    okfull|nodev) mk_partner; mk_xhci3; mk_stickf ;;\n'
    printf '    failall|nopartner) mk_xhci3; mk_usb1f ;;\n'
    printf '  esac\n'
    printf '  return 0\n}\n'
    printf 'fake_dunbind() { rm -rf %s %s; rm -f %s/xhci-hcd.0.auto %s/xhci-hcd.3.auto; rm_usb1; rm -rf %s/sys/class/usb_role/a600000.usb-role-switch; return 0; }\n' \
      "$XDEV0" "$XDEV3" "$DRV" "$DRV" "$R"
    printf 'fake_dbind() { mk_rolesw; return 0; }\n'
  } > "$R/fn.sh"

  # path-redirected hook: fake sysfs/tmp/kmsg/proc (macOS has no /proc, so
  # the pidfile liveness check needs the fake /proc/<pid> dirs, created by
  # the loop below; on the device the real /proc works as-is).  The six
  # sysfs driver writes (xhci unbind in _ac_xunbind and in the escalation,
  # ucsi unbind/bind via the RUNTIME-RESOLVED driver path, dwc3 unbind/
  # bind) are replaced by the fake ops (the rc variable name is preserved
  # by the capture group).
  # v7: the /sys and /proc rules go through placeholders (a plain
  # "s#/sys#${R}/sys#g" also hits the /sys inside /proc/sys/kernel, which
  # produced <R>/proc<R>/sys/... for the v7 printk file)
  sed -e 's#cut -d\. -f1 /proc/uptime#date +%s#' \
      -e "s#/proc/sys#@@PSYS@@#g" \
      -e "s#/sys#@@SYS@@#g" \
      -e "s#/proc#@@PROC@@#g" \
      -e "s#/tmp#@@TMP@@#g" \
      -e "s#@@PSYS@@#${R}/proc/sys#g" \
      -e "s#@@SYS@@#${R}/sys#g" \
      -e "s#@@PROC@@#${R}/proc#g" \
      -e "s#@@TMP@@#${R}/tmp#g" \
      -e "s#> /dev/kmsg#>> ${R}/kmsg#g" \
      -e 's#echo "\$_ac_ucsi_d" > "\$_ac_ucsi_drv/unbind" 2>/dev/null; \(_[a-z0-9]*\)=$?.*#fake_uunbind "$_ac_ucsi_d"; \1=$?#' \
      -e 's#echo "\$_ac_ucsi_d" > "\$_ac_ucsi_drv/bind" 2>/dev/null; \(_[a-z0-9]*\)=$?.*#fake_ubind "$_ac_ucsi_d"; \1=$?#' \
      -e 's#echo "\$_n" > "\$_ac_xdrv/unbind" 2>/dev/null; \(_[a-z0-9]*\)=$?.*#fake_xunbind "$_n"; \1=$?#' \
      -e 's#echo "\$_ac_dev" > "\$_ac_ddrv/unbind" 2>/dev/null; \(_[a-z0-9]*\)=$?.*#fake_dunbind; \1=$?#' \
      -e 's#echo "\$_ac_dev" > "\$_ac_ddrv/bind" 2>/dev/null; \(_[a-z0-9]*\)=$?.*#fake_dbind; \1=$?#' \
      "$SRC" > "$R/body.sh"
  cat "$R/fn.sh" "$R/body.sh" > "$R/hook.sh"

  # world timeline (PDR @1 s, roles+partner @2 s, xhci @2.2 s; the partner
  # is the v4 "PPM sees the stick" gate marker).  These must be FUNCTIONS
  # in this scope (not strings): the world subshells inherit functions,
  # while a string executed via $VAR keeps its quote characters literal.
  world_pdr() { echo "[   3.500] PDR: Indication received from msm/adsp/charger_pd, state: 0x1fffffff, trans-id: 1" >> "$R/dmesg.txt"; }
  set_roles_host() { printf '[source] sink\n' > "$TC/power_role"; printf '[host] device\n' > "$TC/data_role"; printf 'host\n' > "$ROLEF"; }
  mk_partner() { printf 'Retroid stick\n' > "$PARTNERF"; }
  rm_partner() { rm -f "$PARTNERF"; }
  case $MODE in
    ok1400)
      ( sleep 1;  world_pdr
        sleep 1;  set_roles_host; mk_partner; mk_xhci
        sleep 0.2; mk_stick ) &
      ;;
    okfull|failall)
      ( sleep 1;  world_pdr
        sleep 1;  set_roles_host; mk_partner
        sleep 0.2; mk_xhci; mk_usb1 ) &
      ;;
    nopartner)
      ( sleep 1;  world_pdr
        sleep 1;  set_roles_host
        sleep 0.2; mk_xhci; mk_usb1 ) &
      ;;
    110)
      ( sleep 1;  world_pdr
        sleep 1;  set_roles_host; mk_partner
        sleep 0.2; mk_xhci; mk_usb1
        sleep 0.4; echo "[   9.900] xhci-hcd: Host halt failed, -110" >> "$R/dmesg.txt" ) &
      ;;
    nodev)
      ( sleep 1;  world_pdr
        sleep 1;  set_roles_host ) &
      ;;
    okforced)
      ( sleep 1;  world_pdr ) &
      ;;
    escfail)
      ( sleep 1;  world_pdr
        sleep 1;  set_roles_host; mk_partner
        sleep 0.2; mk_xhci; mk_usb1 ) &
      ;;
    norp)
      ( sleep 1;  world_pdr
        sleep 1;  set_roles_host; mk_partner
        sleep 0.2; mk_xhci; mk_usb1 ) &
      ;;
    already)
      :
      ;;
    normal)
      # v6: the stick enumerates at 2 s -> the dump's disk-wait ends
      # quickly and the known-good blob is printed
      ( sleep 2; mk_stick ) &
      ;;
  esac

  PATH="$R/bin:$PATH"; export PATH

  # emulate dracut-initqueue: source every ~0.5 s until done (cap 80 s --
  # the longest v5 modes run ~41 s of fake time: partner-gate 20 s + 3 s
  # window + escalation + the 15 s full-chain disk wait); keep the fake
  # /proc/<pid> alive while the subshell runs (liveness guard)
  i=0
  while [ ! -f "$R/tmp/armada-c.done" ] && [ $i -lt 160 ]; do
    . "$R/hook.sh"
    _p=$(cat "$R/tmp/armada-c.pid" 2>/dev/null)
    [ -n "$_p" ] && mkdir -p "$R/proc/$_p"
    sleep 0.5; i=$((i + 1))
  done

  echo "===== mode=$MODE loop=$i done=$([ -f "$R/tmp/armada-c.done" ] && echo yes || echo TIMEOUT) ====="
  cat "$R/kmsg" 2>/dev/null
  echo "----- end state: bound=$(ls "$DRV" 2>/dev/null | tr '\n' ' ') ucsi=$(ls "$UDRV" 2>/dev/null | tr '\n' ' ') block=$(ls "$R/sys/block" 2>/dev/null | tr '\n' ' ') usb=$(ls "$USBD" 2>/dev/null | tr '\n' ' ')"

  # v5 assertions: the verdict, the tree-dump lines, the gate and the
  # escalation behaviour (including both UCSI-resolve abort branches)
  check() {
    if grep -qF -- "$1" "$R/kmsg" 2>/dev/null; then _f=1; else _f=0; fi
    if [ "$_f" -eq "$2" ]; then
      echo "PASS: $1"
    else
      echo "FAIL: $1 (found=$_f want=$2)"
      FAILURES=$((FAILURES + 1))
    fi
  }
  case $MODE in
    ok1400)   check "hook loaded" 1; check "partner at" 1; check "ENUMERATION OK (first post-PDR scan)" 1; check "TREE[OK]" 1; check "ESCALATE" 0; check "TREE[t10]" 0 ;;
    okfull)   check "FAIL-NO-SCAN: no USB disk after the first post-flip scan" 1; check "ESCALATE at" 1; check "ESCDIAG" 1; check "ENUMERATION OK (full-chain)" 1; check "TREE[OK-FULL]" 1; check "xhci xhci-hcd.3.auto -> [usb1" 1; check "TREE[t10]" 0 ;;
    failall)  check "FAIL-NO-SCAN: no USB disk after the first post-flip scan" 1; check "ESCALATE at" 1; check "FAIL-NO-SCAN-FULL" 1; check "TREE[NO-SCAN-FULL]" 1; check "orientation=[normal]" 1; check "TREE[t10]" 1; check "ESCDIAG" 1 ;;
    110)      check "FAIL: Host halt -110 after the first post-flip scan" 1; check "TREE[halt-110]" 1; check "ESCALATE" 0 ;;
    nodev)    check "FAIL-NO-DEV" 1; check "WARN-nopartner" 1; check "ESCALATE at" 1; check "ENUMERATION OK (full-chain)" 1; check "xhci-hcd.3.auto" 1 ;;
    nopartner) check "WARN-nopartner" 1; check "FAIL-NO-SCAN" 1; check "ESCALATE at" 1; check "FAIL-NO-SCAN-FULL" 1; check "TREE[NO-SCAN-FULL]" 1 ;;
    okforced) check "WARN-nopartner" 1; check "FAIL-NO-SCAN" 1; check "ESCALATE at" 1; check "rc=128" 1; check "ESC-ABORT" 1; check "dwc3 NOT touched" 1; check "ENUMERATION OK" 0 ;;
    escfail)  check "FAIL-NO-SCAN" 1; check "ESCALATE at" 1; check "rc=127" 1; check "ESC-ABORT" 1; check "dwc3 NOT touched" 1; check "ENUMERATION OK" 0 ;;
    already)  check "already enumerated (sdg)" 1; check "TREE[" 0 ;;
    normal)   check "not linux-usb mode" 1; check "TREE[" 0 ;;
  esac

  # v8: the dump runs in ALL modes (after the v5 sequence); the first
  # marker names the mode, then S1/S2/S3/S4/S5 + RPT-SCAN bracket every
  # step and the repeater is identified by its fd08/fd46 signature
  case $MODE in
    normal) v8mode="RPT-S0: enter (mode=normal)" ;;
    *)      v8mode="RPT-S0: enter (mode=linux-usb)" ;;
  esac
  check "$v8mode" 1
  check "RPT-S1:" 1
  [ "$MODE" = normal ] && check "RPT-S0: normal boot; waiting for a USB disk" 1
  if [ "$MODE" = norp ]; then
    check "RPT-ABSENT: no regmap debugfs dirs" 1
    check "RPT-S4: 0-07" 0
  else
    check "RPT-S2: spmi=[0-07 0-08]" 1
    check "RPT-S2: regmap=[0-07 0-08]" 1
    check "RPT-S2: candidates=[0-07 0-08]" 1
    check "RPT-S3: console=4; timeouts before=0; suppressing to 1" 1
    check "RPT-S3: console now=1" 1
    check "RPT-S4: 0-07: read started (bounded 55s)" 1
    check "RPT-S5: 0-07: read done size=828" 1
    check "RPT-SCAN: 0-07 lines=92 WRN: 08=80 46=80 51=0b 53=06 54=03 57=03 KEY: 50=00 52=00 55=00 56=00 58=00 59=00 5a=00 5b=00" 1
    check "RPT-S5: console restored to 4" 1
    check "RPT-NOHIT" 0
  fi
  if [ "$MODE" = norp ]; then
    check "RPT-DUMP: repeater" 0
  else
    check "RPT-DUMP: repeater regmap=0-07" 1
    check "RPT-B: fd50=00 fd51=0b fd52=00 fd53=06 fd54=03 fd55=00 fd56=00 fd57=03" 1
    check "RPT-B: fd58=00 fd59=00 fd5a=00 fd5b=00" 1
    check "RPT-KEY (never kernel-written; residue candidates): 50=00 52=00 55=00 56=00 58=00 59=00 5a=00 5b=00" 1
    check "08=80 46=80 51=0b 53=06 54=03 57=03" 1
    check "RPT-DONE: dump complete at" 1
    check "RPT-ABSENT" 0
    check "RPT-FAIL" 0
  fi
  [ "$MODE" = normal ] && check "RPT-NOTE" 0

  # reap leftovers (subshell + world); wait suppresses the "Terminated: 15"
  # job notification
  _p=$(cat "$R/tmp/armada-c.pid" 2>/dev/null)
  if [ -n "$_p" ]; then kill "$_p" 2>/dev/null; wait "$_p" 2>/dev/null; fi
  wait 2>/dev/null
  return 0
}

if [ $# -gt 0 ]; then
  for m in "$@"; do run_mode "$m"; echo; done
else
  for m in ok1400 okfull failall 110 nodev nopartner okforced escfail already normal norp; do
    run_mode "$m"; echo
  done
fi

echo "==== assertions: $FAILURES failure(s)"
[ "$FAILURES" -eq 0 ]
