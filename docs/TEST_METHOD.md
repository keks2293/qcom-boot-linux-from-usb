# Test Method

## Environment

- Device: Retroid Pocket 6 (QCS8550 / SM8550)
- OS: Armada OS
- Boot mode: ABL `linux usb` (unless the experiment says `normal`)
- Primary case: the drive is **connected before power-on (pre-plug)**, in the
  **normal orientation**, with **zero user actions** after power-on.
  Cold-plug and replug are comparison variants only.

## The run protocol

1. **Pick the image.** One image per experiment; never overwrite a previous
   image file (the filename is the provenance marker). Builders and the
   current hook live in [`scripts/lever-c/`](../scripts/lever-c/).
2. **Flash and verify.** Copy to the FAT32 stick as `KERNEL`, then:
   - `md5` **both sides** and compare (a run in 2026-11 was invalidated
     because the stick still held the previous image);
   - write `KERNEL.md5` as `<md5>  target/KERNEL`;
   - remove AppleDouble files (`._*`) — the stick is written from macOS;
   - check the first bytes are `ANDROID!` (`xxd -l 8`);
   - `diskutil eject` and re-plug into the device.
3. **Boot.** Stick pre-plugged, normal orientation, ABL → `linux usb`, **no
   button presses**. Read the `orientation=` line in the dump **first** — a
   `reverse` run is a confound and must be repeated.
4. **Read the verdict** from the console (`ARMADA-C:` lines are printed at
   `<0>` priority, so they survive `quiet`): `ENUMERATION OK` /
   `FAIL-NO-SCAN` / `FAIL-NO-SCAN-FULL`, plus the diagnostic block of that
   hook version.
5. **Record** the run as a new `EXP-NNN` in
   [`EXPERIMENTS.md`](EXPERIMENTS.md) — including invalid runs, with the
   reason. Add the console transcript to `logs/` when it carries the
   evidence.

The process rules that came out of the invalid runs (md5 after flashing,
orientation first, no hard-coded sysfs driver paths, an empty scan is a
datum) are in [`EXPERIMENTS.md`](EXPERIMENTS.md) §1.5.

## Custom KERNEL images (initramfs diagnostics)

Each image is the CI Android boot image plus one hook file inside the dracut
initramfs:

```
var/lib/dracut/hooks/initqueue/91-armada-usb-fix-c.sh
```

Dracut sources that directory about every 0.5 s, so a hook must be
idempotent: done-marker, `_ac_`-prefixed variables, a background subshell,
no top-level `exit`, no `set -e`/`set -u`, and inert in a normal boot.

### Image invariants (asserted by every builder)

- magic `ANDROID!` at offset 0;
- header `[20:576]` byte-identical to the base image;
- kernel byte-identical to the base;
- SHA1 id at offset 576 recomputed over kernel + ramdisk + sizes;
- initramfs round-trip: exactly one entry replaced, entry count unchanged;
- the previous hook is byte-identical to the previous version's source (a
  provenance assert, so a wrong base fails loudly).

## Tracing data collected by the hooks

- PM state: `power/control`, `power/runtime_status`,
  `power/autosuspend_delay_ms`, `power/wakeup` for `a600000.usb`,
  `xhci-hcd.<N>.auto`, `usb1`, `usb2`
- Runtime PM traces: `events/rpm/*` with `events/rpm/filter` (kernel 7.2.6)
- ADSP/ULOG fingerprints (`pmic_pdcharger_ulog` tracepoint)
- USB port state: `PORTSC`, `ccs`, attach/detach, enumeration events
- `usb_type` from `qcom-battmgr-usb`
- Link topology, role, partner and the device-tree facts
- The eUSB2 repeater register window `0xfd00–0xfd5b` (debugfs regmap)

## Full-system comparison (the control)

Run [`scripts/full-system-coldplug-test.sh`](../scripts/full-system-coldplug-test.sh)
on a full-system boot (internal storage), pre-plugged. This captures PM
state, `usb_type`, modules, typec paths, dmesg/journalctl and RPM traces.
Measured result: [`FULL_SYSTEM_PREPLUG_RESULT.md`](FULL_SYSTEM_PREPLUG_RESULT.md);
the source-role variant (the decisive control for scan ordering):
[`FULL_SYSTEM_PREPLUG_SOURCE_ROLE.md`](FULL_SYSTEM_PREPLUG_SOURCE_ROLE.md).
