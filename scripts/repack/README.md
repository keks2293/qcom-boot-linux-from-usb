# Repack helpers (minimal)

Minimal tooling to understand how the diagnostic `KERNEL.ci-*-dbgXX` images were built.

## Files

- [`cpio.py`](cpio.py) — simple cpio (newc) reader/writer used to extract/replace `usr/bin/dracut-initqueue` in the initramfs and repack it.

## Approach (summary)

1. Extract Android boot image (kernel, ramdisk/initramfs, DTB) using standard tools.
2. Unpack initramfs cpio (newc) with `cpio.py`.
3. Replace only `usr/bin/dracut-initqueue` with a modified version containing diagnostics/experiments.
4. Repack initramfs cpio.
5. Rebuild Android boot image: update ramdisk bytes, recalculate SHA1 ID at `0x240-0x25F`, preserve header invariants (magic `ANDROID!`).
6. Verify: header diff limited to `rs@0x10` and ID, cpio diff limited to `dracut-initqueue`, shell syntax checks, PM paths use `power/` prefix.

See [`docs/TEST_METHOD.md`](../../docs/TEST_METHOD.md) for full details. The full `repack_adsp_dbgN.py` scripts are not included as they are tightly coupled to local paths and specific diag blocks.
