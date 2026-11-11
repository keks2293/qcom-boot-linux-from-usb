# Sequencer timing: best practice, and the "minimalism vs event-start" comparison

Status: analysis round, 2026-11-11, at the user's request ("what is the best
practice — google it"). This document records (1) what the canonical initramfs
practice for "wait for hardware" actually is, (2) why the event-based ADSP start
("option 2") does **not** reproduce the full-system timing it was meant to, and
(3) the decision taken: **1+3+4** — drop the ADSP staging, keep the post-PDR
rebind, make it event-driven, and add a bounded verify/retry with a `-110` guard.

Labels: **[measured]** = read on this machine / in our logs; **[inference]** =
reasoning from those measurements, not directly observed.

## 1. What the canon actually is [measured]

The best practice is not a blog post; it is the source of the initramfs tooling
itself, which is on this very machine (RP6: dracut 108, systemd 259). Read
directly:

- `dracut-initqueue.sh` — the main wait loop is `udevadm settle
  --exit-if-exists=...` plus queue hooks. **No `sleep` for hardware bring-up.**
- `dracut-lib.sh:465` — `udevsettle()` = `udevadm settle
  --exit-if-exists=$hookdir/initqueue/work`.
- `dracut-dev-lib.sh` — `wait_for_dev <dev>` writes an
  `initqueue/finished/devexists-*.sh` containing `[ -e "<dev>" ]`: waiting for a
  device is a **node event**, not a duration.
- Queue hooks: `initqueue --onetime/--settled/--finished/--timeout`; bounded
  retries via `rd.retry` (×2) and `rd.timeout`.
- `udevadm wait DEV --timeout=N --initialized` (systemd ≥ 250; present in our
  initramfs at `usr/bin/udevadm`, verified inside `initramfs-fix.img`) — wait
  for a specific node.
- Probe ordering is the kernel's job (`EPROBE_DEFER`, device links, fw_devlink),
  not userspace timing.

**Consequence:** the sequencer's `UPTIME_S=11` and the `sleep 1` before the
rebind are both **anti-patterns** by the canon. Everything should be
event-driven, with a bounded retry.

## 2. Why "option 2" (event-based ADSP start) is not the fix [measured + inference]

The idea was: wait for the early host scan to finish, then start the ADSP — an
event instead of `uptime ≥ 11`. But the numbers say that event fires **earlier**
than the default:

| event | t |
|---|---|
| early host scan (the thing to wait for) | ~2.7 s |
| udev autoloads `qcom_q6v5_pas` (default) | ~3.0 s |
| `charger_pd` PDR (default) | ~3.498 s |

Sources: `INITRAMFS_CHANGES.md:42` (scan 2.7 s vs PDR 3.5 s) and `:69`
(`qcom_q6v5_pas` probes at ~3 s; initramfs PDR 3.498 s).

So "start the ADSP when the early scan is done" would move the ADSP start to
~2.7 s — **earlier** than doing nothing, and nowhere near the ~11 s the staging
was supposed to reproduce. Option 2 therefore replaces one arbitrary timing with
another, and an earlier one. [inference]

The parts of "2+3+4" that are actually valuable are **3** (`udevadm wait` instead
of `sleep 1`) and **4** (verify + bounded retry); both are orthogonal to the ADSP
question and can be combined with the minimal build.

## 3. Minimalism (drop the staging) vs option 2 [inference from measured numbers]

| axis | minimalism 1+3+4 | "2"+3+4 |
|---|---|---|
| ADSP start | udev ~3.0 s (later) | ~2.7 s (earlier) |
| rebind trigger | `udevadm wait /sys/class/typec/port0` | same |
| retry / `-110` guard | yes | yes |
| reproduces T+11 | no | **no** |
| complexity | least | +a useless event-start |

The only thing minimalism gives up is the **absolute** timing of the full system
(PDR ~3.5 s vs ~12.5 s) — i.e. the "late, clean PPM / ABL session already over"
hypothesis (lever A), which has **never been isolated**. That is precisely the
hypothesis minimalism tests. Option 2 does not test it either.

**Cost of minimalism:** the unbind→rebind window shrinks to ~0.9 s (2.7→3.6)
against ~10 s with `T+11` — so the verify+retry with the `-110` guard is
**mandatory**, not optional.

## 4. Decision [inference]

Adopt **1+3+4**:

1. drop the ADSP staging (`blacklist qcom_q6v5_pas` + the `T+11` `modprobe`); let
   udev autoload the ADSP as on a normal boot;
2. keep the early unbind of the ABL `dr_mode=host` controller (discard the
   pre-PDR scan);
3. trigger the rebind on the **typec node** (`udevadm wait
   /sys/class/typec/port0`), not `sleep 1`;
4. `udevadm settle` before the unbind and before the rebind; after the rebind,
   verify that a block device appeared and, if not **and** dmesg shows **no**
   `-110`, retry once or twice (bounded).

This is the best first experiment: it isolates whether a single reordering (PDR
before scan) is sufficient without reproducing the full-system timing, and it is
no worse than option 2 on any axis except the (unvalidated) lever A.

The deterministic long-term path remains kernel patch 1400 (the kernel orders the
probe itself — no timers, no races): `KERNEL_PATCH_1400.md`.

## References

- `INITRAMFS_CHANGES.md` — the A–D plan, the dbgB run, the 2026-11-11 control
  boot result
- `FULL_SYSTEM_PREPLUG_SOURCE_ROLE.md` — the 2026-11-11 control boot (E)
- `EXTERNAL_PRIOR_ART.md` — the web round (upstream corroboration)
- `KERNEL_PATCH_1400.md` — the deterministic kernel-side alternative
- local canon (this machine): `modules.d/77initqueue/dracut-initqueue.sh`,
  `modules.d/80base/dracut-lib.sh`, `modules.d/80base/dracut-dev-lib.sh`,
  `man 8 udevadm`
