# Lever C implementation: post-PDR xHCI rescan in the initramfs

Status (2026-11-14): **clean beta-2; the eUSB2 repeater dump is done on
both sides, and the register file is not the discriminator.** The full
chain (UCSI → xHCI → dwc3 unbind/rebind) runs correctly, early and
post-VBUS, and does not help (EXP-034) — the residual blocker is below
dwc3. EXP-037 (dbgC8, `linux usb`, pre-plug, §12.5) and EXP-038 (working
mode, manual debugfs read on a normal "sdcard" boot, §12.8) read the
repeater's `0xfd00–0xfd5b` window in both modes: the repeater is
**enabled and reporting OK in both** (`0xfd46=0x80`, `0xfd08=0x80`), the
DT/init tuning is written as expected in both, and the eight registers
the kernel never writes are **bit-identical** (`50=00 52=01 55=03 56=00
58=02 59=03 5a=01 5b=02`) — so the `31bc94de` register-file hypothesis is
**refuted in both its forms** (§12.6, §12.8). The only mode diff in the
window is seven status/activity registers no AP-side software writes
(`fd00 fd02 fd04 fd05 fd09 fd0a fd42`): all `0x00` in the broken mode,
non-zero in the working one — in `linux usb` the repeater has never seen
a link. The blocker is the eUSB2 link state / PPM routing (H2); the
write ladder is dead (steps A and B both no-ops / mismatch-creators),
and the next front is the PPM side (EXP-041: `apsd-rerun-cfg` 0→1 on
device).

Numbering: every boot has an immutable `EXP-NNN` ID
([EXPERIMENTS.md](EXPERIMENTS.md)). The old per-document "run N" counter is
kept only as an alias — EXP-028…031 = runs 1–4, EXP-032…034 = runs 5–7,
EXP-035/036/037 = runs 8/9/10.

Design rationale:
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

## 3. The hardware runs (2026-11-12): EXP-028…031 — runs 1–3 = a hook race, not a hardware verdict; run 4 = the genuine verdict

### 3.0 EXP-028 — run 1

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

### 3.1 EXP-029 — run 2 (the "decisive" run that was not): the stick still held the v1 image

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

### 3.2 EXP-030 — run 3: the third bit-identical v1 repeat (the stick was still never re-flashed)

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

### 3.3 EXP-031 — run 4 (the first genuine lever-C test): ⭐ `FAIL-NO-SCAN` with a live controller

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
  fresh scans, two of them post-VBUS, found nothing. The next lever was the
  **full chain** reset (UCSI → xhci → dwc3 unbind, dwc3 → UCSI rebind,
  §9). **It has now run (runs 6–7, §11):** the chain executes correctly,
  early and post-VBUS, all rc=0, and self-completes in 0.6 s
  (`GET_CONNECTOR_STATUS` → partner → role host → xhci recreated) — and
  **beta-2 is established** (run 7, normal orientation): even the full
  chain produces zero events. The blocker is below dwc3 (eUSB2 repeater /
  PPM data path / physical power); the "residual = dwc3/UCSI/PHY state that
  a re-probe resets" hypothesis is refuted.
- **Run 5 (dbgC4) was not a hardware verdict:** the escalation aborted at
  the UCSI unbind — a wrong sysfs path in the hook (`pmic_glink_ucsi`); the
  real auxiliary driver name is `ucsi_glink.pmic_glink_ucsi`
  (`drivers/base/auxiliary.c:358-360`, §11.1). Fixed in v5 by resolving the
  driver from the device's `driver` symlink at runtime (never hard-code the
  path).
- **Run 6 (dbgC5) was confounded:** the first genuine full chain — but
  `orientation=[reverse]` in every dump; a reverse plug can leave the data
  path unrouted, so the verdict was invalid. Run 7 re-ran the same image
  with the plug flipped to normal.
- ~~`FAIL: Host halt -110`~~ → not triggered (rebind rc=0 ×3). If it ever
  appears: the qmp-combo defect; retries are pointless. Backport the upstream
  fix (Oleg Keri, LKML 2026-09-16, "keep the Type-C callbacks off unclocked
  registers") instead.
- ~~`WARN: no charger_pd PDR in 30 s`~~ → not triggered (PDR at 3.54 s).
- ~~`FAIL-NO-DEV`~~ → not triggered (the flip happened; xhci appeared at
  3.67 s).

The pre-checks from the run-5 protocol, now with results: (1) the port
**orientation** (`/sys/class/typec/port0/orientation`, values
`unknown`/`normal`/`reverse` per `drivers/usb/typec/class.c:1678-1682`) —
measured in every run's dumps: `normal` in runs 5 and 7, `reverse` in run 6
(the confound); a `reverse` orientation can leave the data path unrouted
and is exactly consistent with live CC/VBUS + no enumeration (test D); (2)
the **stick LED** — still pending: whether the VBUS the PPM reports as out
actually reaches the stick; it is now the power-vs-data discriminator for
the below-dwc3 blocker (§11.6); (3) a **manual replug** in the current era
— a CC-edge confirmation without a new image (October history: an early
re-attach, <30 s, opens the port; a late one, 38-102 s, does not).

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
| UCSI over PMIC-GLINK | `drivers/usb/typec/ucsi/ucsi_glink.c:480-487` — an **auxiliary** driver (`auxiliary_driver pmic_glink_ucsi_driver`, `.name = "pmic_glink_ucsi"`, id table `pmic_glink.ucsi` :474-477), **not** platform | **`ucsi_glink.pmic_glink_ucsi`** — *correction (run 5, §11.1):* for a built-in auxiliary driver the sysfs name is **`<KBUILD_MODNAME>.<.name>`** (`drivers/base/auxiliary.c:358-360`: `driver.name = kasprintf("%s.%s", modname, auxdrv->name)`; the caller's module name for built-in `ucsi_glink` is `"ucsi_glink"`) — **not** the bare `.name` | **`pmic_glink.ucsi.0`** — `drivers/base/auxiliary.c:325` (`dev_set_name(dev, "%s.%s.%d", modname, auxdev->name, auxdev->id)`, modname `pmic_glink`, name `"ucsi"` passed at `drivers/soc/qcom/pmic_glink.c:329`). Device and driver are named from *different* modnames, hence the asymmetry | `/sys/bus/auxiliary/drivers/ucsi_glink.pmic_glink_ucsi/unbind\|bind` (resolve at runtime from the device's `driver` symlink — never hard-code) |
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
echo pmic_glink.ucsi.0  > /sys/bus/auxiliary/drivers/ucsi_glink.pmic_glink_ucsi/unbind
echo xhci-hcd.2.auto    > /sys/bus/platform/drivers/xhci-hcd/unbind
echo a600000.usb        > /sys/bus/platform/drivers/dwc3-qcom/unbind
echo a600000.usb        > /sys/bus/platform/drivers/dwc3-qcom/bind
echo pmic_glink.ucsi.0  > /sys/bus/auxiliary/drivers/ucsi_glink.pmic_glink_ucsi/bind
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

### 10.4 v5 (dbgC5) — the image for runs 6–7 (2026-11-13)

v5 = v4 minus the 3-try xhci loop (run 4: three empty scans bought nothing)
plus:

- **early escalation** — a bounded 3 s wait after the partner gate, then the
  full chain immediately (target ~7 s: post-VBUS, inside the ~30 s window);
- **runtime UCSI resolution** (`_ac_ucsi_resolve`): the device by glob
  `pmic_glink.ucsi.*` on the auxiliary bus, the driver from the device's
  `driver` symlink (`cd -P "$dev/driver" && pwd -P` — no `readlink -f` in
  the initramfs) — the run-5 path bug cannot recur;
- an **ESCDIAG dump** (auxiliary devices / drivers / per-candidate driver
  path) before the unbind;
- abort branches rc=127 (device absent) / rc=128 (device unbound) ⇒
  `ESC-ABORT`, dwc3 untouched.

Image: `KERNEL.ci-a699dd6-dbgC5`, 202 114 351 B, md5
`c08490f9f3d7d9eb1440a175e597d6f5`, sha256
`55ec5436235830f12afb5baf7c9df85691a24851d44df097d9e0313368e4ec9f`; hook v5
(25 326 B, md5 `a509333bea77f9ba4ff80e91b11dc1e1`); all image invariants
verified (magic `ANDROID!`, header `[20:576]` byte-identical to the base,
kernel identical, hook round-trip). Protocol: flash to the spare stick,
md5 both sides, stick **pre-plugged in the normal orientation** (read the
`orientation=` line in the photo first — a `reverse` run is a confound,
run 6), ABL → `linux usb`, zero actions, photo.

## 11. Runs 5–7 (2026-11-13): EXP-032…034 — the full chain ran, beta-2 is clean, and the eUSB2 repeater hypothesis

### 11.1 EXP-032 — run 5 (dbgC4): the escalation aborted on a wrong UCSI path (not a hardware verdict)

`line 299: /sys/bus/auxiliary/drivers/pmic_glink_ucsi/unbind: No such file
or directory` @34.86 s — the hard-coded driver path does not exist in the
running kernel; the UAF guard worked (dwc3 untouched), but the full chain
never ran. The real auxiliary **driver** name is
**`ucsi_glink.pmic_glink_ucsi`**: `drivers/base/auxiliary.c:358-360` builds
it as `<KBUILD_MODNAME>.<.name>` from the *caller's* module name (built-in
`ucsi_glink` ⇒ `"ucsi_glink"`), while the *device* name
`pmic_glink.ucsi.0` (`auxiliary.c:325`) is built from the parent device's
modname `pmic_glink`. Lesson: never hard-code a sysfs driver path — resolve
it from the device's `driver` symlink. v5 does this and found the right
path unassisted (run 6 ESCDIAG: device `pmic_glink.ucsi.0` bound to
`ucsi_glink.pmic_glink_ucsi`).

### 11.2 EXP-033 — run 6 (dbgC5): the first genuine full chain — confounded by `reverse`

Timeline (dmesg ms): `TREE[NO-SCAN] orientation=[reverse] partner=yes`
@7.087742 → `ESCDIAG` dump @7.18 → `unbind done ucsi rc=0 xhci rc=0 dwc3
rc=0` @7.208002 → `rebind dwc3 rc=0` @7.242017 → `rebind ucsi rc=0`
@7.275570 → `GET_CONNECTOR_STATUS: ConnectStatus=1, ConnectPartnerType=2,
USB=1` @7.482094 (UCSI completes the chain itself) → `xhci=xhci-hcd.2.auto
at 7s` @7.791763 → `TREE[NO-SCAN-FULL] orientation=[reverse]` @23.177465 →
`FAIL-NO-SCAN-FULL (last up=23s, scan-events=0)` @23.199086. No `-110`.

**What it proves:** the §9 mechanism works on hardware — early (post-VBUS
5.44 s, inside the ~30 s window), safe (all rc=0), and the chain
self-completes in 0.6 s exactly like the full system's bring-up; the PPM's
CONNECTED state survives the rebind. **Why it is invalid as a verdict:**
`orientation=[reverse]` in all three dumps — a reverse plug can leave the
data path unrouted, so `scan-events=0` is explained by orientation, not by
depth. Run 7 = the same image, plug flipped to normal.

### 11.3 EXP-034 — run 7 (dbgC5, normal): ⭐ clean beta-2

Timeline: `otg enable: 1` (VBUS out) @5.401118 → `TREE[NO-SCAN]
orientation=[normal] partner=yes` @7.009344 → `FAIL-NO-SCAN (scan-events=0);
escalating` @7.038515 → `ESCALATE at 7s (ucsi=pmic_glink.ucsi.0
ucsi-drv=ucsi_glink.pmic_glink_ucsi … vbus=out)` @7.043093 → `unbind done
ucsi rc=0 xhci rc=0 dwc3 rc=0` @7.104682 → `rebind dwc3 rc=0` @7.140214 →
`rebind ucsi rc=0` @7.154555 → `GET_CONNECTOR_STATUS … USB=1` @7.454549 →
`xhci=xhci-hcd.2.auto at 7s` @7.668929 → `TREE[t10] orientation=[normal]`
@10.306546 → `TREE[NO-SCAN-FULL] usb: [1-0:1.0 2-0:1.0 usb1 usb2]`
@23.058100/23.069913 → **`FAIL-NO-SCAN-FULL (last up=23s, scan-events=0)`**
@23.077586. No `-110`.

Every condition of the decisive test holds: **normal** orientation in all
dumps; the full chain **executed** (all rc=0, self-completing, fresh scan
after the re-attach); **post-VBUS** (5.40 s) and **early** (7 s, inside the
~30 s window); no `-110`, no UAF. ⇒ the residual blocker is **below dwc3**
(PMIC / PPM / physical). The hypothesis "the residual is dwc3/UCSI/PHY
state that a re-probe resets" is **refuted**: the full chain re-ran
`dwc3_qcom_probe`, re-initialized both PHYs, and redid the whole Type-C
contract and orientation — and did not help.

### 11.4 What is now closed (the software stack does everything right)

| hypothesis | status |
|---|---|
| scan order (pre/post PDR, pre/post VBUS) | closed — post-VBUS scans are empty |
| plug orientation | closed — `normal` measured in runs 5 and 7 |
| dwc3/UCSI/PHY state reset by re-probe | **closed by run 7** — the full chain did not help |
| PPM classification / `usb_type` | closed — control E works with the identical fingerprint |
| UCSI path / `-110` / UAF | fixed (v5 runtime resolution) / not in the path |

The **takeover framing** (accepted): ABL read `\KERNEL` from the stick, so
at handoff the link **worked** (data path routed, VBUS out, the stick
answering) — ABL left a *working* state, not dirt. The bug is that the
kernel's teardown-and-reinit does not restore a working link; the kernel
assumes a default that `linux usb` does not have. (Repo docs:
`ABL_DR_MODE_HOST.md` — "the controller state is torn down and
re-initialized at handoff… What the kernel lacks is sequencing, not a
driver.")

### 11.5 The eUSB2 repeater: partial init, no reset (the current front)

The data path is `dwc3 → usb_1_hsphy` (SoC eUSB2 HS PHY) `→
pm8550b_eusb2_repeater` (PMIC) `→ connector` (`sm8550.dtsi:4565-4566`, the
board DTS wires `usb_1_hsphy`'s `phys` to the repeater). The repeater is a
**separate PMIC device** (`arch/arm64/boot/dts/qcom/pm8550b.dtsi:58-62`,
`reg = <0xfd00>`) driven by
`drivers/phy/qualcomm/phy-qcom-eusb2-repeater.c` (platform driver
`qcom-eusb2-repeater`, regmap of the **parent PMIC** via
`dev_get_regmap(dev->parent)`, base from its own `reg`).

Register map (driver :14-38): `0x08` status (RO, `RPTR_OK` = BIT 7), `0x46`
EN_CTL1 (enable), `0x50` CROSSOVER, `0x51` IUSB2, `0x52` RES_FSDIF, `0x53`
HSDISC, `0x54` SQUELCH_U, `0x55` SLEW, `0x56` EQU, `0x57` PREEM, `0x58`
HS_COMP_CUR, `0x59-0x5B` EUSB slew/equ/comp, `0xe8`/`0xed` force-enable/value
(BIT 6 = 19.2 MHz clock).

**What the kernel writes** (`eusb2_repeater_init`, :141-193): the enable
(0x46=0x80), the SoC init table (IUSB2=0x8, SQUELCH_U=0x3, PREEM=0x5), the
board DT overrides (RP6: PREEM=0x3, HSDISC=0x6, IUSB2=0xb), and a poll of
`RPTR_OK`. In host mode `set_mode` additionally forces the 19.2 MHz clock
(0xe8/0xed = 0x40 — the documented CM.Lx workaround, :204-211). **It never
writes 0x50, 0x52, 0x55, 0x56, 0x58, 0x59-0x5b** — those keep whatever the
hardware holds. Upstream says exactly why this matters (:213-217):

> "In device mode clear host mode related workaround as **there is no
> repeater reset available, and enable/disable of repeater doesn't clear
> previous value due to shared regulators** (say host <-> device mode
> switch)."

Model: full system — ABL never touched the repeater, the un-written
registers hold PMIC defaults, the partial init suffices; `linux usb` — ABL
configured the repeater for its own host session, the kernel's partial init
runs on top and **leaves ABL's values in the un-touched registers** → the
HS path is broken (e.g. a squelch/disconnect threshold, crossover). The
FORCE registers are not the residual — `dwc3_core_init_mode`'s host branch
rewrites them on every rebind (`core.c:252` → `phy-snps-eusb2.c:179-185`).

**Correction of an earlier belief:** the full chain **does** re-initialize
the repeater — `dwc3_core_init` → `dwc3_phy_init` (`core.c:827-843`) →
`snps_eusb2_hsphy_init` (`phy-snps-eusb2.c:455`): repeater `phy_init`
(:464) **plus a hard BCR reset of the SoC HS PHY**
(`reset_control_assert/deassert` :476-484, `GCC_QUSB2PHY_PRIM_BCR`) and the
QMP re-init. So "hard-reset the repeater/PHY" is not an unused lever — it
already ran in run 7 and failed. The SoC side is fully reset on every
rebind; the residual (if analog) sits on the **PMIC side**, where nothing
resets the register file.

**Regulator sharing decides whether the residual can survive a rebind at
all** (RP6 DTS, `qcs8550-ayn-common.dtsi`): `vdd18` = ldo15 is
**shared** (wcd939x audio :503-505 + wcn7850-pmu :521) ⇒ a rebind's
`regulator_bulk_disable` does **not** power-cycle it (refcount); `vdd3` =
ldo5 is **exclusive** to the repeater ⇒ it is power-cycled. Neither LDO is
always-on/boot-on. ⇒ the hypothesis is consistent with run 7 **only if the
register file is powered by vdd18** (or the residual is elsewhere, e.g. the
PPM data path). A register dump decides.

### 11.6 Next experiments (updated 2026-11-13: LED/replug answered, dump plan sharpened)

1. **The stick LED** — **ANSWERED: on.** The power path is excluded (VBUS
   reaches the connector; the PPM's "source=1" is real); the blocker is the
   data path (repeater / PPM routing).
2. **A manual replug** — **ANSWERED: it works.** The CC-edge model is
   confirmed in the current era (a fresh CC attach opens the port; October
   history: an early re-attach <30 s opens, a late one, 38-102 s, does
   not). No AP-side lever (R/T/SET) can create a genuine CC edge — the
   physical replug is the only known working lever. (Pending details: the
   replug's timing from boot start, and whether it produced a full boot —
   if so, one replug at the start of a `linux usb` boot is already a
   working stop-gap.)
3. **Dump + fix test: one image, two runs** (the decisive experiment).
   Image = the dbgC5 base + `CONFIG_REGMAP_DEBUGFS=y` + the hidden one-line
   `#define REGMAP_ALLOW_WRITE_DEBUGFS` in
   `drivers/base/regmap/regmap-debugfs.c` (upstream: "don't provide any
   real compile time configuration option… modify the source code
   directly") — makes `/sys/kernel/debug/regmap/<pmic>/registers` 0600
   with the write format `echo <reg-hex> <val-hex> > registers`
   (`regmap-debugfs.c:294-333`; read format `<reg>: <val>`, :252-257).
   The PMIC regmap is created in `drivers/mfd/qcom-spmi-pmic.c:246-260`
   (device `pmic@7` = pm8550b); the regmap **directory is resolved at
   runtime** (never hard-coded — the UCSI lesson). CI pipeline + the
   `build_dbgC5_ci.py` pattern, same invariants; alternative: an spmi
   read/write route.
   - **Run 1 — the full system from the stick** (working; the stick is
     enumerated): read the known-good blob `fd00:`-`fd5b:`. The eight
     un-written registers hold the **hardware reset values** — non-public,
     not in any DTS (§11.7): the dump is the only source of the recipe.
   - **Run 2 — `linux usb`, pre-plugged**: after the full chain the hook
     reads the current blob, prints the diff, then walks the ladder:
     - **Step A: write 0x00 to the eight un-written registers**
       (0xfd50, 0xfd52, 0xfd55, 0xfd56, 0xfd58, 0xfd59, 0xfd5a, 0xfd5b) —
       restore the pre-`31bc94de` vendor behavior (§11.7) → wait for the
       scan. Enumeration ⇒ the `31bc94de` regression is **proven** and the
       fix is ready: an armada kernel patch that zeroes the eight
       registers in `eusb2_repeater_init` (documented vendor behavior, no
       dependency on the dump values).
     - **Step B** (if A fails): write the run-1 known-good values →
       enumeration ⇒ the general residue hypothesis; fix = the dump
       values (kernel patch or hook-write first).
     - **Step C** (if B fails): an empty diff ⇒ the residue is **not** in
       the register file ⇒ H2 (eUSB2 link state: the BCR reset resets the
       SoC PHY but not the repeater — one-sided reset) / the PPM data
       path ⇒ the PPM side (ADSP tcpc_cfg / RE) or the brute-force vdd18
       cut (raw SPMI write; only if the dump shows a register-file
       residual that the writes cannot cure).
4. (Optional, no build) **The official vendor kernel in `linux usb`
   pre-plug** (the official boot image as `\KERNEL` on the stick): the
   RP6's vendor kernel (ship era, likely the zeroing era) should enumerate
   without a replug if the §11.7 hypothesis holds ⇒ the regression
   confirmed at kernel level. Requires the official ROM (not kept locally;
   caveat: the official DTS may carry different tune values).
5. (Second echelon) `snps,host-vbus-glitches-quirk` in the DT — the
   upstream dwc3 workaround for a ~15 µs VBUS dip at host entry; the
   symptoms differ (full-speed/descriptor corruption, not a total
   no-connect) and on the RP6 the PPM, not the PP bit, drives VBUS — cheap,
   low prior.

### 11.7 Upstream driver history: the zero-out saga and the `31bc94de` regression candidate (web research, 2026-11-13)

The full commit history of
`drivers/phy/qualcomm/phy-qcom-eusb2-repeater.c` (18 commits, via the
GitHub mirror of `torvalds/linux`) contains the key lead — the driver
**once zeroed the un-touched tuning registers**, exactly like the vendor
kernel, and was explicitly changed **not to**:

1. `99a517a5` (2023-09-13, Konrad Dybcio, Linaro) — "Zero out untouched
   tuning regs": *"The vendor kernel zeroes out all tuning data outside
   the init sequence as part of initialization. Follow suit to avoid UB."*
2. `734550d6` (2024-02-01, Abel Vesa, Linaro) — "Rework init to drop
   redundant zero-out loop": the rework **kept the zeroing** — the init
   table became a C zero-initialized array and init wrote **all ten**
   tuning registers: the table values (+ DT overrides) and **0x00 for
   0x50/0x52/0x55/0x56/0x58/0x59/0x5a/0x5b**.
3. **`31bc94de` (2025-06-17, Luca Weiss, Fairphone; Reviewed-by: Konrad
   Dybcio and Dmitry Baryshkov — both Qualcomm)** — "Don't zero-out
   registers": *"Zeroing out registers does not happen in the downstream
   kernel, and will "tune" the repeater in surely unexpected ways since
   most registers don't have a reset value of 0x0. Stop doing that and
   instead just set the registers that are in the init sequence."*

So the zeroing era is upstream ~6.7–6.15 (+ the vendor kernel, per
`99a517a5`). Our 7.2.6 includes `31bc94de` and its later fixes — it writes
only the init table + DT overrides.

**The regression mechanism (the top candidate).** The commit's premise
("the hardware default is fine") is true for a cold boot and **false after
the ABL's USB host session**, which left its own values in the eight
registers. State table (the eight un-written registers):

| kernel | full system (cold ABL) | `linux usb` (ABL ran a host session) |
|---|---|---|
| zeroing era (upstream ~6.7-6.15; vendor per `99a517a5`) | 0x00 (the kernel zeroes) | 0x00 (ABL zeroes\* + kernel zeroes) — **consistent, presumed working** |
| no zeroing (7.2.6) | **reset values** — **working (control E)** | **ABL residue** — **broken (runs 5-7)** |

\* if ABL follows the vendor behavior quoted in `99a517a5`.

`31bc94de` moved the full-system state (0x00 → reset values) but **cannot
move the `linux usb` state** (the ABL residue) ⇒ the mismatch between the
two modes appeared with that commit. The zeroing-era kernel was robust to
the ABL residue (it overwrote it at every init); the new kernel **trusts**
it.

**Consistency with all observations:** control E (full system, pre-plugged)
works ⇒ the reset values are a working state; `linux usb` is broken with
live power (LED on) ⇒ the ABL residue sits in the RX/TX thresholds (the
register semantics below); the replug works ⇒ a fresh CC edge makes the
PPM re-run its attach handling, which plausibly **rewrites the repeater
tuning to a working state** (the AP-side full chain cannot reach the PMIC
register file); the synthetic levers (R/T/SET) are no-ops (they don't touch
the PMIC register file).

**Register semantics (vendor kernel, from `942e47ab`, "the downstream
correspondence"):** `0x57` PREEM = Tx pre-emphasis tuning; `0x51` IUSB2 =
HS transmit amplitude; `0x54` SQUELCH_U = squelch detection threshold;
`0x53` HSDISC = HS disconnect threshold; `0x59` SLEW = slew rate — all
analog HS signaling parameters, i.e. exactly the kind that can silence a
connect event. `5c87da03` (2025-12-19, Qualcomm) adds
`qcom,squelch-detector-bp` (-6000…+1000 mV → 0x54 = 0..7).

**Side findings:** (a) `31bc94de` accidentally swapped the DT mapping
(amplitude↔preem); fixed by `942e47ab` (2025-08-12) — our 7.2.6 has the
correct mapping (RP6 values unchanged: 0x51=0xb, 0x53=0x6, 0x54=0x3,
0x57=0x3); (b) no mainline board (Sony Xperia 1 VI — the same sm8550 —,
sm8750-mtp, Fairphone FP6) sets the eight registers in its DTS ⇒ in every
mainline system they hold the reset values ⇒ **the known-good values are
non-public hardware reset values: a live dump is the only source of the
recipe**; (c) no public discussion of "USB pre-plug broken after an ABL
USB host session" was found — the configuration seems specific to the RP6
(ordinary ABLs do not run a USB host session before handoff); no upstream
fix to expect.

**Honest caveats:** (a) `linux usb` pre-plug was never tested with a
zeroing-era kernel (all October runs were 7.2.6-based) — "the zeroing
world worked" is a hypothesis that step A (§11.6) will test directly;
(b) 0x00 is not guaranteed functional — the `31bc94de` authors argued
against the zeroing (possibly because it broke something on their boards)
— so step A may fail, and step B (the dump values) is the fallback.

## 12. Runs 8–10 (2026-11-13/14): EXP-035…037 — the repeater dump: the stall, its cause, and the result

The dump planned in §11.6 is the only way to see the eight registers the
kernel never writes (§11.5). Getting it took three images, because the first
two failed for reasons that had nothing to do with the repeater.

### 12.1 EXP-035 (dbgC6): the dump stalled silently

Hook v6 = v5 byte-for-byte plus one block: after the full chain, mount
debugfs, resolve the repeater's platform device, read
`/sys/kernel/debug/regmap/<pmic>/registers` from offset `0xfd00` and print
the 92-register block. The chain was again clean beta-2 (PDR 3 s, partner
3 s, `otg enable: 1` 3.39 s, `ESCALATE` 7 s with all rc=0,
`TREE[NO-SCAN-FULL]` 23 s, `scan-events=0`, no `-110`), and then:

```
[23.629] ARMADA-C: RPT-DUMP: linux-usb mode; dumping after the chain
… only heartbeats (hb up=28/33/…/51s) to the end of the photo at 51.5 s
```

No second dump line, no `RPT-ABSENT`, no block. The v6 hook printed its
second marker *after* the resolve and *before* the read, so the stall was
somewhere in mount → glob → resolve → open, or in the read itself; v6 had no
markers to tell them apart.

### 12.2 The read mechanics (source analysis, 7.2.6) — plausible, and later refuted

Why a naive read *could* cost tens of seconds, from the source:

- `regmap_map_fops.llseek = default_llseek` (`regmap-debugfs.c:342`), so GNU
  `tail -c +582913` seeks instead of reading-and-discarding; the seek lands
  inside the file.
- `regmap_read_debugfs(map, 0, max_register, …)` iterates
  `for (i = start; i <= to; i = regmap_next_readable_reg(map, i))`
  (`regmap-debugfs.c:216-270`) — to **`max_register` = 0xffff**, not to the
  92nd line. The pm8550b regmap has `max_register = 0xffff` and no
  `readable_reg` callback ⇒ **768 HW reads**, of which
  `0xfd5c–0xffff` = **676** are unimplemented PMIC addresses.
- Each unimplemented read runs `pmic_arb_wait_for_done` with
  `PMIC_ARB_TIMEOUT_US = 1000` and `udelay(1)` per iteration
  (`spmi-pmic-arb.c:102,390,401`) **plus a `dev_err`** (`:411`) — a
  plausible ~1 s of `udelay` and 676 console lines.
- `count` (8192 B) exceeds the whole `0xfd00–0xffff` window (6912 B) ⇒ the
  read is a **single `read(2)`** and the output appears only at the end ⇒
  "silence until it finishes" is by design, and a kill mid-read yields an
  empty file.

This model predicts a *slow* read, not a hang — and §12.5 shows it was
wrong anyway (0.2–1.1 s per map, zero timeouts).

**Tooling errata** (worth recording once): the CI initramfs is a full Fedora
one — `mkdir`, `mount`, `dmesg`, `timeout`, `stat`, `ps`, `pgrep`, `pkill`,
`cut`, `date` are present; `dd`, `head`, `wc`, `od`, `xxd` are not.

### 12.3 EXP-036 (dbgC7): the stall is the platform-device symlink resolve

v7 = v6 plus step markers, console quieting and a bounded read. The markers
answered the question in one boot:

```
[23.267] RPT-S0: enter (mode=linux-usb)
[23.280] RPT-S1: mkdir rc=0
[23.298] RPT-S1: mount rc=0                     ← debugfs is mounted
[23.394] RPT-S2: globbing platform devices
… heartbeats only, to 60 s
```

debugfs mounts fine; the register read **never started**. The hang is the
*resolve*: the shell glob `*eusb2*` over `/sys/bus/platform/devices/`, the
`[ -e ]` test on the platform-device symlink, `cd -P`, `pwd -P` or the
`stat` behind it. This also refutes the "676 SPMI timeouts" explanation for
this stall (§12.2 stands only as an explanation of read *duration*).

### 12.4 v8 (dbgC8): scan-based identification — no symlink resolve at all

v8 removes the resolve chain entirely (and still hard-codes nothing):

1. `timeout 5 ls /sys/bus/spmi/devices/` and
   `timeout 5 ls /sys/kernel/debug/regmap/` — a plain readdir of a debugfs
   directory and of the spmi bus.
2. Candidates = the intersection (the PMIC regmaps; `spmi.c:67` names
   devices `"%d-%02x"`), falling back to every regmap directory.
3. For each candidate: read the same `0xfd00–0xfd5b` window
   (`timeout 55 tail -c +582913 … | sed -n 1,92p`, with a 50 s kill
   watchdog, a 5 s grace and a byte-size progress line), then **identify the
   repeater by its own signature** — `0xfd08 = RPTR_OK (0x80)` and
   `0xfd46 = RPTR_EN (0x80)`. Every candidate produces one
   `RPT-SCAN: <dir> lines=N WRN:… KEY:…` line, so a non-match still leaves
   the values on screen (`RPT-NOHIT`).
4. The console is quieted with `dmesg -n 1` during the reads and restored
   afterwards; every external step is under `timeout`, so the hook cannot
   hang.

The fake-sysfs harness (`scripts/lever-c/fake-test-c8.sh`) covers 11 boot
modes, including a decoy regmap (a small map ⇒ empty window), a missing
regmap directory (`RPT-ABSENT`) and a non-matching signature
(`RPT-NOHIT`): 0 failures. Image invariants: `ANDROID!`, header `[20:576]`
byte-identical, kernel identical, SHA1 id recomputed, one hook entry
replaced (cpio 3112 entries), ramdisk −633 B.

### 12.5 EXP-037 (dbgC8, `linux usb`, pre-plug): the dump

Zero user actions, stick pre-plugged, normal orientation. The chain is beta-2
again (partner 3 s, `otg enable` 5.48 s, `ESCALATE` 7 s, all rc=0,
`TREE[NO-SCAN-FULL]` 23 s, `scan-events=0`), and then, for the first time,
the dump completes (23 → 25 s):

```
RPT-S2: spmi=[0-00 0-01 0-05 0-07 …]  regmap=[…]
RPT-S2: candidates=[0-00 0-01 0-05 0-07]
RPT-S3: console=4; timeouts before=0; suppressing to 1
RPT-S4: 0-00: read started (bounded 55s) at 23s
RPT-S5: 0-00: read done size=828 at 23s
RPT-SCAN: 0-00 lines=92 WRN: 08=XX 46=XX 51=XX 53=XX 54=XX 57=XX KEY: 50=XX … 5b=XX
RPT-SCAN: 0-01 lines=92 … XX
RPT-SCAN: 0-05 lines=92 … XX
RPT-SCAN: 0-07 lines=92 WRN: 08=80 46=80 51=0b 53=06 54=03 57=03
                 KEY: 50=00 52=01 55=03 56=00 58=02 59=03 5a=01 5b=02
RPT-S5: console restored to 4; timeouts after=0 at 25s
RPT-DUMP: repeater regmap=0-07 (92 regs fd00-fd5b, 9 B/line, offset 582912)
RPT-B: … 12 lines …
RPT-KEY (never kernel-written; residue candidates): 50=00 52=01 55=03 56=00 58=02 59=03 5a=01 5b=02
RPT-WRN (expect 08=80 46=80 51=0b 53=06 54=03 57=03): 08=80 46=80 51=0b 53=06 54=03 57=03
RPT-DONE: dump complete at 25s
```

The three non-repeater PMICs produce 92 lines of `XX`: the window is beyond
their `max_register`, so `regmap_readable()` is false and debugfs prints
`XX` without touching the hardware. The repeater is `0-07` (spmi address
0x07 = pm8550b). Full 92-line block: `logs/lever-c/exp-037-dump.txt`.

| reg | name (`phy-qcom-eusb2-repeater.c`) | value | written by the kernel? |
|---|---|---|---|
| `fd08` | RPTR_STATUS (RO) | `80` = RPTR_OK | — |
| `fd46` | EN_CTL1 | `80` = RPTR_EN | yes (init) |
| `fd51` | TUNE_IUSB2 | `0b` | yes (DT amplitude) |
| `fd53` | TUNE_HSDISC | `06` | yes (DT disc-thres) |
| `fd54` | TUNE_SQUELCH_U | `03` | yes (init table) |
| `fd57` | TUNE_USB2_PREEM | `03` | yes (DT preem) |
| `fd50` | TUNE_USB2_CROSSOVER | `00` | **no** |
| `fd52` | TUNE_RES_FSDIF | `01` | **no** |
| `fd55` | TUNE_USB2_SLEW | `03` | **no** |
| `fd56` | TUNE_USB2_EQU | `00` | **no** |
| `fd58` | TUNE_USB2_HS_COMP_CUR | `02` | **no** |
| `fd59` | TUNE_EUSB_SLEW | `03` | **no** |
| `fd5a` | TUNE_EUSB_EQU | `01` | **no** |
| `fd5b` | TUNE_EUSB_HS_COMP_CUR | `02` | **no** |

### 12.6 What the dump proves and what it refutes

1. **The repeater is enabled and healthy in the broken state**:
   `0xfd46 = 0x80` (enabled) and `0xfd08 = 0x80` (RPTR_OK). The kernel's
   `eusb2_repeater_init` ran — the DT/init values are exactly the ones it
   writes (`0x51=0x0b`, `0x53=0x06`, `0x54=0x03`, `0x57=0x03`), and the
   `RPTR_OK` poll would have failed loudly otherwise.
2. **The eight un-written registers are not zero** — six of eight are
   non-zero and the set looks like plausible hardware reset values, which is
   exactly what `31bc94de` claims ("most registers don't have a reset value
   of 0x0"). ⇒ **the "ABL zeroed the tuning" form of the regression
   candidate is refuted for `linux usb`.** Step A of the ladder (§11.6)
   would therefore *create* the mismatch rather than repair it — it is no
   longer the first thing to try.
3. **The SPMI-timeout model of the read is refuted**: 0.2–1.1 s per map,
   `timeouts before=0`, `timeouts after=0`. Unimplemented addresses return a
   fast arbiter error, not a `PMIC_ARB_TIMEOUT_US` spin.
4. **The v8 identification works on live hardware**: the intersection is
   exactly the four PMIC regmaps, the signature picks `0-07`, and the three
   non-repeaters cost one cheap empty read each.

What was not known here is now answered by the control (EXP-038, §12.8):
the working mode holds the **same eight values** ⇒ the register file is
not the discriminator ⇒ H1/`31bc94de` is refuted in both its forms, and
the blocker is H2 (eUSB2 link state / PPM routing: the BCR reset resets
the SoC PHY but nothing resets the repeater, and no AP-side lever creates
a fresh CC edge) — now with a positive readout: the seven activity
registers are all `0x00` in the broken mode.

### 12.7 The write ladder (dead after EXP-038)

1. **EXP-038 — the control** (2026-11-14, executed — see §12.8): the
   eight-register diff is **empty**.
2. ~~**EXP-039 — step A/B** on a write-capable kernel (the regmap debugfs
   write path, armada patch 1401): write the EXP-038 values into the
   eight registers and re-scan.~~ **Superseded**: step A (zero the eight)
   would *create* the mismatch rather than repair it, and step B (write
   the EXP-038 values) is a no-op — the values are already identical.
3. **step C is the outcome, and it is the front**: the residue is not in
   the register file ⇒ the PPM/eUSB2-link side (firmware RE,
   [ADSP_RE.md](ADSP_RE.md)) or the vdd18 cut. Concretely: re-arm the
   PPM without a fresh CC edge — the `apsd-rerun-cfg` 0→1 firmware patch
   on device ([ADSP_CONFIG.md](ADSP_CONFIG.md), the dbg52 candidate) —
   reserved as **EXP-041**.

### 12.8 EXP-038 (working mode, 2026-11-14): the control

Conditions: normal "sdcard" boot (stock Armada OS, ostree deployment
`6bb952cad7…`, kernel 7.2.6 + 192 armada patches — not the CI `a699dd6`
image kernel), Netac 512 GB stick cold-plug (first plug 1806 s,
disconnect 1836 s, re-plug 1844 s), `OK-ENUM` (`sdg` under
`xhci-hcd.2.auto/usb1`), orientation normal, partner present, zero user
actions. Capture: a manual debugfs read
(`scripts/lever-c/exp038-repeater-dump.sh`, run as root at uptime 3045 s)
with the v8 hook's verified mechanics — scan-based candidate selection
(same four PMIC maps `0-00 0-01 0-05 0-07`), the `fd08=80`/`fd46=80`
signature, and the line geometry measured from the file (9 B/line on this
kernel as well) instead of assumed. Transcript:
`logs/lever-c/exp-038-dump.txt`.

| set | EXP-037 (broken) | EXP-038 (working) |
|---|---|---|
| KEY — eight never-kernel-written tuning | `50=00 52=01 55=03 56=00 58=02 59=03 5a=01 5b=02` | **identical** |
| WRN — kernel-written / RO | `08=80 46=80 51=0b 53=06 54=03 57=03` | **identical** |
| seven never-AP-written status/activity | all `00` | `fd00=02 fd02=03 fd04=0b fd05=0e fd09=9f fd0a=18 fd42=80` |

Result:

1. **The register file is not the discriminator.** The eight tuning
   registers are bit-identical across the modes — and across two
   different kernels. The driver never writes them in either kernel
   (upstream `phy-qcom-eusb2-repeater.c`: init table + DT overrides cover
   only `fd46/fd51/fd53/fd54/fd57`, `set_mode` covers `fde8/fded`; the
   board DT has no `qcom,tune-res-fsdif` / `qcom,squelch-detector-bp`),
   and an identical *non-zero* match cannot be a kernel artifact (a
   zero-out kernel would read `00`). H1/`31bc94de` is refuted; the write
   ladder is dead (§12.7).
2. **The mode diff is link activity, not configuration.** The seven
   differing registers are never written by AP-side software in either
   mode; they are repeater-internal status/activity state. In `linux usb`
   they are all `0x00`: the repeater is enabled and OK but has never seen
   a valid link. That is H2 in register form — the blocker is below the
   repeater's input (PPM/ICM data path / SoC-side signal path),
   consistent with the PPM `ncp_stby` fingerprint and the no-fresh-CC-edge
   model ([KERNEL_PATCH_1400.md](KERNEL_PATCH_1400.md)).
3. **Deviation from the plan, recorded:** the registry said "normal boot
   of dbgC8, stick pre-plugged". Executed with the stock kernel, a plain
   stick, cold-plug. Valid as the control for the tuning comparison for
   the reasons in point 1 (and the WRN set — the kernel-written
   registers — is identical, showing the effective DT/init writes match
   on both kernels). Residual caveat, cheap to close: the same manual
   read in a normal boot of the CI `a699dd6` kernel would confirm the
   seven activity registers on the identical kernel.
4. Repeater device on this kernel: `c400000.spmi:pmic@7:phy@fd00`
   (`qcom,pm8550b-eusb2-repeater`), driver `qcom-eusb2-repeater`
   (built-in), regulators `vdd18`/`vdd3`. The `phy-qcom-m31-eusb2.ko`
   module is the SM8750 M31 HSPHY driver, not bound on this board.
