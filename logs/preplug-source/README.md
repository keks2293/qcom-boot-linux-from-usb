# `logs/preplug-source/` — full-system pre-plug source-role round (2026-11-11)

Raw evidence for [../../docs/FULL_SYSTEM_PREPLUG_SOURCE_ROLE.md](../../docs/FULL_SYSTEM_PREPLUG_SOURCE_ROLE.md).
Captured with `preplug-capture.sh` (unprivileged). All timestamps are
kernel-uptime seconds (`journalctl -o short-monotonic`).

## Per-boot captures

Each directory holds `header.txt`, `typec-power.txt`, `poll.csv`, `done.txt`,
`lsblk-end.txt`, a filtered `usb-events.txt` (USB/xHCI/SCSI/PDR timeline) and a
filtered `ppm-fingerprint.txt` (PPM ULog markers).

| dir | scenario | role / orientation | outcome |
|---|---|---|---|
| [`e-normal-success-20261111-172918/`](e-normal-success-20261111-172918/) | **full system, pre-plug, direct stick** | source / **normal** | **✓** PDR 12.454 s → scan 12.787 s → device 13.05 s → `sdg` 14.21 s |
| [`d-reverse-preplug-20261111-170417/`](d-reverse-preplug-20261111-170417/) | full system, pre-plug, direct stick | source / **reverse** | ✗ in the 180 s window (`ConnectStatus=0`); spontaneous connect at 464 s (see watcher) |
| [`a-dock-reverse-20261111-162720/`](a-dock-reverse-20261111-162720/) | full system, PD dock | source / reverse | ✓ hub 14.19 s, drive behind hub 96.68 s |
| [`g-dock-normal-20261111-174454/`](g-dock-normal-20261111-174454/) | full system, PD dock | source / normal | ✓ dock + Netac behind hub |

`e-normal-success-…/ppm-ulog-boot.full.log` is the **complete** boot-time PPM
ULog drain for the decisive success boot (the `ppm-fingerprint.txt` there is the
filtered excerpt).

> Note: `a-dock-reverse` and `d-reverse-preplug` carry a **byte-identical**
> `ppm-ulog-boot.log` (md5 `7751776d…`). The ULog copy is the boot-time one-shot
> `/var/tmp/adsp-ulog-capture.log`; on the 17:04 boot it was not regenerated, so
> the D PPM fingerprint is **not** independently available from that file. The
> source-role fingerprint is established by the E boot (fresh, md5 `f24a7c8d…`).

## Watcher logs (`dmesg -w`)

| file | covers | key markers |
|---|---|---|
| [`bc-roleswitch-110-watch-20261111.log`](bc-roleswitch-110-watch-20261111.log) | B (hot-plug) + C (re-plug) in a live source-role session | `2873.5` / `2874.66` / `5862.99` `Host halt failed, -110` + `probe with driver xhci-hcd failed with error -110` |
| [`d-reverse-spontaneous-flip-watch-20261111.log`](d-reverse-spontaneous-flip-watch-20261111.log) | D boot (reverse pre-plug) | `464.228` connect → `465.67` `sdg` attached; `547.33` reconnect (normal) → `548.77` `sdg` |

## Initramfs screenshot

| file | what it is |
|---|---|
| [`initramfs-dracut-timeout-20261111.md`](initramfs-dracut-timeout-20261111.md) | transcription of the user's photo of the initramfs console: PPM `usb_type=[Unknown]`/`src=[C]`/`ncp_stby` **and** `dracut-initqueue` looping on `devexists-/dev/disk/by-uuid/49a99c0a-3e…` |
| [`initramfs-dracut-timeout-20261111.raw-ocr.txt`](initramfs-dracut-timeout-20261111.raw-ocr.txt) | raw `tesseract` output (photo is noisy; the `.md` is the cleaned reading) |
