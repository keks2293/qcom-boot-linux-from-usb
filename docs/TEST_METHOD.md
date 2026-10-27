# Test Method

## Environment

- Device: Retroid Pocket 6 (QCS8550 / SM8550)
- OS: Armada OS
- Boot mode: ABL `linux usb`
- Test: cold-plug USB flash drive with zero user actions

## Custom KERNEL images (initramfs diagnostics)

Each iteration produced `KERNEL.ci-<base>-dbgXX` Android boot images with diagnostics injected into `usr/bin/dracut-initqueue` inside the initramfs cpio. Raw diagnostics and screen captures were collected from photos of the diag screen.

### Repacking

Repacking tools are in `diag/` outside this repo (`repack_adsp_dbgN.py`, `cpio.py`). General process:

1. Start from a clean base KERNEL image.
2. Extract and modify only `usr/bin/dracut-initqueue` in the initramfs cpio.
3. Repack initramfs cpio.
4. Recalculate Android boot image SHA1 ID at offset `0x240-0x25F`.
5. Preserve Android boot header invariants (magic `ANDROID!` at start; header bytes outside the recalculated ID remain consistent with base where required).
6. Verify only intended changes were made.

### Verification

Before writing to flash, each image was verified:

- Header diff limited to `rs@0x10` and SHA1 ID at `0x240-0x25F`
- cpio diff limited to `dracut-initqueue`
- `adsp_dtb.mbn` byte-identical unless explicitly patched (and hash recomputed only if valid)
- DTB walk OK
- Shell syntax checks: `bash -n`, `dash -n`
- All PM sysfs accesses use `power/` prefix
- Initramfs remains valid (no truncation of `dracut-initqueue`)

### Boot protocol

1. Write `KERNEL` to the USB/boot media visible to ABL (e.g. `/Volumes/ARMADA/KERNEL`).
2. Boot RP6 in `linux usb` mode.
3. Cold-plug the USB flash drive at boot with no user actions.
4. Photograph the diag screen showing iteration markers and verdict.
5. Parse markers from photos (topology, PM state, RPM traces, ULOG, enumeration timeline).

## Tracing

Collected data included:

- PM state: `power/control`, `power/runtime_status`, `power/autosuspend_delay_ms`, `power/wakeup` for `a600000.usb`, `xhci-hcd.0.auto`, `usb1`, `usb2`
- Runtime PM traces: `events/rpm/*` using `events/rpm/filter` (kernel 7.2.6)
- ADSP/ULOG fingerprints
- USB port state: `PORTSC`, `ccs`, attach/detach, enumeration events
- `usb_type` from `qcom-battmgr-usb` (cell(ii))
- Link topology and device tree facts

## Full-system test (cell(ii))

For comparison with initramfs behavior, run [`scripts/cell-ii.sh`](../scripts/cell-ii.sh) on a full system boot (internal storage) after cold-plugging the USB flash drive. This captures PM state, `usb_type`, modules, typec paths, dmesg/journalctl, and RPM traces if available.
