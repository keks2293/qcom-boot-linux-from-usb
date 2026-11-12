# Lever C implementation: post-PDR xHCI rescan in the initramfs

Status: implemented and smoke-tested on a fake sysfs tree, 2026-11-12. Image
`diag/KERNEL.ci-a699dd6-dbgC` (not yet validated on hardware at the time of
writing). Design rationale: [SEQUENCER_TIMING_BEST_PRACTICE.md](SEQUENCER_TIMING_BEST_PRACTICE.md),
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
| base | `KERNEL.ci-a699dd6-dbgB` (CI `a699dd6` + patch 1400 + lever B) |
| result | `KERNEL.ci-a699dd6-dbgC`, 202 110 046 B, +2856 B |
| builder | `diag/build_dbgC_ci.py` (asserts magic, header diff, kernel identity, cpio round-trip) |

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
(`platform_device_alloc("xhci-hcd", PLATFORM_DEVID_AUTO)`), so:

- its quirk data lives on the platform device itself
  (`platform_device_add_data` @ `dwc3/host.c:199` → `dev_get_platdata` @
  `xhci-plat.c:430`) and **survives** the unbind (it is freed only at
  device release);
- `xhci_plat_remove`/`xhci_plat_probe` are symmetric, so rebind means a fresh
  HCRST and a new root-hub scan;
- the role switch, PHYs and the eUSB2 repeater stay alive and bound.

That is sufficient for the experiment (the port must be re-scanned after the
PDR) with no UAF risk.

## 3. Hook behaviour

The hook is sourced by `dracut-initqueue` on every loop iteration (~0.5 s), so it
is written to be idempotent and side-effect free after completion: pidfile
(`/tmp/armada-c.pid`) **and** done-marker (`/tmp/armada-c.done`), no top-level
`exit`, no `set -e/-u`, all variables prefixed `_ac_`.

Sequence:

| step | action |
|---|---|
| 0 | **normal-boot gate** — act only if the live FDT has `dr_mode = "host"` (`/sys/bus/platform/devices/a600000.usb/of_node/dr_mode`), the property ABL injects only in `linux usb` mode ([ABL_DR_MODE_HOST.md](ABL_DR_MODE_HOST.md)). A normal boot has no such property → no-op. |
| 0b | skip if a USB-backed `sd*` already exists |
| 1 | `udevadm settle`, then unbind `xhci-hcd.*` of `a600000.usb` — discard the pre-PDR scan |
| 2 | wait for the `PDR: Indication received from msm/adsp/charger_pd` line (≤30 s, 0.1 s steps; **no wall-clock delay**, event-driven) |
| 3 | `udevadm settle`, rebind → fresh bring-up + first scan, now post-PDR |
| 4 | verify ≤10 s; up to 3 tries; **hard stop if a new `Host halt failed, -110` appeared** (known qmp-combo defect, a retry cannot recover) |

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
  `basename` and a `printf` binary (the dash builtin is fine).

## 4. Console output

Everything goes through `/dev/kmsg` with a `<0>` level, so it is visible despite
`console=tty0 quiet`. Grep for `ARMADA-C:`.

| line | meaning |
|---|---|
| `ARMADA-C: not linux-usb mode (no dr_mode=host …); no rescan` | normal boot, nothing touched |
| `ARMADA-C: already enumerated (sdX) …; no rescan` | the pre-PDR scan already worked |
| `ARMADA-C: start up=Ns: xhci=… pdr=no scan-events=N` | sequence started |
| `ARMADA-C: unbind xhci-hcd.0.auto rc=0 up=Ns` | pre-PDR controller dropped |
| `ARMADA-C: PDR seen at Ns; rebinding` | event arrived (or `WARN: no charger_pd PDR in 30 s`) |
| `ARMADA-C: ENUMERATION OK at Ns (try N, scan-events=N): sdX` | **success** |
| `ARMADA-C: FAIL-NO-SCAN: no USB disk after N tries …` | controller alive, no disk → next lever |
| `ARMADA-C: FAIL-NO-DEV: no xhci-hcd device …` | ABL did not create the host controller |
| `ARMADA-C: FAIL: Host halt -110 after rebind …; no retry` | qmp-combo defect hit |

## 5. Smoke test (fake sysfs)

`diag/armada-usb-fix-c.sh` was validated against a synthetic sysfs tree with a
synchronous `unbind`/`bind` emulation (real sysfs writes are synchronous too):

| scenario | expected | result |
|---|---|---|
| `ok` | unbind → PDR → bind → disk appears | `ENUMERATION OK: sdg` |
| `already` | disk present before | `already enumerated (sdg); no rescan` |
| `fail` | no disk ever | 3 tries → `FAIL-NO-SCAN` |
| `110` | `Host halt failed, -110` after bind | `FAIL … no retry` (1 try only) |
| `normal` | no `dr_mode` property | `not linux-usb mode …`, controller stays bound |

Re-sourcing the hook after completion is a no-op in all scenarios.

## 6. Interpretation of the result

- **`ENUMERATION OK`** → ordering (pre- vs post-PDR scan) was the whole bug;
  lever C is the fix and belongs in the initramfs of PR #704.
- **`FAIL-NO-SCAN`** with the controller alive → ordering is necessary but not
  sufficient; the next lever is the full chain (repeater → hsphy → dwc3), and it
  must be preceded by unbinding `pmic_glink.ucsi.0` so UCSI re-fetches a fresh
  role switch instead of keeping a stale one.
- **`FAIL: Host halt -110`** → the qmp-combo defect; retries are pointless, the
  rebind point/order has to change.
