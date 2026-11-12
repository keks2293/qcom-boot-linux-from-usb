# Lever C implementation: post-PDR xHCI rescan in the initramfs

Status: **v2 (dbgC2) built and smoke-tested, 2026-11-12; awaiting the
decisive hardware run.** The v1 image (`dbgC`) was run on hardware on
2026-11-12 and failed with `FAIL-NO-DEV` at 3.3 s — a **race in the hook, not
a hardware verdict** (the v1 hook was written for a forced-host kernel; on the
patch-1400 kernel the `xhci-hcd` device does not exist until the post-PDR role
flip at ~5.5 s). v2 removes the race. Design rationale:
[SEQUENCER_TIMING_BEST_PRACTICE.md](SEQUENCER_TIMING_BEST_PRACTICE.md),
evidence: [FULL_SYSTEM_PREPLUG_SOURCE_ROLE.md](FULL_SYSTEM_PREPLUG_SOURCE_ROLE.md).

## 1. What is added to the image

Exactly **one** file inside the dracut initramfs:

```
var/lib/dracut/hooks/initqueue/91-armada-usb-fix-c.sh
```

Kernel, DTB (`second`), the early cpio and the pre-existing lever-B hook are
byte-identical to the base image. In the Android boot header only
`ramdisk_size` (offset 16) and the SHA1 id (offset 576) differ.

| | |
|---|---|
| base (v1) | `KERNEL.ci-a699dd6-dbgB` (CI `a699dd6` + patch 1400 + lever B v1) |
| result (v1) | `KERNEL.ci-a699dd6-dbgC`, 202 110 046 B, md5 `506cb36f9eadd0459d064ac2f4883927` |
| base (v2) | `KERNEL.ci-a699dd6-dbgB2` (same base + lever B **v2**: the EAGAIN-suppressed read, see §7) |
| result (v2) | `KERNEL.ci-a699dd6-dbgC2`, 202 111 747 B, md5 `ab8621850dabacb25e851f8b19f8f7ac`, sha256 `9fa2b591cad49791d822c62763d93d198a27a3cdf8e9ae046fe4cb5a68c92673` |
| builders | `diag/build_dbgB2_ci.py`, `diag/build_dbgC2_ci.py` (assert magic, header diff, kernel identity, hook round-trip; the dbgC2 builder additionally asserts the base's lever-B hook is byte-identical to `diag/armada-ulog-b2.sh`) |

The in-image hook names did not change between versions.

## 2. Scope: only `xhci-hcd`, never `dwc3-qcom`

The first draft of lever C said "unbind/rebind `dwc3-qcom`/xHCI". That is
**wrong and dangerous**, and the implementation deliberately does not do it:

- The USB role-switch device is registered by the **dwc3 core** on `dwc->dev`
  (`drivers/usb/dwc3/core.c`, `dwc3_setup_role_switch()`).
- UCSI takes and holds a reference to it (`drivers/usb/typec/ucsi/ucsi.c:1837`,
  `fwnode_usb_role_switch_get`) and calls `usb_role_switch_set_role()` on
  **every** connector change (`ucsi.c:1376`, `ucsi.c:1958`).
- `usb_role_switch_unregister()` → `device_unregister()` releases the
  devm-allocated `struct dwc3` on unbind. A post-PDR UCSI attach would then call
  `set_role()` through a stale pointer into freed memory — a use-after-free.

`xhci-hcd` is a **separate platform device** created by `dwc3/host.c`
(`platform_device_alloc("xhci-hcd", PLATFORM_DEVID_AUTO)` @ `host.c:147`,
`xhci->dev.parent = dwc->dev` @ `host.c:153`), so:

- its quirk data lives on the platform device itself
  (`platform_device_add_data` @ `dwc3/host.c:199` → `dev_get_platdata` @
  `xhci-plat.c:430`) and **survives** the unbind (it is freed only at
  device release);
- `xhci_plat_remove`/`xhci_plat_probe` are symmetric, so rebind means a fresh
  HCRST and a new root-hub scan;
- the role switch, PHYs and the eUSB2 repeater stay alive and bound.

That is sufficient for the experiment (the port must be re-scanned after the
PDR) with no UAF risk.

## 3. The v1 hardware run (2026-11-12): a hook race, not a hardware verdict

Pre-plug, normal orientation, `linux usb`, zero actions. First console line:

```
[3.305440] ARMADA-C: FAIL-NO-DEV: no xhci-hcd device for a600000.usb at 3s
```

The hook finished on its **first** invocation: no unbind, no PDR wait, no
rebind. Why: the image was built on kernel `a699dd6` **with patch 1400**
("ignore `dr_mode=host` when `usb-role-switch` is present"). With it, DWC3
probes in OTG mode and the `xhci-hcd.0.auto` platform device is created only
when the UCSI role flips to HOST — **after** the charger_pd PDR. In the run the
flip happened at 5.48 s (`data=[host] power=[source]`), ~2 s after the hook
gave up. The v1 hook was written for a forced-host kernel (where `xhci-hcd`
exists from ~2.7 s) and treated "no device at start" as fatal.

The rest of the log is **identical to the successful full-system control E**:
`otg enable: 1` / `otg source = 1` at 5.47 s (PPM enabled the OTG VBUS),
`partner=yes data=[host] power=[source]` at 5.48 s,
`GET_CONNECTOR_STATUS: ConnectStatus=1, ConnectPartnerType=2, USB=1` at 7.52 s,
the known source-role fingerprint (`skip checking usb charging type while usb
is sourcing`, `icm_ncp_stby`, SM=2) at 17.77 s, VBUS ~5.06 V. The
power/role chain is healthy; only the hook's expectation was wrong.
(`usb_type=[Unknown] online=0` is the charger-**input** mirror, not the OTG
output — `otg source=1` directly refutes the old "no VBUS" reading of dbg1400.)

**Timing correction:** the first scan must be post-**OTG-VBUS-enable** (5.47 s
in the run), not merely post-PDR (3.5 s). That gap (~2 s) also explains the
dbg1400 run: the role flip was post-PDR, but the early scan could have outrun
the otg-enable. In control E the first scan was at 12.787 s, 46 ms **after**
the otg-enable at 12.741 s.

## 4. Hook behaviour (v2)

The hook is sourced by `dracut-initqueue` on every loop iteration (~0.5 s), so
it is written to be idempotent and side-effect free after completion: pidfile
(`/tmp/armada-c.pid`) **and** done-marker (`/tmp/armada-c.done`), no top-level
`exit`, no `set -e/-u`, all variables prefixed `_ac_`, the whole sequence runs
in a background subshell so the initqueue loop is never blocked. Every step is
announced **before** the possibly-blocking sysfs write, re-printed at most
every 5 s (heartbeat), and `hook loaded` is printed on the first sourcing, so a
verdict survives a photo taken long after the fact.

Sequence:

| step | action |
|---|---|
| 0 | **normal-boot gate** — act only if the live FDT has `dr_mode = "host"` (`/sys/bus/platform/devices/a600000.usb/of_node/dr_mode`), the property ABL injects only in `linux usb` mode ([ABL_DR_MODE_HOST.md](ABL_DR_MODE_HOST.md)); patch 1400 ignores the value but **leaves the property in the FDT**, so the gate still works. A normal boot has no such property → no-op. |
| 0b | skip if a USB-backed `sd*` already exists |
| 1 | `udevadm settle`; if `xhci-hcd.*` of `a600000.usb` **exists** (forced-host kernel), unbind it to discard the pre-PDR scan. If it is **absent** (patch-1400 kernel) that is **not** an error — step 4 waits for it. |
| 2 | wait for the `PDR: Indication received from msm/adsp/charger_pd` line (≤30 s, 0.1 s steps, event-driven) |
| 3 | wait for typec `port0` `power_role=[source]` **and** `data_role=[host]` (≤15 s) — the proxy for "PPM has enabled the OTG VBUS" (step 3 of the v1 run: the scan must be post-VBUS, not only post-PDR) |
| 4 | wait for the `xhci-hcd.*` device to appear (≤10 s; created by the role flip) — never appears ⇒ `FAIL-NO-DEV` (the role flip itself did not happen: UCSI/partner, a **new class**) |
| 5 | if the first post-flip scan already produced a USB disk → `ENUMERATION OK (first post-PDR scan)` **without a rebind** |
| 6 | otherwise unbind+bind (fresh HCRST + new root-hub scan), verify ≤10 s; up to 3 tries; **hard stop on a *new* `Host halt failed, -110`** (baseline count taken before any unbind, checked **inside** the wait loop → stop immediately; known qmp-combo defect, a retry cannot recover) |

The sysfs role attributes carry only the **current** role in brackets
(`[source] sink` / `source [sink]`; `[host] device` / `host [device]` —
`drivers/usb/typec/class.c:1794-1804`, `:1846-1856`), so the substring checks
for `[source]` / `[host]` are exact.

### Gates that matter

- **Normal boots must stay inert.** In a normal boot the PDR reaches userspace
  at ~12 s from the real root, i.e. after `switch_root`; an "unbind early, wait
  for PDR" hook would leave the controller unbound forever. Hence the
  `dr_mode=host` gate, not a timing guess.
- **USB disk detection must be USB-backed.** The internal UFS is `sda` too
  (`YMUS8B4TF1D1C1`, 115 G in our logs), so a plain `sd*` test is wrong. The
  hook resolves each `/sys/block/sd*` to a physical path and requires it to
  contain `/usb`.
- **No `readlink -f`.** It is a coreutils extension and is not guaranteed in the
  initramfs; the hook uses the shell builtin `( cd -P "$1" && pwd -P )`.
  Verified present in the initramfs: `dmesg`, `udevadm`, `sleep`, `grep`, `tr`,
  `cut`, `ls`, `cat`, `sed`, `tail`, `mount`. **Absent:** `head`, `dirname`,
  `basename` and a `printf` binary (the dash builtin is fine). `sleep 0.1` is
  fine (coreutils `sleep` in the image).

## 5. Console output

Everything goes through `/dev/kmsg` with a `<0>` level, so it is visible despite
`console=tty0 quiet`. Grep for `ARMADA-C:`.

| line | meaning |
|---|---|
| `ARMADA-C: hook loaded up=Ns` | first sourcing, the hook runs at all |
| `ARMADA-C: not linux-usb mode (dr_mode='…') …; no rescan` | normal boot, nothing touched |
| `ARMADA-C: already enumerated (sdX) …; no rescan` | the pre-PDR scan already worked |
| `ARMADA-C: start up=Ns: dr_mode='host' xhci=ABSENT (patch-1400 kernel …)` / `xhci=xhci-hcd.0.auto (forced-host: unbind …)` | sequence started, either controller state handled |
| `ARMADA-C: PDR seen at Ns` / `WARN: no charger_pd PDR in 30 s` | PDR wait outcome |
| `ARMADA-C: source+host at Ns (power='[source] sink' data='[host] device')` / `WARN: no source+host role in 15 s …` | OTG-VBUS proxy outcome |
| `ARMADA-C: ENUMERATION OK (first post-PDR scan) at Ns: sdX` | the role flip's own scan worked — **success, no rebind needed** |
| `ARMADA-C: ENUMERATION OK at Ns (try N, scan-events=N): sdX` | **success** via the guaranteed rebind |
| `ARMADA-C: FAIL-NO-SCAN: no USB disk after N tries …` | controller alive, no disk → next lever |
| `ARMADA-C: FAIL-NO-DEV: xhci-hcd never appeared after PDR …` | the role flip itself did not happen (UCSI/partner) — **new class** |
| `ARMADA-C: FAIL: Host halt -110 after rebind …; no retry` | qmp-combo defect hit |
| `ARMADA-C: hb up=Ns :: <last step>` | heartbeat (≤1 per 5 s) |

## 6. Smoke test (fake sysfs, `diag/fake-test-c2.sh`)

World-driven harness: a background process plays the timeline (PDR @1 s,
typec `source+host` @2 s, `xhci-hcd` @2.2 s, disk on the first scan or only
after the rebind, depending on the mode); the role files use the real kernel
formats; `dracut-initqueue` is emulated by **sourcing** the
path-redirected hook every 0.5 s until the done-marker appears (pidfile guard,
heartbeat and idempotency exercised; the liveness check needs a fake
`/proc/<pid>` on macOS — the real `/proc` on the device works as-is). 8/8:

| mode | world | result |
|---|---|---|
| `ok1400` | patch-1400 kernel: no `xhci-hcd` at start; disk from the first post-flip scan | `ENUMERATION OK (first post-PDR scan): sdg` |
| `okrebind` | same, but the first scan finds nothing; disk only after the rebind | `ENUMERATION OK (try 1): sdg` |
| `okforced` | forced-host kernel: `xhci-hcd` bound from t=0 | start-unbind → `ENUMERATION OK (try 1): sdg` |
| `fail` | rebinds never produce a disk | 3 tries → `FAIL-NO-SCAN: no USB disk after 3 tries` |
| `110` | `Host halt failed, -110` after the rebind | immediate `FAIL … no retry` (1 try) |
| `nodev` | `xhci-hcd` never appears | `FAIL-NO-DEV: xhci-hcd never appeared after PDR` |
| `already` | USB disk present at start | `already enumerated (sdg); no rescan`, controller stays bound |
| `normal` | no `dr_mode=host` | `not linux-usb mode …; no rescan`, controller stays bound |

Re-sourcing the hook after completion is a no-op in all scenarios.

## 7. The lever-B v2 fix (EAGAIN console noise)

The dbgC run printed, on the console and in the dmesg tail:

```
90-armada-ulog-b.sh: line 82: read: 0: read error: Resource temporarily unavailable
```

Cause (code, not the `trace_pipe` read): `qcom_battmgr`'s
`qcom_battmgr_usb_get_property()` returns `-EAGAIN` while `!service_up`
(`drivers/power/supply/qcom_battmgr.c:1006-1007`); `service_up` is set only
after the ADSP/BattMngr service is up (~PDR @3.5 s), and the lever-B hook starts
polling `qcom-battmgr-usb/*` in initqueue (~2.7–4 s), i.e. before that. The
value already fell back to `?` via `|| _ab_v='?'`; the only harm was the shell
error line. Fix: `2>/dev/null` on that one read
(`diag/armada-ulog-b2.sh`); the image is `KERNEL.ci-a699dd6-dbgB2` (202 107 571
B, md5 `62c84617968a0adfc97a5e2926568c98`).

## 8. Interpretation of the dbgC2 result

- **`ENUMERATION OK`** (either variant) → ordering (pre- vs post-PDR/VBUS scan)
  was the whole bug; lever C is the fix and belongs in the initramfs of PR #704
  (dracut module), after which the plan is an OS-root clone and boot from the
  stick.
- **`FAIL-NO-SCAN`** with the controller alive → ordering is necessary but not
  sufficient; the next lever is the full chain (repeater → hsphy → dwc3), and it
  must be preceded by unbinding `pmic_glink.ucsi.0` so UCSI re-fetches a fresh
  role switch instead of keeping a stale one.
- **`FAIL: Host halt -110`** → the qmp-combo defect; retries are pointless.
  Backport the upstream fix (Oleg Keri, LKML 2026-09-16, "keep the Type-C
  callbacks off unclocked registers") instead.
- **`WARN: no charger_pd PDR in 30 s`** → check the ADSP drop-in / remoteproc in
  the initramfs (without it the PDR does not reach the initramfs at all).
- **`FAIL-NO-DEV`** → the role flip itself did not happen (UCSI/partner); a new
  failure class, lever C did not get to run.

Expected timeline of a successful run (from the v1 run and control E):
PDR ~3.5 s → `source+host` ~5.5 s → `xhci-hcd` ~5.5–5.6 s → first scan (or
rebind ~5.6 s) → `ENUMERATION OK` ~6–7 s — inside the ~30 s PPM window and
before any runtime role switch, so the `-110` bug is not in the path.

## 9. Run protocol

Flash `KERNEL.ci-a699dd6-dbgC2` to the **spare** stick (verify md5
`ab8621850dabacb25e851f8b19f8f7ac` on both sides), stick **pre-plugged in the
normal orientation** (reverse orientation leaves the data path unrouted), ABL
→ `linux usb`, **zero actions**, read the `ARMADA-C:` lines.
