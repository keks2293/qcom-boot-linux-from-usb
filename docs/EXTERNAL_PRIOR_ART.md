# External prior art and corroboration (web search, 2026-11-11)

Status: search round run at the user's request ("maybe someone already solved
this"). Nothing found describes the *exact* RP6 `linux usb` pre-plug failure,
but **two upstream threads match our own measurements precisely**, and the
bootloader that provides `linux usb` (ROCKNIX-ABL) documents USB boot as a
maintained feature. This document records what is out there and how it maps onto
the local findings; it changes no conclusion, it **corroborates** two of them.

Everything below is external (other people's code/reports); our own measured
numbers are quoted only to show the match. `websearch` was HTTP-403 throughout,
so all of this was gathered with `webfetch` (DuckDuckGo HTML + GitHub/LKML).

## 1. The `qmp-combo` Type-C callback runtime-PM bug — direct match to our `-110`

**LKML, Oleg Keri, 2026-09-16: `[PATCH v2 0/2] phy: qcom: qmp-combo: keep the
Type-C callbacks off unclocked registers`** (v3 posted same day).

- https://lkml.org/lkml/2026/9/16/1519 (v2 0/2)
- https://lkml.iu.edu/hypermail/linux/kernel/2609.2/01276.html (mirror, 0/2)
- https://lkml.iu.edu/hypermail/linux/kernel/2609.2/01277.html (mirror, 2/2)
- https://lkml.org/lkml/2026/9/16/1617 (v3 0/2)

The commit message names **our exact warning**, from **our exact code path**:

> Patch 1: the callbacks hold no runtime PM reference, so releasing the clocks
> during the teardown can drop the device's last reference and re-enter
> `qmp_combo_runtime_suspend()` from `clk_core_unprepare()`, which then disables
> clocks that are already being torn down. **Seen as "`gcc_usb3_prim_phy_pipe_clk`
> already disabled" warnings from the `pmic_glink_altmode_worker`** on a Lenovo
> Yoga Slim 7x Gen 11 (Snapdragon X2 Elite) once runtime PM is allowed from
> userspace.

Local measurement it matches (see
[FULL_SYSTEM_PREPLUG_SOURCE_ROLE.md](FULL_SYSTEM_PREPLUG_SOURCE_ROLE.md) §B/C,
`logs/preplug-source/bc-roleswitch-110-watch-20261111.log`):

```
WARN ... gcc_usb3_prim_phy_pipe_clk already disabled / already unprepared
  via qmp_combo_typec_switch_set → pmic_glink_ucsi_connector_status
  → pmic_glink_altmode_worker
... a600000.usb: device_unregister
xhci-hcd xhci-hcd.2.auto: Host halt failed, -110
xhci-hcd xhci-hcd.2.auto: probe with driver xhci-hcd failed with error -110
```

**What this means.** The runtime source-role re-probe failure we measured
(`Host halt failed, -110`, bus deregistered, no recovery) is **not RP6-specific
and not our bug**: it is an **upstream `phy-qcom-qmp-combo` defect with a fix in
flight** (Sep 2026), and the clock `WARN` we saw is the same symptom on a
different Snapdragon. Patch 1 (hold a runtime PM reference in the typec
callbacks) is the relevant one; Patch 2 checks `qmp_combo_com_init()`'s return.
Earlier work in the same area: `[PATCH v4 1/4] phy: qcom: qmp-combo: Prevent
unnecessary PM runtime…` (Jul 2026) and `[PATCH 5/6] phy: qcom-qmp-combo: fix
runtime suspend` (Nov 2022).

**Consequence for the plan.** This is exactly the "separate kernel bug" caveat we
recorded for lever C: keep the post-PDR rescan a **single, early rebind**, before
the port has been through a live role switch, and do not combine it with a
runtime role change. If lever C ever trips this path, the upstream fix (or a
backport) is the remedy, not a workaround.

## 2. `dr_mode = "host"` + `usb-role-switch` — the upstream discussion behind patch 1400

**LKML, Mar 2026: "grumpy DWC3+UCSI, usb-role-switch semantics"**
(Konrad Dybcio → Thinh Nguyen).

- https://lkml.iu.edu/2603.1/12798.html (Thinh Nguyen's reply)
- https://ratatoskr.run/linux-devicetree/2026/03/3453227 (thread root, 403 to bots)

The thread describes **our exact device-tree combination**:

> in this configuration: `&usb { dr_mode = "host"; usb-role-switch; };` the role
> switch device is never registered on devices with a DWC3 controller, since
> that's handled in `dwc3_drd_init()`, which is only called if `dr_mode = "otg"`
> (or absent since otg is the default). This notably causes: `ucsi_init()` →
> `ucsi_register_port()` → `fwnode_usb_role_switch_get()` to loop in
> `-EPROBE_DEFER`.

Thinh Nguyen's conclusion: `dr_mode` is a hardware-capability property and is
independent of UCSI; the recommended path is to **not set `dr_mode = "host"`**
where UCSI is the role authority, or to teach dwc3 to register the role switch
even when `dr_mode != "otg"`.

**What this means.** This is the upstream conversation that the local **kernel
patch 1400** ("demote `dr_mode=host` → OTG when `usb-role-switch` is present",
[KERNEL_PATCH_1400.md](KERNEL_PATCH_1400.md), [ABL_DR_MODE_HOST.md](ABL_DR_MODE_HOST.md))
is an instance of. It confirms the demotion is the *upstream-blessed* direction,
not a hack.

Related, SM8550-specific: **`usb: dwc3: qcom: enable vbus override when in OTG
dr-mode`** (upstream `eb320f76e31d`) — "With vbus override enabled when in OTG
`dr_mode`, Host<->Peripheral switch now works on SM8550, otherwise the DWC3
seems to be stuck in Host mode only." Relevant because our board is SM8550 and
patch 1400 moves the controller into OTG.

## 3. The bootloader that provides `linux usb`: ROCKNIX-ABL

`linux usb` is the **ROCKNIX-ABL** boot target (a custom Qualcomm ABL;
explicitly "tested with … **Armada**").

- https://github.com/ROCKNIX/abl
- https://github.com/ROCKNIX/abl/releases

The README lists **"USB Boot Support — Boot supported Linux images directly from
USB devices"** and "Multiple Boot Sources: Internal storage / SD card / USB". So
USB boot is a **first-class, maintained** feature, and the ABL hands off to a
Linux kernel + initramfs (dracut) — i.e. the stage where our failure lives. The
release history shows active USB-boot work, and — notably — an **ADSP
interaction** already known to the ABL team:

- v1.1.7 (2026-08-01): `Boot: Enable USB boot`, `USB boot: Preserve fastboot in
  abl in host mode`, `usb: shutdown ADSP for EFI boot`, `xhci: Match UEFI spec`,
  `usb: fail fast when nothing connected`, `usb: boot error if no image`.
- v1.1.8 (2026-08-25): `sm4450: disable usb boot for now` (SoC-specific gating).

The `usb: shutdown ADSP for EFI boot` item is interesting for us: it shows the
ROCKNIX team handles an ADSP/PPM interaction around USB boot. It is on the
**EFI** path, not the `linux usb` path, so it does not solve our case, but it is
worth reading the ABL source for how they sequence USB vs ADSP.

## 4. Community reports (adjacent, none is our exact case)

- **Armada issue #155 — "Support booting Armada via stock UEFI without flashing
  ABL"** (RP6, Jul 2026): a *different* boot path (stock UEFI + GRUB + a
  `devicetree` line), fully reversible, no ABL flash. Not USB boot, but relevant
  as a lower-risk alternative boot route for RP6 owners, and it names the RP6's
  lack of public recovery firmware. https://github.com/armada-os/armada/issues/155
- **Armada issue #102 — "Sometimes just doesn't boot with Armada (RP6)"** (closed):
  cold-boot sometimes needs a charger plugged in / a long power-hold. Suggests a
  **power/charger-state-dependent** boot sensitivity on this board, adjacent to
  our source/sink-role theme. https://github.com/armada-os/armada/issues/102
- **Generic `Host halt failed, -110`**: OpenWrt (ipq806x/ipq40xx), Armbian
  (Rockchip Helios64), Arch Linux ARM (RPi4) — all describe the *generic* xHCI
  "host controller not responding, assume dead" failure under load/teardown.
  Confirms `-110` is a broad xHCI symptom, not something unique to us.
- **Arch BBS "[SOLVED] How to make USB available in initramfs"** — the generic
  class: the USB device simply does not exist in the initramfs at root-mount
  time; the fixes are initramfs-side (module/hook ordering), matching our
  lever-C framing (the fix is in the initramfs, not the firmware).
- **ROCKNIX wiki / DeepWiki boot process** pages describe the ABL → kernel →
  initramfs chain for Qualcomm handhelds; useful background on the standard flow.

## Bottom line

- No one has published a fix for *this* RP6 `linux usb` pre-plug case — the
  search did not change the plan.
- **Our `-110` finding is corroborated as an upstream `qmp-combo` bug** (Sep 2026
  patch, same `gcc_usb3_prim_phy_pipe_clk` WARN via `pmic_glink_altmode_worker`).
- **Our `dr_mode=host` → OTG demotion (patch 1400) is corroborated as the
  upstream-recommended direction** (Mar 2026 `usb-role-switch`/UCSI thread) and
  as an SM8550 concern (vbus-override commit).
- **The lever-C fix stays in the initramfs** (post-PDR, single, early rebind),
  which is also where the community's analogous initramfs-USB problems are
  solved.

## References

- `phy: qcom: qmp-combo` runtime-PM/typec fix (Oleg Keri, 2026-09-16):
  [lkml 0/2](https://lkml.org/lkml/2026/9/16/1519) ·
  [mirror 0/2](https://lkml.iu.edu/hypermail/linux/kernel/2609.2/01276.html) ·
  [mirror 2/2](https://lkml.iu.edu/hypermail/linux/kernel/2609.2/01277.html) ·
  [v3](https://lkml.org/lkml/2026/9/16/1617)
- `usb-role-switch` + UCSI semantics (2026-03):
  [lkml.iu.edu/2603.1/12798](https://lkml.iu.edu/2603.1/12798.html)
- `usb: dwc3: qcom: enable vbus override when in OTG dr-mode` (`eb320f76e31d`)
- ROCKNIX-ABL: [repo](https://github.com/ROCKNIX/abl) ·
  [releases](https://github.com/ROCKNIX/abl/releases)
- Armada issues: [#155](https://github.com/armada-os/armada/issues/155) ·
  [#102](https://github.com/armada-os/armada/issues/102)
- local counterparts: [FULL_SYSTEM_PREPLUG_SOURCE_ROLE.md](FULL_SYSTEM_PREPLUG_SOURCE_ROLE.md)
  (the `-110` measurement), [KERNEL_PATCH_1400.md](KERNEL_PATCH_1400.md) /
  [ABL_DR_MODE_HOST.md](ABL_DR_MODE_HOST.md) (the `dr_mode` demotion),
  [INITRAMFS_CHANGES.md](INITRAMFS_CHANGES.md) (lever C)
