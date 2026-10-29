# ADSP container and PPM configuration

What the `adsp_dtb.mbn` container holds, how it is laid out and signed, and the
PPM (Platform Policy Manager) configuration values that matter for the
cold-plug problem. All offsets below were verified byte-for-byte against the
stock RP6 `adsp_dtb.mbn` (16 184 B, md5 `395b86387251969f32e974d616c085be`);
the dtc-readable FDT dump is in
[`logs/adsp-re/ppm-fdt-rp6.dts`](../logs/adsp-re/ppm-fdt-rp6.dts).

## MBN container layout (verified)

| MBN offset | size | content |
|---|---|---|
| 0 | 148 | junk ELF-ish header (magic `4c454c7f`-style, `ehsize=3`, `phnum=0` — not parseable as ELF; the container is identified by the FDT magic only) |
| 148 | 60 | segment-1 header: magic `CFLG` (`43 46 47 4c`), then `02 00 01 00 3c 00 00 00` (segment size field = 0x3c00 = 8376) |
| 208 | 8315 | **FDT payload** (magic `d00dfeed`, version 17, 216 properties) — the PPM configuration |
| 12576 | 48 | `sha384(d[0:148])` — hash slot for segment 0 (verified equal) |
| 12624 | 48 | `sha384(d[148:148+8376])` — hash slot for segment 1, i.e. over the FDT region (verified equal) |
| 12720 | … | ECDSA P-384 signature + certificate chain |

FDT header fields: `off_dt_struct=56`, `off_dt_strings=5648`, `off_dt_rsvmap=40`.
Note: the string table is the region `[5648 : 8315]` (2667 bytes); the 4th
header field (0x28) is the rsvmap pointer, **not** a strings size. A naive
parser that reads it as `stringsz` will find 40 bytes and parse nothing.

The FDT describes the PPM configuration tree:

```
/sw/core/pmic/battman/
├── charger_cfg/{chg_det_cfg, chg_icm_cfg, chg_idt_cfg, chg_lpd_cfg,
│                jeita_cfg, led_cfg, mtc_chg_cfg, pl_chg_cfg,
│                therm_thresh_cfg, wls_chg_cfg}
├── gauge_cfg
├── platform_cfg/{batt_auth_cfg, beh_cfg, chg_table_cfg, esd_cfg, offmode_cfg}
└── usbpd_cfg/{lpm_cfg, pd_policies_cfg, pd_static_info_cfg, tcpc_cfg,
               ucsi_cap_cfg, ucsi_conn_cap_cfg}
```

## Key configuration values (verified offsets)

Offsets `DTB+N` are relative to the FDT payload start (MBN+208); `MBN+N` is
the absolute file offset. All values were re-read from the raw bytes with a
parser that reproduces the `dtc` dump exactly (216 properties).

### `chg_det_cfg` — charger-detection config (the `apsd-rerun-cfg` lever)

| property | value | value @DTB+ | value @MBN+ |
|---|---|---|---|
| `en-apsd-pwr` | 1 | 2168 | 2376 |
| `en-usb-phy-cfg` | 1 | 2184 | 2392 |
| `qc-det-cfg` | 2 | 2200 | 2408 |
| `dam-hc-override` | 0 | 2216 | 2424 |
| **`apsd-rerun-cfg`** | **0** | **2232** | **2440** |
| `bm-hw-poff-ctrl` | 3 | 2248 | 2456 |

`apsd-rerun-cfg = 0` disables the firmware's APSD (Auto Power Source
Detection, the BC1.2 port-type detection) re-run mechanism, even though the
firmware contains the full mechanism (see
[ADSP_RE.md](ADSP_RE.md#the-apsd-rerun-levers)).

### `chg_icm_cfg`

| property | value | value @DTB+ | value @MBN+ |
|---|---|---|---|
| `force-eoc-5v` | 0 | 2300 | 2508 |
| `ptm-cfg` | 2 | 2316 | 2524 |

### `ucsi_cap_cfg` — the PPM's UCSI GET_CAPABILITY answer

| property | value | value @DTB+ | value @MBN+ |
|---|---|---|---|
| `attributes` | 0x4046 | 2576 | 2784 |
| `bc-ver` | 0x120 (BC 1.20) | … | … |
| `pd-ver` | 0x300 (PD 3.0) | … | … |
| `typec-ver` | 0x130 (Type-C 1.3) | … | … |
| `conn-num` | 1 | … | … |
| `en-alt-mode` | 0 | … | … |

`attributes = 0x4046` (UCSI 2.0 `bmAttributes` + `bmPowerSource`), decoded:

- bit 0 Disabled State Support = 0
- bit 1 **Battery Charging = 1** (BC 1.20)
- bit 2 **USB Power Delivery = 1** (PD 3.0)
- bit 6 **USB Type-C Current = 1** (Type-C 1.3)
- bit 14 (bmPowerSource) **Uses VBUS = 1**

### `tcpc_cfg` — port0 (port array, 4 cells each)

| property | port0 | value @DTB+ | value @MBN+ |
|---|---|---|---|
| `en-snk` | 1 | 3652 | 3860 |
| `en-src` | 0 | 3680 | 3888 |
| `en-port-cfg-ovr` | 0 | 3540 | 3748 |
| `en-lpd` | 1 | … | … |
| `pmic-idx` | 7 | … | … |
| `src-rp-val` | 1 | … | … |
| `vbus-rampdown-wait-ms` | 0x14 | … | … |

### `platform_cfg` — internal PPM timers

| property | value | value @DTB+ | value @MBN+ |
|---|---|---|---|
| **`chg-heartbeat-timer-ms`** | **0x7530 = 30 000 ms (30 s)** | 448 | 656 |
| `dischg-heartbeat-timer-ms` | 0x493e0 = 300 000 ms | 464 | 672 |
| **`poll-timer-ms`** | **0x9c40 = 40 000 ms (40 s)** | 480 | 688 |
| `chg-done-timer-ms` | 0x1ac7780 = 28 000 000 ms | 496 | 704 |
| `wd-timer-ms` | 0x40 = 64 ms | 592 | 800 |

### `pd_policies_cfg`

| property | value | value @DTB+ | value @MBN+ |
|---|---|---|---|
| `pan-ack-tmout-ms` | 0x32c8 = 13 000 ms | 3212 | 3420 |
| `dr-swap-policy` / `pr-swap-policy` | 3 / 3 | … | … |
| `snk-cap-size` | 5 | … | … |
| `src-cap-size` | 1 | … | … |

### `chg_lpd_cfg`

| property | value | value @DTB+ | value @MBN+ |
|---|---|---|---|
| `cooldown-time-s` | 0x3c = 60 s | 2468 | 2676 |
| `holdoff-time-ms` | 0x190 = 400 ms | … | … |

## Timer ↔ replug correlation

The measured cold-plug behavior (zero actions, `linux usb` mode, same stick)
is window-dependent:

| replug delay after power-on | result |
|---|---|
| ≤ ~24.7 s | enumerates (multiple runs) |
| ≥ ~38 s | fails (multiple runs, up to ~102 s) |

The ~30 s boundary correlates numerically with `chg-heartbeat-timer-ms =
30 000` (and the ~40 s failure start with `poll-timer-ms = 40 000`). This is a
**correlation, not a proof**: the timers are internal to the PPM firmware and
need not track AP time. It is recorded as a config fact; the causal mechanism
is part of P-06. See [INVESTIGATION.md](INVESTIGATION.md) for the full run
table.

## The 1-byte patch recipe (verified by trial patch)

To enable the APSD re-run mechanism:

1. In `adsp_dtb.mbn`, the `apsd-rerun-cfg` value word is the big-endian u32 at
   **MBN+2440** (currently `00 00 00 00`). To set it to `<0x01>`, flip the
   byte at **MBN+2443** (the last byte of the word) from `0x00` to `0x01`.
   (Flipping MBN+2440 would produce `0x01000000` — the wrong value.)
2. Recompute the segment-1 hash slot: `sha384(d[148 : 148+8376])` → write the
   48-byte digest at **MBN+12624**.
3. Do **not** touch the ECDSA signature @12720 or the segment-0 slot @12576.

Total change vs stock: 49 bytes (1 FDT byte + 48 hash bytes).

Precedent that a patched `adsp_dtb.mbn` boots: the dbg37 build applied exactly
this container procedure (with the `tcpc_cfg` `en-snk`/`en-src` swap instead
of the `apsd-rerun-cfg` byte) and the device booted and ran — i.e. the
TZ/ABL side accepts a re-hashed segment without re-signing. The `apsd-rerun-cfg=1`
patch itself is **not yet tested on device** (candidate dbg52, see
[INVESTIGATION.md](INVESTIGATION.md)).

The other config levers identified (lower priority): `en-port-cfg-ovr` 0→1
(MBN+3748), `dam-hc-override` 0→1 (MBN+2424), `ptm-cfg` 2→? (MBN+2524).

## Cross-firmware comparison

The FDT payload (8315 B @MBN+208) is **byte-identical across all 7 public
sm8550 variants** (md5 `f7c72c64f8f7e0a75e5791ed973ea766`) — the containers
differ only in signing data, so there is no "known-good" configuration to
copy. The newer SM8650 (kaanapali) firmware carries the same
`apsd-rerun-cfg = 0` and the same `attributes = 0x4046`; the older SM8380
stack has no `apsd-rerun-cfg` at all. Full md5 registry and details:
[`logs/adsp-re/cross-firmware-compare.txt`](../logs/adsp-re/cross-firmware-compare.txt).
