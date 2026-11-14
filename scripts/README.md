# Scripts

## full-system-coldplug-test.sh

Run on a full system boot (internal storage). The primary variant is
**pre-plug** (drive connected before power-on); post-plug/cold-plug is the
secondary variant.

```bash
chmod +x full-system-coldplug-test.sh
./full-system-coldplug-test.sh > full-system-coldplug-test.log 2>&1
# optional: OUTDIR=/tmp/out ./full-system-coldplug-test.sh
```

The sysfs controller paths are discovered dynamically (`soc@0/a600000.usb`,
`xhci-hcd.<N>.auto`), because the old hard-coded
`/sys/devices/platform/a600000.usb/xhci-hcd.0.auto` paths do not exist on
kernel 7.2.6.

Collects:
- PM state of `a600000.usb`, `xhci-hcd.<N>.auto` and the root hubs
- `usb_type` from every power supply that exposes it (key)
- modules, typec/role paths
- dmesg/journalctl around enumeration
- RPM trace tail if available
- kernel config snippets

Attach the generated log to any report.

## boot-deferred-sampler.sh + .service — boot-time deferred-probe sampling

Answers Q1 of the mechanism capture (does any supplier hold
`soc@0/a600000.usb`?): `/sys/kernel/debug/devices_deferred` is empty once
boot is finished, so it must be sampled *during* boot. Result: nothing holds
it — the host controller is only created when the Type-C role flips to HOST,
3–4.4 s after the `charger_pd` PDR (see
[`../docs/FULL_SYSTEM_MECHANISM_CAPTURE.md`](../docs/FULL_SYSTEM_MECHANISM_CAPTURE.md)).

```bash
# on the device (as root; /usr/local is read-only on this ostree system)
sudo install -D -m0755 scripts/boot-deferred-sampler.sh /var/lib/boot-deferred-sampler/boot-deferred-sampler.sh
sudo install -D -m0644 scripts/boot-deferred-sampler.service /etc/systemd/system/boot-deferred-sampler.service
sudo systemctl daemon-reload && sudo systemctl enable boot-deferred-sampler.service
# then reboot; results land in /var/tmp/boot-deferred.log
```

Reads only (plus a best-effort dynamic-debug switch on `dd.c`/`core.c`/`dwc3`/
`xhci_hcd`). Samples every 50 ms for 45 s and prints only state changes, with
kernel uptime, so each line can be matched against the `dmesg` timeline.

## usb-type-poller.sh + .service — `usb_type` transition logger

Answers "when does the port get classified?" — the transition
`Unknown → SDP` on `qcom-battmgr-usb`, stamped with kernel uptime so it lines
up with `journalctl -b -k -o short-monotonic` (PDR, role flip, first scan).
Result and interpretation: [`../docs/USB_TYPE_TIMING.md`](../docs/USB_TYPE_TIMING.md).

```bash
# on the device (as root; /usr/local is read-only on this ostree system)
sudo install -D -m0755 scripts/usb-type-poller.sh /var/lib/usb-type-poller/poller.sh
sudo install -D -m0644 scripts/usb-type-poller.service /etc/systemd/system/usb-type-poller.service
sudo systemctl daemon-reload && sudo systemctl enable --now usb-type-poller.service
# log: /var/tmp/usb-type-poller.log (rotated to .prev on each start)
```

Reads sysfs only. Samples every 50 ms; a line is written only when a *stable*
field changes (`usb_type`, `online`, `power/data` role, partner, role-switch,
USB block device) plus a 10 s heartbeat — voltage/current wobble is carried
along but does not trigger a line, so a steady boot produces ~1 line per 10 s.
Starts at `sysinit.target` (after `local-fs.target`), i.e. before the ADSP PDR.

## adsp-ulog-capture.sh + .service — the PPM's own charger log, from the AP

The kernel ships `pmic_pdcharger_ulog.ko` (no dependencies, *"loaded manually
only"* → never auto-loaded). It binds the `PMIC_LOGS_ADSP_APPS` rpmsg channel
and reads the PPM charger ULog once per second into the tracepoint
`pmic_pdcharger_ulog:pmic_pdcharger_ulog_msg` — the PPM's own view of initial
detection, ICM `ncp_stby`, and the charger state machine, with no custom dbg
firmware. Write-up and the boot-1 success-side fingerprint:
[`../docs/ADSP_ULOG.md`](../docs/ADSP_ULOG.md).

```bash
# on the device (as root; /usr/local is read-only on this ostree system)
sudo install -d -m0755 /var/lib/adsp-ulog-capture
sudo install -m0755 scripts/adsp-ulog-capture.sh /var/lib/adsp-ulog-capture/capture.sh
sudo install -m0644 scripts/adsp-ulog-capture.service /etc/systemd/system/adsp-ulog-capture.service
sudo systemctl daemon-reload && sudo systemctl enable adsp-ulog-capture.service
# then reboot; next boot drains 40 s in the background → /var/tmp/adsp-ulog-capture.log
# (CAPTURE_S env var overrides the window)
```

The 40 s dump loop runs in the background, so the `sysinit.target` unit
returns immediately and boot is not delayed. In the initramfs the same script
works after mounting tracefs — **the module is already in the stock initramfs
image**. Gotcha: never `rmmod` it in a live session — unloading tears the
rpmsg channel down and it does not come back until an ADSP restart.

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

## lever-c/ — the lever-C hook sources, harness and builder

[`lever-c/`](lever-c/) is the **complete, reproducible** lever-C toolchain
(EXP-028…037): hook versions v2…v8 (`armada-usb-fix-c2.sh`…`-c8.sh`), the
lever-B v2 prerequisite hook, one image builder per step
(`build_dbgB2_ci.py`, `build_dbgC2_ci.py`…`build_dbgC8_ci.py`), the cpio
helper they share, and `fake-test-c8.sh` — a fake-sysfs harness for v8 with
11 boot modes (no root, no device).

See [`lever-c/README.md`](lever-c/README.md) for the build chain, how to get
the CI base image, the dump geometry and the run protocol.
