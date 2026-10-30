# UCSI/PPM command flow: AP UCSI core → glink → ADSP PPM → PMIC doorbell

Who sends what between the AP and the PPM, which PPM commands actually reach
the PMIC, and why the command set is small and closed. All addresses are
`adsp.mbn` vaddrs (evidence:
[`../logs/adsp-re/ppm-ucsi-dispatch-table.txt`](../logs/adsp-re/ppm-ucsi-dispatch-table.txt),
[`../logs/adsp-re/ppm-doorbell-callers.txt`](../logs/adsp-re/ppm-doorbell-callers.txt),
[`../logs/adsp-re/func-connector-reset-600d8620.txt`](../logs/adsp-re/func-connector-reset-600d8620.txt)).

## The protocol: plain UCSI, no renumbering

The AP↔ADSP command numbers are the **standard UCSI numbers**
(kernel `drivers/usb/typec/ucsi/ucsi.h:112-144`) — the PPM dispatch table
reconstructed from the disassembly matches them 1:1. There is **no vendor
permutation**; the QTI vendor driver `ucsi_qti_glink.c` (public, OnePlus
SM8850 tree) also passes the core commands through without remapping.

Command word layout (`ucsi.h:146-154`):

```
 bits[ 7: 0] = command number
 bits[23:16] = connector number   (UCSI_CONNECTOR_NUMBER = num << 16)
 bit   23    = CONNECTOR_RESET hard-reset flag (v1.0: hard; v2.0: data reset)
```

## The AP actor: the in-kernel UCSI core (not a userspace service)

The client that sends these commands over glink is the **UCSI core**
(`ucsi.c` + `ucsi_glink.c`, all `=y` in the armada config). There is no
userspace daemon and no separate glink client — the 4-zone actor hunt
(see [../docs/INVESTIGATION.md](../docs/INVESTIGATION.md)) searched the
wrong place: the actor is a kernel built-in and exists in **every**
environment (initramfs, full system, third-party rootfs).

`ucsi_glink` ops: synchronous = `ucsi_sync_control_common` (write
`UCSI_MESSAGE_OUT`), asynchronous = write `UCSI_CONTROL` (used for
`UCSI_PPM_RESET`). glink opcodes: 0x11 read-buf request, **0x12 write-buf
request (the command channel)**, 0x13 USB-C notify indication (ADSP→AP).

Whether the core is **active or deferred** depends on the device tree, not
on the environment:

- **active** — `connector@0` has no `usb-role-switch` property reachable
  through the `usb@a600000` graph node: the full UCSI handshake completes
  (PPM_RESET, SET_NOTIFICATION_ENABLE, GET_CAPABILITY, port registration,
  partner registration). This is the state of the spliced diagnostic images
  (dbg12+).
- **deferred** — the property is present and the role-switch class is empty
  (no registrant on this board, dwc3 is host-only):
  `ucsi_register_port` → `fwnode_usb_role_switch_get` →
  `-EPROBE_DEFER` → 100 retries × 100 ms → `"PPM init failed, stop trying"`
  → the AP stops sending UCSI commands (only the boot-time reset storm of
  `UCSI_PPM_RESET` 0x01 remains). This is the state of the un-spliced
  stock/CI images — in the **working full-system environment the UCSI core
  is therefore deferred**, and the enumeration path is PPM **autonomy** on
  the fresh CC edge, not an AP command.

The four commands that ring the PMIC doorbell and **where the core sends
them** (kernel v7.2.6 line refs):

| PPM cmd | Name | Sent by (ucsi.c) | Condition |
|---|---|---|---|
| 0x09 | SET_UOR | `ucsi_dr_swap` :1725-1728, via `typec_set_data_role` from `ucsi_partner_change` :1334-1348 | **only if `PARTNER_TYPE` ∈ {UFP, CABLE, CABLE_AND_UFP, DFP}; `PARTNER_TYPE = 0` (USB2) → `default: break` → not sent** |
| 0x0b | SET_PDR | `ucsi_pr_swap` :1767-1770 | on power-role swap requests |
| 0x10 | GET_PDOS | `ucsi_register_partner` :1279-1280 → `ucsi_read_pdos` :873 | **only if `PWR_OPMODE == PD`** |
| 0x03 | CONNECTOR_RESET | recovery path `ucsi_role_cmd` :1687-1697 → `ucsi_reset_connector` :1594-1606 (plus `UCSI_PPM_RESET` 0x01 + `SET_NOTIFICATION_ENABLE` via async `UCSI_CONTROL`) | after **any** role command returns `-ETIMEDOUT` |

## The whole chain (disassembly-verified)

```
AP (Linux v7.2.6)
  UCSI core ucsi.c (0x09 / 0x0b / 0x10 / 0x03)
    │  ucsi_glink.c: sync = UCSI_MESSAGE_OUT write, async = UCSI_CONTROL write
    ▼
glink channel (pmic_glink) — opcode 0x12 = UC_UCSI_WRITE_BUF_REQ
    │
    ▼
ADSP (adsp.mbn)
  RX handler ppm_ucsi_mailbox_write 0x600d60d0
    ├─ gate memb(0x603286b4) (UCSI-enable; set by the ADSP itself at service
    │  registration, 0x600d39a8, single write-site, never cleared — set in
    │  BOTH environments, not a discriminator)
    ├─ copy cmd(8 B) → 0x60328688, data(16 B) → 0x603286a0
    ├─ log "PPM: UCSI Write, Command=0x%02X" (fmt 0x6020c42d)
    ├─ EVERY write also rings the PMIC: 0x600cc190(handle, 0xb) → 0x6019cd40
    │  (handle, 0x16) → 0x600810b0 → 0x60003094(handle, 0x16)
    ▼
  UCSI WRITE dispatcher 0x600d4830 (vtable slot svc->+0x24)
    idx = memub(0x60328688) - 2, bounds 0..0x11, jump table 0x6020c29c:

    0x03 CONNECTOR_RESET ──────► 0x600d8620 ─┐
    0x09 SET_UOR ──────────────► 0x600d87f0 ─┤
    0x0b SET_PDR ───────────────► 0x600d8f30 ─┼► call ppm_set_request_to_lpm
    0x10 GET_PDOS ──────────────► 0x600d7fb0 ─┘   0x600da6d0
                                                    "Relay OPM request to LPM"
    0x02/0x05/0x06/0x07/0x0d/0x0e/0x12/0x13     │   (the ONLY 4 callers in
    ─► 0x600d4948 → immediate 0x600d75e0        ▼    the whole firmware)
       (sub-table 0x6020c304, 18 entries,    0x600ccb80 per-port (stride 0xf8)
        real: 0x02/0x05/0x06/0x07/0x0d/0x0e/  ▼
        0x12 GET_CONNECTOR_STATUS → 0x600d7b54, 0x600da940 → 0x6019cd40
        0x13 GET_ERROR_STATUS → 0x600d7e88;     (handle, 0x20)
        rest stubs 0x600d7f7c)                 ▼
    0x04 ACK_CC_CI ─► 0x600d7230               0x600810b0
    0x0c GET_ALTERNATE_MODES ─► 0x600d96d0      ▼
    0x08/0x0a/0x0f/0x11 ─► error 0x600d4a74     0x60003094(handle, 0x20)
                                                       glink DOORBELL to the
                                                       PMIC: OR bit 0x20 into
                                                       the 64-bit shared cmd
                                                       bitmap (CAS) +
                                                       trap0(#0x11)
    ▼
PMIC (PM8550B): OPM request → PD (re)start → fresh CC/PD HW event
  → HW IRQ → charger-detection SM re-classifies → property 0x270b push
  → ICM leaves icm_ncp_stby (see [icm-state-machine.md](icm-state-machine.md))
```

The CONNECTOR_RESET handler (0x600d8620) is elementary — it does **not**
touch CC/ICM state directly:

- `port = cmd_buf[2] & 0x7f`, valid 1..4, else error 0x202; hard = bit 23
- log `"Info: %s: CONNECTOR_RESET: Port[%d], HardReset=%d"` (fmt 0x6020d6ef,
  name 0x6020d721: `ppm_proccess_connector_reset_command` — typo verbatim)
- `ctx->+0x1ca = hard ? 0x0a : 0x09`, `ctx->+0x1c8 = 1`, `ctx->+0x1c9 = port-1`
- `call 0x600da6d0` (the doorbell chain above)
- mailbox op 7 (0x600d5c20); return 0

The effect is entirely on the PMIC side (firmware not RE-able here).

## Why dbg31/dbg32 looked "dead" even though the actor is present

In the **active** initramfs runs (spliced DTB, dbg12+) the UCSI core fired
the commands and the PPM processed them (it answered with errors/timeouts):

| command (dbg31/32, word) | decode | result |
|---|---|---|
| `0x00010003` | CONNECTOR_RESET, port 1 | rc=0, handler completed **including the doorbell** — but the PMIC had nothing to re-detect (no fresh CC event; port misclassified as `PARTNER_TYPE=0` USB2) |
| `0x00800003` | CONNECTOR_RESET + **hard**, port `0x80 & 0x7f` = **0 → invalid** | confounded experiment: the hang was a reset of a **nonexistent port 0** (handler rejects it), not necessarily the hard-reset semantics |
| `0x00020003` | CONNECTOR_RESET, port 2 | (no-op) |
| `SET_PDR` (dbg31) | power-role swap to sink | PPM error `UCSI_ERROR_CC_COMMUNICATION_ERR` (bit 4) → `-ECOMM` |
| `SET_UOR` ×2 (dbg31) | data-role swap | PPM never completes → `-ETIMEDOUT` |
| `GET_PDOS` (auto, boot) | sent because BEFORE showed `power_operation_mode=usb_power_delivery` | part of the normal boot sequence in **both** environments |

The core also **refuses to send SET_UOR by itself** when the PPM classifies
the partner as `PARTNER_TYPE = 0` (USB2) — exactly what the PPM does in the
failing environment (`ucsi_partner_change` `default: break`).

**Consequence:** the discriminator between the working (full system) and the
failing (initramfs) environment is **not the presence or absence of an AP
actor**. With the UCSI core *active* (spliced initramfs images) it fires the
doorbell commands and the wedge still persists — the PMIC has no fresh CC
event to re-detect, the port is misclassified as USB2, role commands are
refused with a CC communication error, and the ICM stays in `icm_ncp_stby`
until the charger type is updated
([charger-type-chain.md](charger-type-chain.md)). With the UCSI core
*deferred* (un-spliced stock/CI images, including the working full-system
environment) the AP sends no doorbell commands at all — and enumeration
still works there, driven purely by **PPM autonomy on the fresh CC edge**
(cold plug after boot). Either way the re-arm is a **PPM/PMIC state**
question: a fresh CC edge (replug ≤ ~24.7 s, cold plug) or a PMIC-side
re-run (`apsd-rerun-cfg`,
[../docs/ADSP_CONFIG.md](../docs/ADSP_CONFIG.md)) is what re-arms
detection.

## Cross-references

- ADSP RE with the dispatcher/RX/doorbell evidence: [../docs/ADSP_RE.md](../docs/ADSP_RE.md#the-ucsi-ppm-command-protocol-ap--adsp)
- The wedge state the doorbell is supposed to clear: [icm-state-machine.md](icm-state-machine.md)
- Charger-type chain and the levers: [charger-type-chain.md](charger-type-chain.md)
- AP↔ADSP layer placement: [architecture.md](architecture.md)
- Raw run evidence: [../logs/dbg31-role-swap-refused.txt](../logs/dbg31-role-swap-refused.txt), [../logs/dbg32-connector-reset.txt](../logs/dbg32-connector-reset.txt)
