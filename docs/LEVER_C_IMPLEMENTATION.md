# Lever C implementation: post-PDR xHCI rescan in the initramfs

Status: **v3 (dbgC3) ran on hardware for the first time (run 4, 2026-11-12):
verdict `FAIL-NO-SCAN` with a live controller — a new, strong result.** The
v1 image (`dbgC`) was run on hardware **three** times on 2026-11-12 — each
time it failed with `FAIL-NO-DEV` at ~3.1 s, a **race in the hook, not a
hardware verdict** (the v1 hook was written for a forced-host kernel; on the
patch-1400 kernel the `xhci-hcd` device does not exist until the post-PDR role
flip). Runs 2 and 3 turned out to be the v1 image again (the stick's `KERNEL`
was byte-identical to `dbgC` each time; v2/v3 were never flashed) — so an
image must be md5-verified **after** flashing. v2 removed the race; v3 adds a
one-shot device-tree snapshot so that a failure can no longer leave "the
xhci controller was created and scanned but found nothing" indistinguishable
from "the xhci controller was never created at all". Run 4 (genuine dbgC3)
confirmed case (A): controller alive, root hub up, **three fresh post-PDR
scans (two post-VBUS) found nothing** (`scan-events=0`) — the "scan ordering
is the whole bug" hypothesis is **refuted in the strong form**. Empirical
gate correction: the typec roles are **not** a proxy for VBUS (roles are set
at UCSI port registration, ~1.8 s **before** the PPM enables the OTG VBUS).
Next lever: the **full chain** reset (UCSI → xhci → dwc3 unbind, dwc3 → UCSI
rebind), code-verified in §9. The manual full-chain test is **impossible**
(the emergency shell takes no input on this hardware, confirmed
2026-11-12) ⇒ v4 (dbgC4) is built with the **unconditional**
auto-escalation: it gates the first rebind on `port0-partner` (the real
post-VBUS marker, §3.3), dumps `orientation` / `partner` / the xhci → usbN
mapping, and on `FAIL-NO-SCAN` escalates xhci-only → full chain, printing
the beta-1 / beta-2 verdict (`ENUMERATION OK (full-chain)` vs
`FAIL-NO-SCAN-FULL`). Run 5 = dbgC4, protocol in §10.3. Design rationale:
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
| base (v2/v3) | `KERNEL.ci-a699dd6-dbgB2` (same base + lever B **v2**: the EAGAIN-suppressed read, see §7) |
| result (v2) | `KERNEL.ci-a699dd6-dbgC2`, 202 111 747 B, md5 `ab8621850dabacb25e851f8b19f8f7ac`, sha256 `9fa2b591cad49791d822c62763d93d198a27a3cdf8e9ae046fe4cb5a68c92673` — **never booted on hardware** (the second run was the v1 image again, §3.1) |
| result (v3) | `KERNEL.ci-a699dd6-dbgC3`, 202 112 128 B, md5 `9969edaff95d75c4766d84919d82cbb7`, sha256 `81046641e053cf3cdc3e788f4d0ff4d90e9e48a92300a6103a1242e539517e12` — ran in run 4 (§3.3) |
| result (v4) | `KERNEL.ci-a699dd6-dbgC4`, 202 114 227 B, md5 `5704495b563cd991102264581eb4e9e7`, sha256 `66111bd8773b7f55211142f91d92f14038fc802ba44894d60b0ee512f0d7a9a3` — **the image to flash for run 5** (partner gate + dump additions + unconditional full-chain escalation, §10.3) |
| builders | `diag/build_dbgB2_ci.py`, `diag/build_dbgC2_ci.py`, `diag/build_dbgC3_ci.py`, `diag/build_dbgC4_ci.py` (assert magic, header diff, kernel identity, hook round-trip; the dbgC2/dbgC3/dbgC4 builders additionally assert the base's lever-B hook is byte-identical to `diag/armada-ulog-b2.sh` and the version-specific hook markers) |

The in-image hook names did not change between versions. Each image keeps a
**distinct filename** on purpose: after the second run turned out to be the
v1 image, the file name on the stick became a self-identifying provenance
marker (plus the md5 check after flashing).

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

## 3. The hardware runs (2026-11-12): runs 1–3 = a hook race, not a hardware verdict; run 4 = the genuine verdict

### 3.0 Run 1

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

### 3.1 Run 2 (the "decisive" run that was not): the stick still held the v1 image

The second run — prepared to flash `dbgC2` — produced a **deterministic
repeat** of run 1: `ARMADA-C: FAIL-NO-DEV: no xhci-hcd device for a600000.usb
at 3s` at **3.135 s**, no further `ARMADA-C:` lines, and the PPM/port side
again identical to control E (`otg enable: 1` / `otg source = 1` at 5.27 s,
`power=[source] data=[host] partner=yes` from 5.29 s,
`GET_CONNECTOR_STATUS: ConnectStatus=1, PowerDirection=1,
ConnectPartnerType=2, USB=1` at 7.32 s, the known source-role fingerprint at
17.57 s, VBUS ~5.06 V stable to 66+ s).

**Which image was actually flashed — verified, not inferred:** the stick's
`/Volumes/ARMADA/KERNEL` (202 110 046 B) has md5
`506cb36f9eadd0459d064ac2f4883927`, **byte-identical to
`KERNEL.ci-a699dd6-dbgC` (v1)**. The v2 image
(md5 `ab8621850dabacb25e851f8b19f8f7ac`) was never on the stick, so it was
**never booted on hardware**. Corroborating evidence (all consistent with v1,
all impossible for v2): the v1 `FAIL-NO-DEV … at 3s` phrasing (v2 says
"never appeared after PDR"), the absence of the v2 `hook loaded` / heartbeat
lines, and the still-present lever-B console error
`line 82: read: 0: read error: Resource temporarily unavailable` (the v2
image carries lever-B v2 with the `2>/dev/null` fix, §7).

**Consequences.** (1) The lever-C test has not yet happened; the mechanism is
neither confirmed nor refuted — two runs died in the same v1 hook race.
(2) Both runs leave the same **blind spot**: with a quiet console and a dead
hook, it is impossible to tell "the xhci controller was created by the
post-PDR flip, a scan ran, and found nothing" from "the xhci controller was
never created at all" — the two have different next levers (§8). v3 exists
to close exactly this gap. (3) Run protocol now includes an **md5 check after
flashing** (§10).

### 3.2 Run 3: the third bit-identical v1 repeat (the stick was still never re-flashed)

Prepared after v3 (dbgC3) was built, the third run produced the **third
bit-identical v1 repeat**: `ARMADA-C: FAIL-NO-DEV: no xhci-hcd device for
a600000.usb at 3s` at 3.299 s, PPM/port side again 1:1 with control E. The
stick's `KERNEL` md5 was checked after the run and was **again**
`506cb36f9eadd0459d064ac2f4883927` (v1 `dbgC`) — dbgC3 had been built but
never written to this stick. Determinism ×3 (PDR ~3.5 s → otg-enable
~5.3–5.5 s → roles ~5.5 s → the known source-role fingerprint) confirmed the
runs are reproducible, so a new image would yield a comparable result.
dbgC3 was then flashed (12 ноя 13:27; md5 `9969edaff95d75c4766d84919d82cbb7`
verified on **both** sides, AppleDouble `._*` cleaned, `KERNEL.md5` updated,
volume ejected).

### 3.3 Run 4 (the first genuine lever-C test): ⭐ `FAIL-NO-SCAN` with a live controller

Pre-plug, normal orientation, `linux usb`, zero actions. The v2/v3 logic ran
exactly as designed:

```
ARMADA-C: hook loaded up=3s                                  @3.31
ARMADA-C: start up=3s: dr_mode='host' xhci=ABSENT (patch-1400 kernel …) pdr=no   @3.38
ARMADA-C: PDR seen at 3s                                     @3.54
ARMADA-C: source+host at 3s (power='[source] sink' data='[host] device')        @3.66
ARMADA-C: xhci=xhci-hcd.2.auto at 3s: checking the first post-flip scan         @3.67
  (try 1: unbind+bind rc=0 @3.70/3.72 — **pre-VBUS**)
[  5.44] otg enable: 1 / otg source = 1                       (PPM OTG VBUS on)
[  7.49] GET_CONNECTOR_STATUS: ConnectStatus=1, PowerDirection=1, ConnectPartnerType=2, USB=1
ARMADA-C: TREE[t10] up=10s …                                  @10.1
ARMADA-C: no disk after try 1 at 16s: rebind retry (scan-events=0)              @16.39  (try 2, post-VBUS)
ARMADA-C: no disk after try 2 at 29s: rebind retry (scan-events=0)              @29.18  (try 3, post-VBUS)
ARMADA-C: FAIL-NO-SCAN: no USB disk after 3 tries …            ~42 s
```

No `Host halt failed, -110` at any point (the rebind is safe and repeatable;
the qmp-combo defect is not in the path). The `TREE[t10]` dump:

```
a600000.usb: [of_node … usb_role xhci-hcd.2.auto]     (controller ALIVE, xhci bound)
role /sys/class/usb_role/a600000.usb-role-switch: [host]
/sys/block: [loop0…7 mmcblk0 sda sdb sdc sdd sde sdf]  (UFS only, no USB sd*)
usb: [1-0:1.0 2-0:1.0 usb1 usb2]                      (two root hubs, NO port-1 child)
```

**Verdict: case (A) confirmed, case (B) excluded.** The controller is alive,
both root hubs are up, and **three fresh scans — two of them post-VBUS,
~11 s and ~24 s after the PPM enabled the OTG VBUS — saw no connect event at
all** (`scan-events=0`). Yet the PPM *sees* the stick (`ConnectPartnerType=2,
USB=1`), the OTG VBUS is out (`otg source=1`, ~5.06 V) and the role is host.
The pre-plugged drive is therefore not being presented electrically on the
bus: the residual blocker is the **data path** — either state left in dwc3 /
UCSI / PHY below the xhci layer, or orientation / repeater / the power switch.

**⭐ Empirical gate correction (for v4).** The v2 assumption "typec `port0`
`[source]`+`[host]` = PPM enabled the OTG VBUS" is **wrong**: the hook saw
source+host at **3.66 s** — UCSI sets the roles when it registers the port
(`drivers/usb/typec/ucsi/ucsi.c:1837,1958`) — while the PPM actually enabled
the OTG VBUS (`otg enable: 1`) at **5.44 s**, ~1.8 s later. The `xhci-hcd`
device appeared at 3.67 s right after the role set, i.e. it is created by the
**role flip, not by the VBUS**. Try 1 (3.7 s) was pre-VBUS and doomed by
timing; tries 2 and 3 (16.4 s / 29.2 s) were post-VBUS and still
`scan-events=0` — so scan ordering is necessary but not sufficient. The
correct gate for the first rebind is the appearance of **`port0-partner`**
(~5.4 s; `ucsi_register_partner()` at `ucsi.c:1944`, after
`GET_CONNECTOR_STATUS`) or the ULog line `otg enable: 1`.

**Note:** `wait_disk 100` ("10 s") costs ~12.7 s of wall clock in practice
(per-iteration cost: the six UFS-LUN `sda`–`sdf` resolved via `cd -P`/`pwd -P`
plus a forked `dmesg | grep -c` each time) — that is why the tries ended at
16.4 s / 29.2 s. v4 will shorten the wait.

## 4. Hook behaviour (v2/v3; v3 = v2 byte-for-byte plus the tree dump)

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
| 3 | wait for typec `port0` `power_role=[source]` **and** `data_role=[host]` (≤15 s) — **v4 correction:** this is *not* a reliable proxy for "PPM has enabled the OTG VBUS" (run 4, §3.3: the roles appear at 3.66 s, ~1.8 s **before** `otg enable: 1` at 5.44 s; v4 gates on `port0-partner` / `otg enable: 1` instead) |
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

### 4.1 v3 addition: the one-shot device-tree dump (`_ac_tree`)

The dump answers the question the two v1 runs could not: **was the xhci
controller created at all, and if so, what did its scan see?** It prints four
tagged, grep-able lines (`ARMADA-C: TREE[<tag>] up=Ns …`):

1. children of `a600000.usb` — `ls /sys/bus/platform/devices/a600000.usb/`
   (is `xhci-hcd.*` there at all?);
2. the usb-role-switch state — `/sys/class/usb_role/*/role` (a single word
   `host`/`device`/`none`, per `role_show` in `drivers/usb/roles/class.c`;
   is the switch at `host` after the flip?);
3. `/sys/block/` — is there a USB `sd*` (the UFS `sda` is there always)?;
4. the host-side USB bus — `usb1` / `1-1` / `1-1:1.0`: **`lsusb` is not in
   the initramfs** (verified against the CI cpio entry list), so the hook
   uses a `command -v lsusb` branch with the fallback
   `ls /sys/bus/usb/devices/`.

Fire points:

| tag | when |
|---|---|
| `t10` | **once at up = 10 s** while the sequence is still running (called from every wait loop: PDR / role / xhci / rebind-wait; a once-flag guarantees a single dump) |
| `WARN-nopdr`, `WARN-norole` | the 30 s PDR / 15 s role waits time out |
| `NO-DEV` | `xhci-hcd` never appeared after the PDR (the role flip did not happen) |
| `halt-110` | a new `Host halt failed, -110` after a rebind |
| `NO-SCAN` | no USB disk after 3 rebind tries |
| `OK` | after either success variant (the tree then shows `usb1 1-1 1-1:1.0` and the disk) |

The discriminator: case (A) "created, scanned, found nothing" ⇒
`a600000.usb: [… xhci-hcd.0.auto]` and `usb: [usb1]` (a live root hub, no
port-1 child); case (B) "never created" ⇒ `a600000.usb: [of_node]` and
`usb: []`. Everything is read-only sysfs plus `ls`/`tr`/`command` (all
verified present); the dump adds no new sysfs writes and cannot affect the
sequence.

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
| `ARMADA-C: TREE[t10] up=Ns …` | v3: the device-tree snapshot at up = 10 s (4 lines: `a600000.usb:` children, `role …: [host/device/none]`, `/sys/block:`, `usb:` or `lsusb:` bus listing) — see §4.1 |
| `ARMADA-C: TREE[NO-DEV / NO-SCAN / halt-110 / WARN-…] …` | v3: the same snapshot on the corresponding timeout/failure path (verdict line follows) |
| `ARMADA-C: TREE[OK] …` | v3: the snapshot after a successful enumeration |
| `ARMADA-C: hb up=Ns :: <last step>` | heartbeat (≤1 per 5 s) |

## 6. Smoke test (fake sysfs, `diag/fake-test-c3.sh`)

World-driven harness: a background process plays the timeline (PDR @1 s,
typec `source+host` @2 s, `xhci-hcd` @2.2 s, disk on the first scan or only
after the rebind, depending on the mode); the role files use the real kernel
formats (typec port attributes with only the **current** role bracketed; the
usb-role-switch `role` attribute as a single word, per
`drivers/usb/roles/class.c`); the host-side USB bus is faked faithfully
(`usb1` appears when the xhci driver binds, `1-1`/`1-1:1.0` when a scan finds
the stick, and an xhci unbind tears `usb1` down); a fake `date` reports
seconds elapsed since harness start so the hook's absolute `up >= 10` tree-dump
gate fires in fake time exactly like on the device. `dracut-initqueue` is
emulated by **sourcing** the path-redirected hook every 0.5 s until the
done-marker appears (pidfile guard, heartbeat and idempotency exercised; the
liveness check needs a fake `/proc/<pid>` on macOS — the real `/proc` on the
device works as-is). 8/8, plus per-mode **assertions** on the verdict and the
TREE lines (non-zero exit on any failure):

| mode | world | result (verdict + v3 tree dump) |
|---|---|---|
| `ok1400` | patch-1400 kernel: no `xhci-hcd` at start; disk from the first post-flip scan | `ENUMERATION OK (first post-PDR scan): sdg` + `TREE[OK] usb: [usb1 1-1 1-1:1.0]` |
| `okrebind` | same, but the first scan finds nothing; disk only after the rebind | `ENUMERATION OK (try 1): sdg` + `TREE[OK] usb: [usb1 1-1 1-1:1.0]` |
| `okforced` | forced-host kernel: `xhci-hcd` bound from t=0 | start-unbind → `ENUMERATION OK (try 1): sdg` + `TREE[OK] usb: [usb1 1-1 1-1:1.0]` |
| `fail` | rebinds never produce a disk | 3 tries → `FAIL-NO-SCAN` + `TREE[t10] usb: [usb1]` (**case A**: controller alive, root hub up, no port-1 child) + `TREE[NO-SCAN]` |
| `110` | `Host halt failed, -110` after the rebind | immediate `FAIL … no retry` (1 try) + `TREE[halt-110] usb: [usb1]` |
| `nodev` | `xhci-hcd` never appears | `FAIL-NO-DEV` + `TREE[t10] a600000.usb: [of_node]`, `usb: []` (**case B**: controller never created — the exact blind spot the dump closes) + `TREE[NO-DEV]` |
| `already` | USB disk present at start | `already enumerated (sdg); no rescan`, controller stays bound, **no** TREE lines |
| `normal` | no `dr_mode=host` | `not linux-usb mode …; no rescan`, controller stays bound, **no** TREE lines |

Re-sourcing the hook after completion is a no-op in all scenarios; the
`t10` dump fires at most once per run (verified in the long-running
`fail`/`nodev` modes, where it appears during a wait loop, not on every
iteration).

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

## 8. Interpretation of the runs (decision tree state after run 4)

The v3 tree dump makes the two failure classes directly distinguishable on the
screen (the `usb:` line is the key): **`usb: [usb1]`** = case A, the xhci
controller exists and a scan ran but found nothing; **`usb: []`** (+
`a600000.usb: [of_node]`, no `xhci-hcd.*`) = case B, the controller was never
created, i.e. the post-PDR role flip itself did not happen. The `role
…: [host]` line cross-checks the usb-role-switch state, and the `/sys/block:`
line shows whether any `sd*` appeared that the USB-backed detection missed.
**Run 4 returned case (A): `usb: [1-0:1.0 2-0:1.0 usb1 usb2]`, role `[host]`,
no port-1 child — `FAIL-NO-SCAN` with a live controller** (§3.3).

- ~~`ENUMERATION OK`~~ (either variant) → not triggered.
- **`FAIL-NO-SCAN` with the controller alive — GIVEN (run 4).** Ordering
  (pre- vs post-PDR/VBUS scan) is **necessary but not sufficient**: three
  fresh scans, two of them post-VBUS, found nothing. The next lever is the
  **full chain** reset — UCSI → xhci → dwc3 unbind, dwc3 → UCSI rebind,
  code-verified in §9 — preceded by unbinding the UCSI auxiliary driver so
  UCSI re-fetches a fresh role switch instead of keeping a stale reference.
  Two sub-branches: (β1) the manual full-chain rebind in the emergency shell
  enumerates the stick → the residual blocker was state left in dwc3/UCSI and
  v4 (dbgC4) automates the escalation; (β2) even the full chain produces zero
  events → the blocker is below dwc3 (PHY / eUSB2 repeater / PPM data path /
  plug orientation) and is chased item by item.
- ~~`FAIL: Host halt -110`~~ → not triggered (rebind rc=0 ×3). If it ever
  appears: the qmp-combo defect; retries are pointless. Backport the upstream
  fix (Oleg Keri, LKML 2026-09-16, "keep the Type-C callbacks off unclocked
  registers") instead.
- ~~`WARN: no charger_pd PDR in 30 s`~~ → not triggered (PDR at 3.54 s).
- ~~`FAIL-NO-DEV`~~ → not triggered (the flip happened; xhci appeared at
  3.67 s).

Cheap checks before the full chain (run 5 protocol, §10): (1) the port
**orientation** (`/sys/class/typec/port0/orientation`, values
`unknown`/`normal`/`reverse` per `drivers/usb/typec/class.c:1678-1682`) — a
`reverse` orientation can leave the data path unrouted for minutes and is
exactly consistent with live CC/VBUS + no enumeration (test D); if reverse,
flip the plug and re-run dbgC3 first; (2) the **stick LED** — does the VBUS
that the PPM reports as out actually reach the stick.

Expected timeline of a successful run (from the v1 run and control E):
PDR ~3.5 s → `source+host` ~5.5 s → `xhci-hcd` ~5.5–5.6 s → first scan (or
rebind ~5.6 s) → `ENUMERATION OK` ~6–7 s — inside the ~30 s PPM window and
before any runtime role switch, so the `-110` bug is not in the path.

## 9. The full-chain reset (code-verified; the next lever)

Scope expansion beyond §2: if the xhci-only rebind cannot make the port re-scan
a pre-plugged drive, the next step resets the **whole** stack. Everything below
is verified against the source (kernel v7.2.6), with the exact sysfs paths for
the manual test in the emergency shell.

### 9.1 The drivers and their sysfs locations (correction: UCSI is an *auxiliary* driver)

| component | driver | driver name | device | sysfs unbind/bind |
|---|---|---|---|---|
| UCSI over PMIC-GLINK | `drivers/usb/typec/ucsi/ucsi_glink.c:480-487` — an **auxiliary** driver (`auxiliary_driver pmic_glink_ucsi_driver`, `.name = "pmic_glink_ucsi"`, id table `pmic_glink.ucsi` :474-477), **not** platform | `pmic_glink_ucsi` | **`pmic_glink.ucsi.0`** — `drivers/base/auxiliary.c:325` (`dev_set_name(dev, "%s.%s.%d", modname, auxdev->name, auxdev->id)`, modname `pmic_glink`, name `"ucsi"` passed at `drivers/soc/qcom/pmic_glink.c:329`) | `/sys/bus/auxiliary/drivers/pmic_glink_ucsi/unbind\|bind` |
| xHCI | `drivers/usb/host/xhci-plat.c:631-636` (`platform_driver usb_generic_xhci_driver`) | `xhci-hcd` | **`xhci-hcd.2.auto`** (auto ID `.2`; child of `a600000.usb`; the SoC has several DWC3 instances, hence two root hubs `usb1`/`usb2`) | `/sys/bus/platform/drivers/xhci-hcd/unbind\|bind` |
| DWC3 glue | `drivers/usb/dwc3/dwc3-qcom.c:847-858` (`platform_driver dwc3_qcom_driver`) | `dwc3-qcom` | **`a600000.usb`** | `/sys/bus/platform/drivers/dwc3-qcom/unbind\|bind` |
| role switch | `drivers/usb/dwc3/drd.c:504-540` (`dwc3_setup_role_switch`), name `<parent>-role-switch` (`drivers/usb/roles/class.c:392`) | — | **`a600000.usb-role-switch`** (appears/disappears with the dwc3 driver) | not directly bindable; created/destroyed by dwc3 bind/unbind |

### 9.2 Unbind order: **UCSI → xhci → dwc3**

- UCSI holds a reference to the role switch: `ucsi.c:1837`
  (`con->usb_role_sw = fwnode_usb_role_switch_get(cap->fwnode)`) and calls
  `usb_role_switch_set_role()` on every connector change (`ucsi.c:1376`,
  `:1958`). Unbinding dwc3 while UCSI still holds the switch would unregister
  it out from under a live reference (UAF) — so **UCSI goes first**.
- Unbinding dwc3 = `dwc3_qcom_remove` → `dwc3_core_remove`
  (`drivers/usb/dwc3/core.c:2409-2436`) → `dwc3_core_exit_mode` (:2413) → OTG
  ⇒ `dwc3_drd_exit` (`drd.c:596-624`): `usb_role_switch_unregister`
  (:600-601) **plus** `dwc3_host_exit` while `current_dr_role == HOST`
  (:610-612, which destroys the `xhci-hcd` platform device) → then
  `dwc3_core_exit` (core.c:2416, the CORESOFTRESET/halt path). The xhci
  unbind itself is top-down and its safety is already proven by run 4
  (rc=0 ×3, no `-110`).

### 9.3 Rebind order: **dwc3 → UCSI** (the chain then completes itself)

- **dwc3 first**: `dwc3_qcom_probe` → `dwc3_core_probe` → OTG ⇒
  `dwc3_drd_init` (`drd.c:546-552`) → `dwc3_setup_role_switch` → a **new**
  `a600000.usb-role-switch`, initial mode **DEVICE** (no `default-role`
  property in the image DTB, §9.4). No `xhci-hcd` yet.
- **UCSI second, and it must be second**: the probe resolves the role switch
  via `ucsi_find_fwnode()` (`ucsi.c:1800-1808`, the fwnode of `connector@0`)
  → `fwnode_usb_role_switch_get()` (`drivers/usb/roles/class.c:190-201`) →
  `fwnode_connection_find_match()` (`drivers/base/property.c:1444-1459`) →
  graph walk: the `connector@0` endpoint →
  `fwnode_graph_get_remote_port_parent()` (property.c:1385) → the
  `a600000.usb` node, where `usb_role_switch_match()`
  (`roles/class.c:126-136`) requires the **`usb-role-switch` property — which
  is present in the image DTB** (§9.4). Without a registered switch the
  probe **hard-fails** (`ucsi.c:1838-1840`, `dev_err_probe`) — hence dwc3 must
  be re-bound first.
- **After that UCSI completes the chain by itself** (no further user action):
  `GET_CONNECTOR_STATUS` (`ucsi.c:1916`; the PPM never de-plugged the stick ⇒
  CONNECTED) → partner type UFP ⇒ `u_role = USB_ROLE_HOST` (:1925-1928) +
  `ucsi_register_partner()` (:1944 — `port0-partner` reappears) +
  `ucsi_orientation()` (:1946) → `usb_role_switch_set_role(HOST)` (:1958) ⇒
  `dwc3_usb_role_switch_set` (`drd.c:450-474`) → `dwc3_set_mode(HOST)` →
  CORESOFTRESET + `dwc3_host_init` (core.c:244) ⇒ **`xhci-hcd.2.auto` is
  recreated** → auto-bind → fresh root hub → **fresh scan**.

### 9.4 Image DTB facts (the dbgC3 image; checked with the token-walk tool)

Both rp6 DTBs embedded in the kernel section (two are present; ABL picks one)
have **`usb-role-switch` present** on `soc@0/usb@a600000` and **no**
`dr_mode` (ABL injects it into the in-RAM DT in `linux usb` mode) and **no**
`default-role` (hence the initial role-switch mode is DEVICE). The DTB uses a
non-standard FDT tag encoding (the high `0x10` byte of tag words is cleared,
so tags are bare `1/2/3/4/9`; the strings block has no leading empty string),
so the naive `diag/dump_usb_dtb.py` parser mis-parses it (it printed
`usb-role-switch=НЕТ` — wrong); the authoritative check is the full token walk
(`diag/check_dtb_role_switch.py`, byte-identical round-trip against the
un-spliced reference DTBs) plus the runtime (the switch is live in run 4 and
the flip works).

### 9.5 The manual sequence (emergency shell, no rebuild)

```sh
cat /sys/class/typec/port0/orientation        # 1) normal or reverse?  (reverse ⇒ flip the plug, re-run dbgC3 first)
ls /sys/class/typec/                          # port0, port0-partner?
echo pmic_glink.ucsi.0  > /sys/bus/auxiliary/drivers/pmic_glink_ucsi/unbind
echo xhci-hcd.2.auto    > /sys/bus/platform/drivers/xhci-hcd/unbind
echo a600000.usb        > /sys/bus/platform/drivers/dwc3-qcom/unbind
echo a600000.usb        > /sys/bus/platform/drivers/dwc3-qcom/bind
echo pmic_glink.ucsi.0  > /sys/bus/auxiliary/drivers/pmic_glink_ucsi/bind
dmesg | tail -40                              # "new high-speed/SuperSpeed USB device"?
ls /sys/block/                                # a new sdX beyond sda–sdf?
```

Success = `new …-speed USB device` in dmesg + a new `sdX`: the residual
blocker was state left in dwc3/UCSI (pre-PDR scan / the ABL host session)
that the xhci-only rebind does not reset → v4 (dbgC4) = the auto-escalation.
Zero events even on the full chain → the blocker is below dwc3 (PHY /
repeater / PPM data path / orientation) — chase item by item.

**The emergency shell takes no input on this hardware (confirmed by the
user, 2026-11-12), so this manual sequence is not possible.** The same
sequence is automated in v4 (dbgC4) as the escalation of §9.1–9.3: it fires
only on the `FAIL-NO-SCAN` / `FAIL-NO-DEV` branches, dumps the tree before
and after, and prints the beta-1 / beta-2 verdict directly.

## 10. Run protocol

### 10.1 dbgC3 (runs 1–4; the image is still on the spare stick)

Flash `KERNEL.ci-a699dd6-dbgC3` to the **spare** stick, then **verify md5
`9969edaff95d75c4766d84919d82cbb7` on both sides after flashing** (lesson of
§3.1: runs 2 and 3 booted the v1 image because the stick was never checked),
stick **pre-plugged in the normal orientation** (reverse orientation leaves
the data path unrouted), ABL → `linux usb`, **zero actions**, read the
`ARMADA-C:` lines.

A run is a genuine dbgC3 run only if it prints `ARMADA-C: hook loaded up=Ns`
followed by `start up=…: dr_mode='host' xhci=ABSENT (patch-1400 kernel …)` and
eventually `ARMADA-C: TREE[ …` lines; a screen showing only the v1
`FAIL-NO-DEV … at 3s` line (plus the lever-B `line 82: read …` error) is the
wrong image.

### 10.2 Run 5 (the manual full-chain test) — **not possible**

When dracut fails to find the root it drops an **emergency shell**; the test
was to be §9.5 (the exact sysfs echoes). The emergency shell **takes no
input on this hardware (confirmed by the user, 2026-11-12)** — no console
keys, no Bluetooth keyboard. The manual full-chain test is therefore
**impossible**, and v4 (dbgC4) with the unconditional auto-escalation is the
only beta-1 / beta-2 discriminator. Its two pre-checks moved into the run:

1. **orientation** — the v4 dump prints `port0/orientation` (values
   `unknown` / `normal` / `reverse`) on every `TREE[ …` line. If a run
   prints **`reverse`**: flip the plug and re-run the *same* dbgC4 image —
   a reverse orientation can leave the data path unrouted and would explain
   everything without new levers.
2. **the stick LED** — physical observation during the run (no input
   needed): whether the VBUS the PPM reports as out actually reaches the
   stick (the PPM reading is not a guarantee at the connector).

### 10.3 v4 (dbgC4) — built, the image for run 5

- **gate** the first rebind on `port0-partner` appearance (≤20 s; the real
  post-VBUS marker, §3.3 gate correction — the bare roles at 3.66 s were
  pre-VBUS) instead of the bare typec roles;
- **dump additions**: `port0/orientation`, `partner: yes/no`, and the
  xhci → `usbN` mapping (`ls` of each xhci device directory: which root hub
  belongs to `xhci-hcd.*.auto` — the auto ID is looked up by glob, never
  hard-coded, because a full-chain reset can re-create the device under a
  new ID);
- **`wait_disk` optimization** (run 4: ~12.7 s wall clock per "10 s" —
  UFS-LUN cache, `sleep 0.5`, the `-110` check every 2nd iteration);
- **auto-escalation** xhci-only → full chain (UCSI → xhci → dwc3 unbind,
  dwc3 → UCSI rebind, §9) **unconditional** (the manual test is impossible),
  fired only on the `FAIL-NO-SCAN` / `FAIL-NO-DEV` branches, with a safety
  abort (if the UCSI unbind fails, dwc3 is not touched — the role-switch
  reference, §9.2).

Verdicts: `ENUMERATION OK (full-chain)` (beta-1: the residual blocker was
dwc3/UCSI state → the hook is the fix) / `FAIL-NO-SCAN-FULL` (beta-2: the
blocker is below dwc3 — chase PHY / repeater / PPM data path / orientation
item by item) / `FAIL-ESCALATE` / `FAIL: Host halt -110 after full-chain
reset`. New `TREE[ …` tags: `ESC`, `ESC-ABORT`, `NO-XHCI-ESC`,
`NO-SCAN-FULL`, `OK-FULL`.

Protocol (run 5): flash `KERNEL.ci-a699dd6-dbgC4` to the spare stick,
**verify md5 on both sides after flashing** (the lesson of §3.1), stick
pre-plugged, ABL → `linux usb`, zero actions, photo of the diag screen,
watch the stick LED. A run is a genuine dbgC4 run only if it prints
`ARMADA-C: hook loaded up=Ns` and then either `partner at Ns (port0-partner;
…)` or `WARN-nopartner` (the v4 gate line); on failure, `ESCALATE at Ns:
full-chain reset (…)` marks the escalation.
