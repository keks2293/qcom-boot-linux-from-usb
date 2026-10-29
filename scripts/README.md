# Scripts

## full-system-coldplug-test.sh

Run on full system (internal boot) after cold-plugging USB flash drive.

```bash
chmod +x full-system-coldplug-test.sh
./full-system-coldplug-test.sh > full-system-coldplug-test.log 2>&1
```

Collects:
- PM state of `a600000.usb` and `xhci-hcd.0.auto`
- `usb_type` from `qcom-battmgr-usb` (key)
- modules, typec/role paths
- dmesg/journalctl around enumeration
- RPM trace tail if available
- kernel config snippets

Attach the generated log to any report.

## adsp-re/ — PPM firmware RE toolchain

Tools used to reverse-engineer the PPM/ADSP firmware (`adsp.mbn`, a 32-bit
little-endian Hexagon ELF with no section headers). All RE claims in
[`../docs/ADSP_RE.md`](../docs/ADSP_RE.md) are reproducible with these:

- `dump_adsp.sh` — `llvm-objdump --triple=hexagon -d adsp.mbn > text_all.txt`
  (whole file; `--start-address/--stop-address` are broken on this ELF).
  Requires a LLVM with the Hexagon backend (e.g. Homebrew LLVM ≥ 17).
- `adsp_elfmap.py` — print the PHDR map (file↔vaddr). Key segment:
  PT_LOAD#19 file `[0xa93000:0xcd67c4]` ↔ vaddr `[0x60000000:0x602437c4]`,
  so `vaddr = 0x60000000 + (fileoff − 0xa93000)`.
- `extract_func.py <vaddr>` — cut the function enclosing a site
  (`allocframe`…`dealloc_return` boundary) into `func_at_<vaddr>.txt`.
- `vaddr2str.py <strings-file> <vaddr>…` — resolve a code-referenced vaddr
  to the string at that file offset (avoids manual conversion errors).

Xref method: `grep '##0x<vaddr>' text_all.txt`. Gotcha: `= ##0xADDR` matches
register *loads*, not memory *writes* — direct writes are
`memw/memb/memh/memd(##0xADDR) = …`.
